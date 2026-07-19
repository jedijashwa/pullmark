/*
 * Shared marked extensions for PullMark's Typora-parity constructs:
 *   - $inline$ and $$block$$ math rendered through KaTeX (renderToString —
 *     pure string output, so the same code runs in the WKWebView pages and
 *     in the Quick Look extension's JavaScriptCore context, no DOM needed)
 *   - ==highlight==  -> <mark>
 *   - ~subscript~    -> <sub>   (double ~~strikethrough~~ is untouched)
 *   - ^superscript^  -> <sup>
 *   - a paragraph that is exactly [toc] -> an empty <nav class="pm-toc">
 *     placeholder that each pipeline fills with heading links
 *
 * This file must stay DOM-free: it is evaluated both in the browser page
 * (before app.js) and in JavaScriptCore for Quick Look previews.
 */
(function (global) {
  "use strict";

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // GitHub-style heading slugs — the same algorithm app.js applies to the
  // rendered DOM, so [toc] links land on the anchors either pipeline emits.
  function slugify(text) {
    return String(text).trim().toLowerCase()
      .replace(/[^\p{L}\p{N}\- ]+/gu, "")
      .replace(/ +/g, "-");
  }

  function renderMath(tex, displayMode) {
    if (typeof global.katex === "undefined") { return null; }
    try {
      return global.katex.renderToString(tex, {
        displayMode: displayMode,
        throwOnError: false
      });
    } catch (e) {
      return null; // hard KaTeX failure: fall back to literal code
    }
  }

  function mathHTML(tex, displayMode) {
    var html = renderMath(tex, displayMode);
    if (html === null) {
      html = "<code>" + escapeHtml(tex) + "</code>";
    }
    return displayMode
      ? '<div class="pm-math-block">' + html + "</div>\n"
      : html;
  }

  // ---- Math ----
  // Conservative Pandoc-style tokenization so currency survives: the
  // opening $ must be followed by a non-space, the closing $ preceded by a
  // non-space and not followed by a digit, no $ or newline inside. Code
  // spans and fenced blocks starting before a $ win naturally — marked's
  // tokenizers consume them whole before inline extensions ever see their
  // contents — and a backtick inside a candidate rejects it (TeX has no
  // backticks), so "$10 fee: `$x$`" can never swallow the code span's
  // opening fence to pair "$10 … `$".

  var mathBlock = {
    name: "pmMathBlock",
    level: "block",
    start: function (src) {
      var i = src.indexOf("$$");
      return i === -1 ? undefined : i;
    },
    tokenizer: function (src) {
      var m = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n+|$)/.exec(src);
      if (!m || !m[1].trim() || m[1].indexOf("`") !== -1) { return undefined; }
      return { type: "pmMathBlock", raw: m[0], text: m[1].trim() };
    },
    renderer: function (token) {
      return mathHTML(token.text, true);
    }
  };

  var mathInline = {
    name: "pmMathInline",
    level: "inline",
    start: function (src) {
      var i = src.indexOf("$");
      return i === -1 ? undefined : i;
    },
    tokenizer: function (src) {
      // $$…$$ inside a paragraph still renders display-style (Typora).
      var display = /^\$\$([\s\S]+?)\$\$/.exec(src);
      if (display && display[1].trim() && display[1].indexOf("`") === -1) {
        return { type: "pmMathInline", raw: display[0],
                 text: display[1].trim(), displayMode: true };
      }
      var m = /^\$([^$\n]+?)\$(?!\d)/.exec(src);
      if (!m || /^\s|\s$/.test(m[1]) || m[1].indexOf("`") !== -1) { return undefined; }
      return { type: "pmMathInline", raw: m[0], text: m[1], displayMode: false };
    },
    renderer: function (token) {
      return mathHTML(token.text, token.displayMode);
    }
  };

  // ---- ==highlight== ----

  var highlight = {
    name: "pmHighlight",
    level: "inline",
    start: function (src) {
      var i = src.indexOf("==");
      return i === -1 ? undefined : i;
    },
    tokenizer: function (src) {
      var m = /^==([^\n]+?)==/.exec(src);
      if (!m || /^[\s=]|[\s=]$/.test(m[1])) { return undefined; }
      return { type: "pmHighlight", raw: m[0], text: m[1],
               tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer: function (token) {
      return "<mark>" + this.parser.parseInline(token.tokens) + "</mark>";
    }
  };

  // ---- ~sub~ / ^sup^ ----
  // Pandoc rule: no whitespace inside, so "approx ~5" and "5 ^ 3" stay
  // literal. The (?!~)/(?<none>) guards keep ~~strikethrough~~ intact.

  var subscript = {
    name: "pmSub",
    level: "inline",
    start: function (src) {
      var i = src.indexOf("~");
      return i === -1 ? undefined : i;
    },
    tokenizer: function (src) {
      var m = /^~(?!~)([^\s~]+)~(?!~)/.exec(src);
      if (!m) { return undefined; }
      return { type: "pmSub", raw: m[0], text: m[1],
               tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer: function (token) {
      return "<sub>" + this.parser.parseInline(token.tokens) + "</sub>";
    }
  };

  var superscript = {
    name: "pmSup",
    level: "inline",
    start: function (src) {
      var i = src.indexOf("^");
      return i === -1 ? undefined : i;
    },
    tokenizer: function (src) {
      var m = /^\^([^\s^]+)\^/.exec(src);
      if (!m) { return undefined; }
      return { type: "pmSup", raw: m[0], text: m[1],
               tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer: function (token) {
      return "<sup>" + this.parser.parseInline(token.tokens) + "</sup>";
    }
  };

  // ---- [toc] ----
  // A block that is exactly "[toc]" (case-insensitive) renders as an empty
  // nav placeholder; app.js fills it from the heading outline once anchors
  // exist, and the Quick Look static renderer fills it from lexer tokens.

  var TOC_PLACEHOLDER = '<nav class="pm-toc" data-pm-toc="1" aria-label="Table of contents"></nav>';

  var toc = {
    name: "pmToc",
    level: "block",
    start: function (src) {
      var i = src.toLowerCase().indexOf("[toc]");
      return i === -1 ? undefined : i;
    },
    tokenizer: function (src) {
      // Only a whole [toc] paragraph counts: end of input or a blank line
      // must follow, so "[toc] and prose" stays literal text.
      var m = /^\[toc\][ \t]*(?:\n{2,}|\n?$)/i.exec(src);
      if (!m) { return undefined; }
      return { type: "pmToc", raw: m[0] };
    },
    renderer: function () {
      return TOC_PLACEHOLDER + "\n";
    }
  };

  global.pmExtensions = {
    extensions: function () {
      return [mathBlock, mathInline, highlight, subscript, superscript, toc];
    },
    slugify: slugify,
    escapeHtml: escapeHtml,
    TOC_PLACEHOLDER: TOC_PLACEHOLDER
  };
})(typeof window !== "undefined" ? window : globalThis);
