(function () {
  "use strict";

  // The payload rides in a non-executing JSON script tag so hostile markdown
  // can never reach an executing context; page CSP additionally blocks any
  // inline script (#5).
  var payload = { mode: "document", markdown: "" };
  var payloadElement = document.getElementById("pm-payload");
  if (payloadElement) {
    try {
      payload = JSON.parse(payloadElement.textContent);
    } catch (e) { /* fall through to the empty document */ }
  }
  var content = document.getElementById("content");
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  // Reading theme: app.css scopes the non-default packs to
  // :root[data-theme="..."], so an absent or "github" theme renders the
  // stock GitHub look untouched.
  if (payload.theme) {
    document.documentElement.dataset.theme = payload.theme;
  }
  // Settings theme cards: miniature, non-interactive rendering.
  if (payload.preview) {
    document.documentElement.dataset.preview = "1";
  }

  if (typeof markedAlert === "function") {
    marked.use(markedAlert());
  }
  if (typeof markedFootnote === "function") {
    marked.use(markedFootnote());
  }
  // Typora-parity constructs (math/[toc]/highlight/sub/sup) shared with the
  // Quick Look static renderer.
  if (typeof pmExtensions !== "undefined") {
    marked.use({ extensions: pmExtensions.extensions() });
  }
  marked.use({ gfm: true });

  // Outline speech bubble drawn to match the SF Symbols style used in the
  // native toolbar.
  var COMMENT_ICON =
    '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor"' +
    ' stroke-width="1.4" stroke-linejoin="round" stroke-linecap="round" aria-hidden="true">' +
    '<path d="M2.75 3h10.5c.69 0 1.25.56 1.25 1.25v5.5c0 .69-.56 1.25-1.25 1.25H8.5L5.25 13.6V11H2.75c-.69 0-1.25-.56-1.25-1.25v-5.5C1.5 3.56 2.06 3 2.75 3z"/>' +
    "</svg>";

  function post(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
      window.webkit.messageHandlers.bridge.postMessage(message);
    }
  }

  function render(markdown) {
    return marked.parse(markdown || "");
  }

  // ---- Local resources (relative images/links in local documents) ----

  function rewriteLocalResources(root) {
    if (!payload.localResources) { return; }
    var absolute = /^([a-z][a-z0-9+.\-]*:|\/\/|#)/i;
    function encodeSegment(segment) {
      var decoded = segment;
      try { decoded = decodeURIComponent(segment); } catch (e) { /* keep raw */ }
      return encodeURIComponent(decoded);
    }
    root.querySelectorAll("img[src], a[href]").forEach(function (el) {
      var attr = el.tagName === "IMG" ? "src" : "href";
      var value = el.getAttribute(attr);
      if (!value || absolute.test(value)) { return; }
      var path = value.replace(/^\//, "");
      el.setAttribute(attr, "pullmark-local:///" + path.split("/").map(encodeSegment).join("/"));
    });
  }

  // ---- Remote resources (PR files: images/links relative to the repo) ----

  function resolveRepoPath(baseDir, relative) {
    var joined = relative.startsWith("/")
      ? relative.slice(1)
      : (baseDir ? baseDir + "/" : "") + relative;
    var stack = [];
    var parts = joined.split("/");
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (part === "" || part === ".") { continue; }
      if (part === "..") {
        if (!stack.length) { return null; }
        stack.pop();
      } else {
        stack.push(part);
      }
    }
    return stack.length ? stack.join("/") : null;
  }

  function rewriteRemoteResources(root) {
    if (!payload.remoteResources) { return; }
    var absolute = /^([a-z][a-z0-9+.\-]*:|\/\/|#)/i;
    var baseDir = payload.resourceDir || "";
    root.querySelectorAll("img[src], a[href]").forEach(function (el) {
      var attr = el.tagName === "IMG" ? "src" : "href";
      var value = el.getAttribute(attr);
      if (!value || absolute.test(value)) { return; }
      var fragment = "";
      if (attr === "href") {
        var hash = value.indexOf("#");
        if (hash !== -1) { fragment = value.slice(hash); value = value.slice(0, hash); }
      }
      var resolved = resolveRepoPath(baseDir, value);
      if (!resolved) { return; }
      el.setAttribute(attr, "pullmark-remote:///" +
        resolved.split("/").map(encodeURIComponent).join("/") + fragment);
    });
  }

  // ---- Word-level diff marks ----
  // Swift wraps changed runs in private-use sentinels (U+E000-U+E003) that
  // survive Markdown rendering as text; convert them to highlight spans.
  // The open/close state carries across text nodes so a run spanning inline
  // elements (e.g. through **bold**) stays highlighted.

  var DEL_OPEN = "\uE000", DEL_CLOSE = "\uE001", INS_OPEN = "\uE002", INS_CLOSE = "\uE003";
  var SENTINELS = /[\uE000-\uE003]/;
  var SENTINELS_ALL = /[\uE000-\uE003]/g;

  function applyWordDiffMarks(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var nodes = [];
    while (walker.nextNode()) { nodes.push(walker.currentNode); }
    var current = null; // "del" | "ins" | null
    nodes.forEach(function (node) {
      var text = node.nodeValue;
      if (!SENTINELS.test(text) && !current) { return; }
      var frag = document.createDocumentFragment();
      var buffer = "";
      function flush() {
        if (!buffer) { return; }
        if (current) {
          var span = document.createElement("span");
          span.className = current === "del" ? "pm-word-del" : "pm-word-ins";
          span.textContent = buffer;
          frag.append(span);
        } else {
          frag.append(document.createTextNode(buffer));
        }
        buffer = "";
      }
      for (var ch of text) {
        if (ch === DEL_OPEN) { flush(); current = "del"; }
        else if (ch === INS_OPEN) { flush(); current = "ins"; }
        else if (ch === DEL_CLOSE || ch === INS_CLOSE) { flush(); current = null; }
        else { buffer += ch; }
      }
      flush();
      node.parentNode.replaceChild(frag, node);
    });
    // Sentinels that leaked into attributes (e.g. a changed link URL) are
    // stripped rather than highlighted.
    root.querySelectorAll("*").forEach(function (el) {
      Array.prototype.forEach.call(el.attributes, function (attr) {
        if (SENTINELS.test(attr.value)) {
          el.setAttribute(attr.name, attr.value.replace(SENTINELS_ALL, ""));
        }
      });
    });
  }

  // ---- YAML front matter ----
  // GitHub renders a leading `---` fence as a metadata table instead of
  // prose. Detection is line-based (no YAML parser): the opening `---` must
  // be the very first line, the closing `---` the next line that is exactly
  // `---` after trimming. Values are inserted with textContent, never parsed.

  // Document mode: split leading front matter off the source. Returns
  // { lines, rest, endLine } (endLine = 1-based line of the closing fence)
  // or null when the document has no front matter.
  function fmParse(markdown) {
    var lines = (markdown || "").split("\n");
    if (lines.length < 2 || lines[0].replace(/\r$/, "") !== "---") { return null; }
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() === "---") {
        return {
          lines: lines.slice(1, i),
          rest: lines.slice(i + 1).join("\n"),
          endLine: i + 1
        };
      }
    }
    return null;
  }

  // Diff mode: front matter arrives as one whole block segment (Swift keeps
  // the fence together). Returns the inner lines, or null when the text is
  // not exactly a front matter fence.
  function fmBlockLines(text) {
    var lines = (text || "").split("\n");
    if (lines.length < 2 || lines[0].replace(/\r$/, "") !== "---") { return null; }
    if (lines[lines.length - 1].trim() !== "---") { return null; }
    return lines.slice(1, -1);
  }

  // One table row per line: simple `key: value` lines split on the first
  // colon; anything else (nested/indented YAML, list items, comments) stays
  // a single preformatted cell.
  function fmRowEl(line) {
    var row = document.createElement("tr");
    var m = /^([^\s:#-][^:]*?)[ \t]*:(?:[ \t]+(.*))?$/.exec(line);
    if (m) {
      var key = document.createElement("th");
      key.textContent = m[1];
      var value = document.createElement("td");
      value.textContent = (m[2] || "").trim();
      row.append(key, value);
    } else {
      var cell = document.createElement("td");
      cell.colSpan = 2;
      var pre = document.createElement("pre");
      pre.textContent = line;
      cell.append(pre);
      row.append(cell);
    }
    return row;
  }

  function frontMatterEl(lines, open) {
    var details = document.createElement("details");
    details.className = "pm-frontmatter";
    if (open) { details.open = true; }
    var summary = document.createElement("summary");
    summary.textContent = "Front matter";
    details.append(summary);
    var table = document.createElement("table");
    table.className = "pm-frontmatter-table";
    var tbody = document.createElement("tbody");
    lines.forEach(function (line) {
      if (!line.trim()) { return; }
      tbody.append(fmRowEl(line));
    });
    table.append(tbody);
    details.append(table);
    return details;
  }

  // Diff segments: Swift flags each side that is a leading front matter
  // block (fmText / fmOldText — only Swift knows both sides' true line
  // numbers). Fills `el` with the metadata table when flagged, with
  // rendered markdown otherwise.
  function renderSegmentText(el, text, isFrontMatter, open) {
    var lines = isFrontMatter ? fmBlockLines(text) : null;
    if (lines) {
      el.append(frontMatterEl(lines, open));
    } else {
      el.innerHTML = render(text);
    }
  }

  // ---- Heading anchors + link previews ----

  // marked v15 no longer emits heading ids; generate GitHub-style slugs so
  // [table of contents](#like-this) links work.
  function setupHeadingAnchors(root) {
    var used = Object.create(null);
    root.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach(function (heading) {
      if (heading.id) { return; }
      var slug = heading.textContent.trim().toLowerCase()
        .replace(/[^\p{L}\p{N}\- ]+/gu, "")
        .replace(/ +/g, "-");
      var unique = slug || "section";
      var counter = 1;
      while (used[unique]) { unique = slug + "-" + counter; counter += 1; }
      used[unique] = true;
      heading.id = unique;
    });
  }

  // Browser-style status pill showing where a link goes before you click it.
  function setupLinkPreview() {
    var status = document.createElement("div");
    status.className = "pm-link-status";
    document.body.append(status);
    document.addEventListener("mouseover", function (event) {
      var anchor = event.target.closest ? event.target.closest("a[href]") : null;
      if (!anchor) { status.style.display = "none"; return; }
      var href = anchor.getAttribute("href") || "";
      if (!href) { status.style.display = "none"; return; }
      var label = href;
      ["pullmark-local:///", "pullmark-remote:///"].forEach(function (scheme) {
        if (href.startsWith(scheme)) {
          try { label = decodeURIComponent(href.slice(scheme.length)); } catch (e) { /* keep raw */ }
        }
      });
      status.textContent = label;
      status.style.display = "block";
    });
  }

  // ---- Code + mermaid enhancement ----

  function enhance(root) {
    root.querySelectorAll("pre code.language-mermaid").forEach(function (el) {
      var pre = el.closest("pre");
      var div = document.createElement("div");
      div.className = "mermaid";
      div.dataset.source = el.textContent;
      div.textContent = el.textContent;
      // Keep the blame line annotation on the replacement element.
      if (pre.dataset.pmLines) { div.dataset.pmLines = pre.dataset.pmLines; }
      pre.replaceWith(div);
    });
    // GitHub suggestion blocks get a labeled container instead of syntax
    // highlighting.
    root.querySelectorAll("pre code.language-suggestion").forEach(function (el) {
      var pre = el.closest("pre");
      var wrap = document.createElement("div");
      wrap.className = "pm-suggestion";
      var label = document.createElement("div");
      label.className = "pm-suggestion-label";
      label.textContent = "Suggested change";
      if (pre.dataset.pmLines) { wrap.dataset.pmLines = pre.dataset.pmLines; }
      pre.replaceWith(wrap);
      wrap.append(label, pre);
    });
    root.querySelectorAll("pre code").forEach(function (el) {
      if (el.classList.contains("language-suggestion")) { return; }
      try { hljs.highlightElement(el); } catch (e) { /* unknown language */ }
    });
  }

  var __headings = [];

  function reportOutline(root) {
    var items = [];
    __headings = [];
    root.querySelectorAll("h1[id], h2[id], h3[id], h4[id]").forEach(function (heading) {
      if (heading.closest(".pm-thread")) { return; }
      __headings.push(heading);
      items.push({
        level: parseInt(heading.tagName.slice(1), 10),
        text: heading.textContent.trim(),
        id: heading.id
      });
    });
    post({ type: "outline", items: items });
    return items;
  }

  // ---- [toc] ----
  // pm-extensions.js renders a `[toc]` paragraph as an empty nav
  // placeholder; fill every one with links built from the same heading
  // items the outline sidebar shows (anchors already exist by now).

  function populateToc(items) {
    var navs = content.querySelectorAll("nav.pm-toc");
    if (!navs.length) { return; }
    var minLevel = items.reduce(function (min, item) {
      return Math.min(min, item.level);
    }, 6);
    navs.forEach(function (nav) {
      nav.textContent = "";
      if (!items.length) {
        var empty = document.createElement("p");
        empty.className = "pm-toc-empty";
        empty.textContent = "No headings";
        nav.append(empty);
        return;
      }
      var list = document.createElement("ul");
      list.className = "pm-toc-list";
      items.forEach(function (item) {
        var li = document.createElement("li");
        li.className = "pm-toc-item pm-toc-level-" + (item.level - minLevel + 1);
        var a = document.createElement("a");
        a.href = "#" + item.id;
        a.textContent = item.text;
        li.append(a);
        list.append(li);
      });
      nav.append(list);
    });
  }

  // ---- Word count / reading time (document mode only) ----
  // Counted from the rendered text so markup, front matter, the [toc]
  // block, and KaTeX's duplicated math trees don't inflate the number.

  function reportStats(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        return node.parentElement &&
          node.parentElement.closest(".pm-toc, .pm-frontmatter, .katex")
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    var words = 0;
    while (walker.nextNode()) {
      words += (walker.currentNode.nodeValue.match(/[\p{L}\p{N}]+/gu) || []).length;
    }
    // 220 wpm is a middle-of-the-road silent reading speed.
    post({ type: "stats", words: words, minutes: Math.max(1, Math.ceil(words / 220)) });
  }

  // Scroll-spy: report which section the viewport is currently in.
  var __activeSection = null;
  function updateActiveSection() {
    var current = "";
    for (var i = 0; i < __headings.length; i++) {
      if (__headings[i].getBoundingClientRect().top <= 90) {
        current = __headings[i].id;
      } else {
        break;
      }
    }
    if (current !== __activeSection) {
      __activeSection = current;
      post({ type: "activeSection", id: current });
    }
  }
  (function () {
    var pending = false;
    window.addEventListener("scroll", function () {
      if (pending) { return; }
      pending = true;
      setTimeout(function () { pending = false; updateActiveSection(); }, 120);
    }, { passive: true });
  })();

  // ---- Find in page ----

  window.__pmFind = (function () {
    var matches = [];
    var index = -1;
    function clear() {
      document.querySelectorAll("mark.pm-find").forEach(function (mark) {
        var parent = mark.parentNode;
        parent.replaceChild(document.createTextNode(mark.textContent), mark);
        parent.normalize();
      });
      matches = [];
      index = -1;
    }
    function focusCurrent() {
      matches.forEach(function (mark, i) {
        mark.classList.toggle("pm-find-current", i === index);
      });
      if (matches[index]) {
        matches[index].scrollIntoView({ block: "center" });
      }
    }
    function set(query) {
      clear();
      if (!query) { return [0, 0]; }
      var lowered = query.toLowerCase();
      // Skip non-rendered text (e.g. <style> sheets that mermaid embeds in
      // its SVGs mention ".mermaid" dozens of times): matches there would
      // be invisible and inflate the count.
      var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
        acceptNode: function (node) {
          var el = node.parentElement;
          var tag = el && el.tagName ? el.tagName.toLowerCase() : "";
          if (!el || tag === "style" || tag === "script" || tag === "noscript") {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      var nodes = [];
      while (walker.nextNode()) { nodes.push(walker.currentNode); }
      nodes.forEach(function (node) {
        var text = node.nodeValue;
        var lower = text.toLowerCase();
        var i = lower.indexOf(lowered);
        if (i === -1) { return; }
        var frag = document.createDocumentFragment();
        var pos = 0;
        while (i !== -1) {
          frag.append(document.createTextNode(text.slice(pos, i)));
          var mark = document.createElement("mark");
          mark.className = "pm-find";
          mark.textContent = text.slice(i, i + query.length);
          frag.append(mark);
          matches.push(mark);
          pos = i + query.length;
          i = lower.indexOf(lowered, pos);
        }
        frag.append(document.createTextNode(text.slice(pos)));
        node.parentNode.replaceChild(frag, node);
      });
      if (matches.length) { index = 0; focusCurrent(); }
      return [matches.length ? 1 : 0, matches.length];
    }
    function step(delta) {
      if (!matches.length) { return [0, 0]; }
      index = (index + delta + matches.length) % matches.length;
      focusCurrent();
      return [index + 1, matches.length];
    }
    return {
      set: set,
      next: function () { return step(1); },
      prev: function () { return step(-1); },
      clear: function () { clear(); return [0, 0]; }
    };
  })();

  // ---- Copy as Markdown ----
  // Maps the current selection back to source lines using the data-pm-lines
  // annotations (document mode). Whole-block granularity: any block the
  // selection touches contributes its full line range. Returns
  // [startLine, endLine] (1-based, inclusive) or null when nothing usable
  // is selected — Swift then copies the whole document source.

  window.__pmSelectionLines = function () {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { return null; }
    var range = sel.getRangeAt(0);
    var start = null;
    var end = null;
    content.querySelectorAll("[data-pm-lines]").forEach(function (el) {
      var m = /^(\d+)-(\d+)$/.exec(el.getAttribute("data-pm-lines"));
      if (!m) { return; }
      var intersects;
      try { intersects = range.intersectsNode(el); } catch (e) { intersects = false; }
      if (!intersects) { return; }
      var s = +m[1];
      var e2 = +m[2];
      if (start === null || s < start) { start = s; }
      if (end === null || e2 > end) { end = e2; }
    });
    return start === null ? null : [start, end];
  };

  function renderMermaid() {
    var nodes = document.querySelectorAll(".mermaid");
    if (!nodes.length || typeof mermaid === "undefined") { return; }
    nodes.forEach(function (node) {
      node.removeAttribute("data-processed");
      node.textContent = node.dataset.source || "";
    });
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: darkQuery.matches ? "dark" : "default"
    });
    mermaid.run({ querySelector: ".mermaid" }).catch(function () {
      /* invalid diagram source: leave the raw text visible */
    });
  }

  darkQuery.addEventListener("change", renderMermaid);

  // ---- Blame gutter (document mode) ----
  // Swift computes everything (relative dates, coalesced runs, avatar
  // tiering); this only builds DOM. The document is rendered once, whole
  // (so footnotes and reference links work), then each top-level element is
  // annotated with its source line range via the marked lexer, and gutter
  // entries are positioned from element geometry. Avatars are remote https
  // images in a non-persistent web view; when no avatar URL exists
  // (local-only blame) a deterministic initials circle stands in.

  function blameInitialsEl(name) {
    var span = document.createElement("span");
    span.className = "pm-blame-avatar pm-blame-initials";
    var parts = (name || "?").trim().split(/\s+/).filter(Boolean);
    var initials = parts.length
      ? (parts[0][0] + (parts.length > 1 ? parts[parts.length - 1][0] : "")) : "?";
    span.textContent = initials.toUpperCase();
    var hash = 0;
    var s = name || "";
    for (var i = 0; i < s.length; i++) { hash = (hash * 31 + s.charCodeAt(i)) >>> 0; }
    span.style.background = "hsl(" + (hash % 360) + ", 45%, 42%)";
    return span;
  }

  function blameAvatarEl(name, avatarUrl) {
    if (!avatarUrl) { return blameInitialsEl(name); }
    var img = document.createElement("img");
    img.className = "pm-blame-avatar";
    img.src = avatarUrl;
    img.alt = name || "";
    img.addEventListener("error", function () { img.replaceWith(blameInitialsEl(name)); });
    return img;
  }

  function blameNoteEl(text) {
    var note = document.createElement("div");
    note.className = "pm-blame-note";
    note.textContent = text;
    return note;
  }

  // Walks the top-level lexer tokens in parallel with #content's children,
  // stamping each element with its 1-based source line range
  // (data-pm-lines="start-end"). Each token's raw is located in the source
  // from a moving cursor (raws appear in source order, but plain
  // concatenation would drift: marked swallows link-reference definitions
  // without emitting a token). Returns false when the walk isn't possible
  // (lexer failure) so the gutter is skipped. `lineOffset` is the number of
  // source lines stripped before `markdown` (the front matter fence), so
  // annotations still carry original file line numbers.
  function annotateBlockLines(markdown, lineOffset) {
    var source = markdown || "";
    var tokens;
    try { tokens = marked.lexer(source); } catch (e) { return false; }

    var els = [];
    for (var child = content.firstElementChild; child; child = child.nextElementSibling) {
      // marked-footnote appends the footnotes section at the end; it has no
      // in-place source lines.
      if (child.tagName === "SECTION" && child.classList.contains("footnotes")) { continue; }
      els.push(child);
    }

    // Bare instance (no extensions) used to count how many top-level
    // elements a raw-HTML token produces.
    var plain = null;
    function htmlElementCount(raw) {
      try {
        plain = plain || new marked.Marked({ gfm: true });
        var tpl = document.createElement("template");
        tpl.innerHTML = plain.parse(raw);
        return tpl.content.children.length;
      } catch (e) { return 1; }
    }

    // Block tokens start at line beginnings; anchoring the search there
    // avoids false matches inside skipped regions.
    function findToken(raw, from) {
      var idx = source.indexOf(raw, from);
      while (idx > 0 && raw[0] !== "\n" && source[idx - 1] !== "\n") {
        idx = source.indexOf(raw, idx + 1);
      }
      return idx === -1 ? from : idx;
    }

    function countNewlines(text) {
      return (text.match(/\n/g) || []).length;
    }

    var ONE = { heading: 1, paragraph: 1, code: 1, blockquote: 1, list: 1, table: 1, hr: 1,
                pmMathBlock: 1, pmToc: 1 };
    var NONE = { space: 1, def: 1, footnote: 1 };
    var line = 1 + (lineOffset || 0); // 1-based file line at srcPos
    var srcPos = 0;
    var ei = 0;
    var i = 0;
    while (i < tokens.length && ei < els.length) {
      var tok = tokens[i];
      if (tok.type === "footnotes") {
        // Synthetic container token — its raw is a label, not source text.
        i += 1;
        continue;
      }
      var raw = tok.raw || "";
      var count;
      if (tok.type === "text") {
        // Consecutive top-level text tokens merge into one paragraph.
        while (i + 1 < tokens.length && tokens[i + 1].type === "text") {
          i += 1;
          raw += tokens[i].raw || "";
        }
        count = 1;
      } else if (NONE[tok.type]) {
        count = 0;
      } else if (ONE[tok.type]) {
        count = 1;
      } else {
        count = htmlElementCount(raw);
      }
      var idx = findToken(raw, srcPos);
      line += countNewlines(source.slice(srcPos, idx));
      var startLine = line;
      var endLine = startLine + countNewlines(raw.replace(/\n+$/, ""));
      for (var k = 0; k < count && ei < els.length; k++) {
        els[ei].setAttribute("data-pm-lines", startLine + "-" + endLine);
        ei += 1;
      }
      line = startLine + countNewlines(raw);
      srcPos = idx + raw.length;
      i += 1;
    }
    return true;
  }

  function setupBlameGutter(runs) {
    document.documentElement.classList.add("pm-blame-on");

    var layer = document.createElement("div");
    layer.className = "pm-blame-gutter";
    content.append(layer);

    // Shared hover popover; lives inside #content so it inherits the
    // reading theme's primer variables.
    var pop = document.createElement("div");
    pop.className = "pm-blame-pop";
    content.append(pop);
    var hideTimer = null;
    function hidePop() { pop.style.display = "none"; }
    function scheduleHide() { hideTimer = setTimeout(hidePop, 250); }
    function cancelHide() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    }
    pop.addEventListener("mouseenter", cancelHide);
    pop.addEventListener("mouseleave", scheduleHide);
    window.addEventListener("scroll", hidePop, { passive: true });

    function shaChipEl(run) {
      var sha;
      if (run.url) {
        sha = document.createElement("a");
        sha.href = run.url; // opened externally by the navigation delegate
        sha.title = "View commit on GitHub";
      } else {
        sha = document.createElement("button");
        sha.type = "button";
        sha.title = "Copy full SHA";
        sha.addEventListener("click", function (event) {
          event.stopPropagation();
          post({ type: "copySHA", sha: run.sha });
          sha.textContent = "copied";
          setTimeout(function () { sha.textContent = run.shortSHA; }, 900);
        });
      }
      sha.className = "pm-blame-sha";
      sha.textContent = run.shortSHA;
      return sha;
    }

    function fillPop(run) {
      pop.textContent = "";
      var head = document.createElement("div");
      head.className = "pm-blame-pop-head";
      var author = document.createElement("span");
      author.className = "pm-blame-pop-author";
      author.textContent = run.uncommitted ? "Uncommitted changes" : (run.author || "");
      head.append(author);
      if (run.dateLabel && !run.uncommitted) {
        var date = document.createElement("span");
        date.className = "pm-blame-pop-date";
        date.textContent = run.dateLabel;
        head.append(date);
      }
      pop.append(head);
      if (run.headline && !run.uncommitted) {
        var headline = document.createElement("div");
        headline.className = "pm-blame-pop-headline";
        headline.textContent = run.headline;
        pop.append(headline);
      }
      var actions = document.createElement("div");
      actions.className = "pm-blame-pop-actions";
      if (!run.uncommitted) { actions.append(shaChipEl(run)); }
      var hint = document.createElement("span");
      hint.className = "pm-blame-pop-hint";
      hint.textContent = "Click the gutter for history";
      actions.append(hint);
      pop.append(actions);
    }

    function showPop(entry, run) {
      cancelHide();
      fillPop(run);
      pop.style.display = "block";
      var rect = entry.getBoundingClientRect();
      // Fixed positioning, clamped to the viewport.
      pop.style.left = Math.round(rect.right + 10) + "px";
      pop.style.top = "0px";
      var height = pop.offsetHeight;
      var top = Math.min(Math.max(8, rect.top - 4), window.innerHeight - height - 8);
      pop.style.top = Math.round(top) + "px";
    }

    var entries = [];
    runs.forEach(function (run) {
      if (!run.sha) { return; }
      var entry = document.createElement("div");
      entry.className = "pm-blame-entry";
      if (run.uncommitted) { entry.classList.add("pm-blame-entry-uncommitted"); }
      entry.append(blameAvatarEl(run.uncommitted ? "· ·" : run.author, run.avatarUrl));
      var rule = document.createElement("div");
      rule.className = "pm-blame-rule";
      entry.append(rule);
      entry.addEventListener("mouseenter", function () { showPop(entry, run); });
      entry.addEventListener("mouseleave", scheduleHide);
      entry.addEventListener("click", function () {
        hidePop();
        post({ type: "blameHistory", lineStart: run.lineStart, lineEnd: run.lineEnd });
      });
      layer.append(entry);
      entries.push({ el: entry, run: run });
    });

    function blockRanges() {
      var out = [];
      content.querySelectorAll("[data-pm-lines]").forEach(function (el) {
        var m = /^(\d+)-(\d+)$/.exec(el.getAttribute("data-pm-lines"));
        if (m) { out.push({ el: el, start: +m[1], end: +m[2] }); }
      });
      return out;
    }

    function positionEntries() {
      var blocks = blockRanges();
      var cRect = content.getBoundingClientRect();
      entries.forEach(function (item) {
        var top = null;
        var bottom = null;
        blocks.forEach(function (block) {
          if (block.start > item.run.lineEnd || block.end < item.run.lineStart) { return; }
          var rect = block.el.getBoundingClientRect();
          if (top === null || rect.top < top) { top = rect.top; }
          if (bottom === null || rect.bottom > bottom) { bottom = rect.bottom; }
        });
        if (top === null) {
          item.el.style.display = "none";
          return;
        }
        item.el.style.display = "";
        item.el.style.top = Math.round(top - cRect.top) + "px";
        item.el.style.height = Math.round(Math.max(24, bottom - top)) + "px";
      });
    }

    positionEntries();
    // Reposition as async content (mermaid diagrams, images) changes block
    // heights, and on window resizes.
    if (typeof ResizeObserver === "function") {
      new ResizeObserver(positionEntries).observe(content);
    }
    window.addEventListener("resize", positionEntries);
  }

  // ---- Diff rendering ----

  // An added/removed block whose Markdown renders to nothing (or to an empty
  // shell like a bare code fence) would show as a bare colored box; give it a
  // minimal label instead.
  function markEmptyBlock(div) {
    if (div.textContent.trim() !== "") { return; }
    if (div.querySelector("img, svg, hr, video, iframe, input, object, embed, canvas")) { return; }
    var label = document.createElement("span");
    label.className = "pm-blank-label";
    label.textContent = "(empty)";
    div.append(label);
  }

  function commentButton(seg) {
    var btn = document.createElement("button");
    btn.className = "pm-comment-btn";
    btn.type = "button";
    btn.innerHTML = COMMENT_ICON;
    btn.title = "Comment on " + (seg.side === "LEFT" ? "old" : "new") +
      " lines " + seg.lineStart + "–" + seg.lineEnd;
    btn.addEventListener("click", function (event) {
      event.stopPropagation();
      post({ type: "comment", lineStart: seg.lineStart, lineEnd: seg.lineEnd, side: seg.side });
    });
    return btn;
  }

  function threadsEl(threads) {
    var wrap = document.createElement("div");
    wrap.className = "pm-threads";
    threads.forEach(function (thread) {
      var box = document.createElement("div");
      box.className = "pm-thread";
      if (thread.resolved === true) { box.classList.add("pm-thread-resolved"); }
      var header = document.createElement("div");
      header.className = "pm-thread-header";
      if (thread.lineLabel) {
        var label = document.createElement("div");
        label.className = "pm-thread-line";
        label.textContent = thread.lineLabel + (thread.resolved === true ? " · Resolved" : "");
        header.append(label);
      }
      if (thread.rootID) {
        var actions = document.createElement("div");
        actions.className = "pm-thread-actions";
        var reply = document.createElement("button");
        reply.type = "button";
        reply.textContent = "Reply";
        reply.addEventListener("click", function () {
          post({ type: "threadReply", rootID: thread.rootID });
        });
        actions.append(reply);
        if (thread.resolved !== null && thread.resolved !== undefined) {
          var resolve = document.createElement("button");
          resolve.type = "button";
          resolve.textContent = thread.resolved ? "Unresolve" : "Resolve";
          resolve.addEventListener("click", function () {
            post({ type: "threadResolve", rootID: thread.rootID, resolved: !thread.resolved });
          });
          actions.append(resolve);
        }
        header.append(actions);
      }
      box.append(header);
      (thread.comments || []).forEach(function (c) {
        var comment = document.createElement("div");
        comment.className = "pm-thread-comment";
        var head = document.createElement("div");
        head.className = "pm-thread-head";
        head.textContent = c.author + (c.dateLabel ? " · " + c.dateLabel : "");
        var body = document.createElement("div");
        body.className = "pm-thread-body";
        body.innerHTML = render(c.body);
        comment.append(head, body);
        box.append(comment);
      });
      wrap.append(box);
    });
    return wrap;
  }

  function inlineSegmentEl(seg) {
    var wrap = document.createElement("div");
    if (seg.kind === "modified" && seg.wordDiff) {
      wrap.className = "pm-block pm-changed";
      var merged = document.createElement("div");
      merged.innerHTML = render(seg.wordDiff.merged);
      applyWordDiffMarks(merged);
      wrap.append(merged);
    } else if (seg.kind === "modified") {
      wrap.className = "pm-block pm-modified";
      var oldDiv = document.createElement("div");
      oldDiv.className = "pm-old";
      renderSegmentText(oldDiv, seg.oldText, seg.fmOldText, true);
      var newDiv = document.createElement("div");
      newDiv.className = "pm-new";
      renderSegmentText(newDiv, seg.text, seg.fmText, true);
      wrap.append(oldDiv, newDiv);
    } else {
      wrap.className = "pm-block pm-" + seg.kind;
      var div = document.createElement("div");
      renderSegmentText(div, seg.text, seg.fmText, seg.kind !== "unchanged");
      if (seg.kind === "added" || seg.kind === "removed") { markEmptyBlock(div); }
      wrap.append(div);
    }
    if (payload.commentable !== false) { wrap.append(commentButton(seg)); }
    return wrap;
  }

  function renderInline(segments) {
    segments.forEach(function (seg) {
      content.append(inlineSegmentEl(seg));
      if (seg.threads && seg.threads.length) {
        content.append(threadsEl(seg.threads));
      }
    });
  }

  function renderSplit(segments) {
    content.classList.add("pm-wide");
    var grid = document.createElement("div");
    grid.className = "pm-split";
    segments.forEach(function (seg) {
      var left = document.createElement("div");
      var right = document.createElement("div");
      left.className = "pm-cell";
      right.className = "pm-cell";
      if (seg.kind === "unchanged") {
        renderSegmentText(left, seg.text, seg.fmText, false);
        renderSegmentText(right, seg.text, seg.fmText, false);
      } else if (seg.kind === "added") {
        left.classList.add("pm-cell-empty");
        right.classList.add("pm-cell-added");
        renderSegmentText(right, seg.text, seg.fmText, true);
        markEmptyBlock(right);
      } else if (seg.kind === "removed") {
        left.classList.add("pm-cell-removed");
        renderSegmentText(left, seg.text, seg.fmText, true);
        markEmptyBlock(left);
        right.classList.add("pm-cell-empty");
      } else {
        left.classList.add("pm-cell-removed");
        right.classList.add("pm-cell-added");
        if (seg.wordDiff) {
          left.innerHTML = render(seg.wordDiff.old);
          right.innerHTML = render(seg.wordDiff.new);
          applyWordDiffMarks(left);
          applyWordDiffMarks(right);
        } else {
          renderSegmentText(left, seg.oldText, seg.fmOldText, true);
          renderSegmentText(right, seg.text, seg.fmText, true);
        }
      }
      if (payload.commentable !== false) {
        (seg.side === "LEFT" ? left : right).append(commentButton(seg));
      }
      grid.append(left, right);
      if (seg.threads && seg.threads.length) {
        var full = document.createElement("div");
        full.className = "pm-split-full";
        full.append(threadsEl(seg.threads));
        grid.append(full);
      }
    });
    content.append(grid);
  }

  function appendOutdated() {
    var threads = payload.outdatedThreads || [];
    if (!threads.length) { return; }
    var heading = document.createElement("h2");
    heading.className = "pm-outdated-heading";
    heading.textContent = "Outdated review comments";
    content.append(heading, threadsEl(threads));
  }

  function renderPatch(patch) {
    var pre = document.createElement("pre");
    pre.className = "pm-patch";
    (patch || "").split("\n").forEach(function (line) {
      var span = document.createElement("span");
      if (line.startsWith("+")) { span.className = "pm-line-add"; }
      else if (line.startsWith("-")) { span.className = "pm-line-del"; }
      else if (line.startsWith("@@")) { span.className = "pm-line-hunk"; }
      span.textContent = line;
      pre.append(span, document.createTextNode("\n"));
    });
    content.append(pre);
  }

  // ---- Entry point ----

  setupLinkPreview();

  if (payload.mode === "document") {
    // Leading YAML front matter renders as a collapsed metadata table, the
    // rest as normal markdown.
    var fm = fmParse(payload.markdown);
    var docBody = fm ? fm.rest : payload.markdown;
    content.innerHTML = render(docBody);
    // Every document is annotated with source line ranges before other
    // passes mutate the DOM: the blame gutter positions its runs from them,
    // and Copy as Markdown maps the selection back to source lines.
    var linesAnnotated = annotateBlockLines(docBody, fm ? fm.endLine : 0);
    var blameAnnotated = payload.blame && payload.blame.length && linesAnnotated;
    if (fm) {
      var fmDetails = frontMatterEl(fm.lines, false);
      // Blame treats the fence like any block: annotate its file lines.
      fmDetails.setAttribute("data-pm-lines", "1-" + fm.endLine);
      content.prepend(fmDetails);
    }
    if (payload.blameNote) { content.prepend(blameNoteEl(payload.blameNote)); }
    rewriteLocalResources(content);
    rewriteRemoteResources(content);
    setupHeadingAnchors(content);
    populateToc(reportOutline(content));
    enhance(content);
    reportStats(content);
    renderMermaid();
    if (blameAnnotated) { setupBlameGutter(payload.blame); }
  } else if (payload.mode === "diff") {
    var segments = payload.segments || [];
    if (!segments.length) {
      var note = document.createElement("p");
      note.className = "pm-empty-note";
      note.textContent = "This file is empty on both sides of the diff.";
      content.append(note);
    }
    if (payload.layout === "split") {
      renderSplit(segments);
    } else {
      renderInline(segments);
    }
    appendOutdated();
    rewriteRemoteResources(content);
    setupHeadingAnchors(content);
    populateToc(reportOutline(content));
    enhance(content);
    renderMermaid();
  } else if (payload.mode === "patch") {
    renderPatch(payload.patch);
  }
})();
