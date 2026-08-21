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
  // Content width: Standard leaves the attribute (and the default
  // cascade) alone; "wide"/"full" widen the measure via app.css.
  if (payload.width) {
    document.documentElement.dataset.width = payload.width;
  }
  // Settings theme cards: miniature, non-interactive rendering.
  if (payload.preview) {
    document.documentElement.dataset.preview = "1";
  }
  // Line numbers apply to the rendered views only — the source and patch
  // views have real per-line gutters of their own.
  if (payload.lineNumbers && !payload.preview
      && (payload.mode === "document" || payload.mode === "diff")) {
    document.documentElement.classList.add("pm-line-numbers");
  }

  // Parse through a real Marked instance: the UMD namespace's methods are
  // read-only getters, so fixWalkTokens couldn't patch walkTokens on it.
  // ---- Localized page strings (spec: app-i18n) ----
  // The render payload carries a strings table resolved Swift-side via
  // Bundle.main; keys are the English strings. Absent table or key
  // (previews, missing translation) falls back to the English key —
  // the same silent-English failure mode .strings files have, which
  // scripts/check-strings.py exists to catch.
  function pmString(key) {
    return (payload.strings && payload.strings[key]) || key;
  }
  // Templated variant: pmFormat("Comment on line {n}", {n: 12})
  function pmFormat(key, subs) {
    var out = pmString(key);
    Object.keys(subs).forEach(function (name) {
      out = out.replace("{" + name + "}", subs[name]);
    });
    return out;
  }

  var MarkedCtor = marked.Marked;
  marked = new MarkedCtor();

  // Third-party extension configs go through pmExtensions.boundStarts:
  // their unbounded start() scans are what made lexing quadratic in
  // document size (see pm-extensions.js).
  var boundStarts = typeof pmExtensions !== "undefined"
    ? pmExtensions.boundStarts
    : function (config) { return config; };
  if (typeof markedAlert === "function") {
    marked.use(boundStarts(markedAlert()));
  }
  if (typeof markedFootnote === "function") {
    marked.use(boundStarts(markedFootnote()));
  }
  // extended-syntax constructs (math/[toc]/highlight/sub/sup) shared with the
  // Quick Look static renderer.
  if (typeof pmExtensions !== "undefined") {
    marked.use({ extensions: pmExtensions.extensions() });
  }
  marked.use({ gfm: true });
  // Linear walkTokens (marked's own is quadratic in token count — see
  // pm-extensions.js). Must come after every marked.use.
  if (typeof pmExtensions !== "undefined") {
    pmExtensions.fixWalkTokens(marked);
  }

  // Outline speech bubble drawn to match the SF Symbols style used in the
  // native toolbar.
  var COMMENT_ICON =
    '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor"' +
    ' stroke-width="1.4" stroke-linejoin="round" stroke-linecap="round" aria-hidden="true">' +
    '<path d="M2.75 3h10.5c.69 0 1.25.56 1.25 1.25v5.5c0 .69-.56 1.25-1.25 1.25H8.5L5.25 13.6V11H2.75c-.69 0-1.25-.56-1.25-1.25v-5.5C1.5 3.56 2.06 3 2.75 3z"/>' +
    "</svg>";

  // Real vector icons for in-page chrome. Unicode glyphs (▸ ✓ ±) render
  // at the text font's mercy — inconsistent weights, dead whitespace in
  // the em box, no optical kinship with the native header's SF Symbols
  // (Josh's catch). These are drawn to match the SF *.circle.fill
  // family: filled circle in currentColor, white glyph.
  var SVG_NS = "http://www.w3.org/2000/svg";
  function svgIcon(kind, cls) {
    var svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("aria-hidden", "true");
    if (cls) { svg.setAttribute("class", cls); }
    function stroke(d, color, width) {
      var p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", d);
      p.setAttribute("fill", "none");
      p.setAttribute("stroke", color);
      p.setAttribute("stroke-width", width);
      p.setAttribute("stroke-linecap", "round");
      p.setAttribute("stroke-linejoin", "round");
      svg.append(p);
    }
    if (kind === "chevron") {
      stroke("M5.5 3.5 L10.5 8 L5.5 12.5", "currentColor", 2);
      return svg;
    }
    var circle = document.createElementNS(SVG_NS, "circle");
    circle.setAttribute("cx", 8);
    circle.setAttribute("cy", 8);
    circle.setAttribute("r", 7);
    circle.setAttribute("fill", "currentColor");
    svg.append(circle);
    if (kind === "check-circle") {
      stroke("M4.7 8.4 L7 10.7 L11.4 5.7", "#fff", 1.8);
    } else if (kind === "plusminus-circle") {
      stroke("M8 3.4 V6.6", "#fff", 1.5);
      stroke("M6.4 5 H9.6", "#fff", 1.5);
      stroke("M5.6 10.8 H10.4", "#fff", 1.5);
    }
    return svg;
  }

  function post(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
      window.webkit.messageHandlers.bridge.postMessage(message);
    }
  }

  function render(markdown) {
    return marked.parse(markdown || "");
  }

  // ---- Local resources (relative images/links in local documents) ----

  // Decode-then-encode a path segment: idempotent for already-encoded
  // names, correct for raw ones.
  function encodeSegment(segment) {
    var decoded = segment;
    try { decoded = decodeURIComponent(segment); } catch (e) { /* keep raw */ }
    return encodeURIComponent(decoded);
  }

  function rewriteLocalResources(root) {
    if (!payload.localResources) { return; }
    var absolute = /^([a-z][a-z0-9+.\-]*:|\/\/|#)/i;
    root.querySelectorAll("img[src], a[href]").forEach(function (el) {
      var attr = el.tagName === "IMG" ? "src" : "href";
      var value = el.getAttribute(attr);
      if (!value || absolute.test(value)) { return; }
      // The fragment/query must not be encoded into the filename —
      // "notes.md#heading" is notes.md plus an anchor, not a filename.
      var suffix = "";
      if (attr === "href") {
        var cut = value.search(/[#?]/);
        if (cut !== -1) { suffix = value.slice(cut); value = value.slice(0, cut); }
      }
      var path = value.replace(/^\//, "");
      var rewritten = "pullmark-local:///"
        + path.split("/").map(encodeSegment).join("/");
      if (attr === "href") {
        // Links carry the RAW relative path in a query parameter: URL
        // normalization (WHATWG remove-dot-segments, which eats even
        // percent-encoded dots) would otherwise swallow a leading ".."
        // before the native side ever sees it. Only the fragment
        // survives from the original suffix — a query string on a
        // local file link has no meaning.
        var frag = suffix.indexOf("#") !== -1 ? suffix.slice(suffix.indexOf("#")) : "";
        rewritten += "?pmrel=" + encodeURIComponent(value) + frag;
      } else {
        rewritten += suffix;
      }
      el.setAttribute(attr, rewritten);
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
      // encodeSegment (decode-then-encode) so author-percent-encoded
      // names aren't double-encoded into a 404.
      el.setAttribute(attr, "pullmark-remote:///" +
        resolved.split("/").map(encodeSegment).join("/") + fragment);
    });
  }

  // ---- GitHub attachment images (spec: github-user-attachments) ----
  // Attachment URLs are gated behind GitHub's own auth (404 for private
  // content without it), so the page can't load them directly. Rewrite
  // them to the pullmark-attachment scheme, whose handler fetches with
  // the user's token. Images only — links to attachments open in the
  // browser, which has the session.

  var ATTACHMENT_URL = new RegExp(
    "^https://github\\.com/(" +
    "user-attachments/assets/[0-9a-fA-F][0-9a-fA-F-]+" +
    "|[^/?#]+/[^/?#]+/assets/[0-9]+/[0-9a-fA-F][0-9a-fA-F-]+" +
    ")$");

  function rewriteAttachmentImages(root) {
    if (!payload.githubAttachments) { return; }
    root.querySelectorAll("img[src]").forEach(function (img) {
      var src = img.getAttribute("src");
      var match = src && ATTACHMENT_URL.exec(src);
      if (!match) { return; }
      img.setAttribute("data-pm-attachment", src);
      img.setAttribute("src", "pullmark-attachment:///" + match[1]);
    });
  }

  // A failed attachment (no token for private content, deleted upload,
  // offline) turns into a labeled placeholder instead of the broken-image
  // glyph — with the original URL as an escape hatch, since the browser's
  // session can render what the app cannot. Image error events don't
  // bubble; capture phase catches them all.
  document.addEventListener("error", function (event) {
    var img = event.target;
    if (!img || img.tagName !== "IMG") { return; }
    var original = img.getAttribute("data-pm-attachment");
    if (!original) { return; }
    var box = document.createElement("span");
    box.className = "pm-attachment-missing";
    var alt = img.getAttribute("alt");
    if (alt) {
      var altEl = document.createElement("span");
      altEl.className = "pm-attachment-missing-alt";
      altEl.textContent = alt;
      box.append(altEl);
    }
    var note = document.createElement("span");
    note.className = "pm-attachment-missing-note";
    note.textContent = pmString("Couldn't load this image from GitHub · ");
    var link = document.createElement("a");
    link.href = original;
    link.textContent = pmString("Open on GitHub");
    note.append(link);
    box.append(note);
    img.replaceWith(box);
  }, true);

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
  function fmLooksLikeYAML(inner) {
    // A fence with no key: value line is a thematic break + content
    // (`---` / `# Title` / `---`), not metadata.
    for (var i = 0; i < inner.length; i++) {
      if (/^[A-Za-z0-9_-]+\s*:/.test(inner[i].replace(/\r$/, ""))) { return true; }
    }
    return false;
  }

  function fmParse(markdown) {
    var lines = (markdown || "").split("\n");
    if (lines.length < 2 || lines[0].replace(/\r$/, "") !== "---") { return null; }
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() === "---") {
        var inner = lines.slice(1, i);
        if (!fmLooksLikeYAML(inner)) { return null; }
        return {
          lines: inner,
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
    var inner = lines.slice(1, -1);
    return fmLooksLikeYAML(inner) ? inner : null;
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
    summary.textContent = pmString("Front matter");
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
      // GitHub's slugger keeps underscores and hyphenates EVERY space
      // without collapsing runs ("a — b" → "a--b") — matching it exactly
      // is what makes anchors written for GitHub land here (and vice versa).
      var slug = heading.textContent.trim().toLowerCase()
        .replace(/[^\p{L}\p{N}\-_ ]+/gu, "")
        .replace(/ /g, "-");
      var unique = slug || "section";
      var counter = 1;
      while (used[unique]) { unique = slug + "-" + counter; counter += 1; }
      used[unique] = true;
      heading.id = unique;
    });
  }

  // Browser-style status pill showing where a link goes before you click it.
  // GitHub Markdown links additionally say where they'll OPEN (PullMark or
  // browser, per the user's policy), flipping live while ⌘ is held.
  function setupLinkPreview() {
    var status = document.createElement("div");
    status.className = "pm-link-status";
    document.body.append(status);
    var currentAnchor = null;
    var cmdHeld = false;

    // Mirrors RemoteDocLink.parse: github.com blob URLs and raw URLs whose
    // path ends in a Markdown extension. Approximate on purpose — this only
    // labels the pill; the click itself re-parses natively.
    function isGitHubDocLink(href) {
      var m = /^https?:\/\/(?:www\.)?github\.com\/[^/]+\/[^/]+\/blob\/[^/]+\/(.+)$/.exec(href)
        || /^https?:\/\/raw\.githubusercontent\.com\/[^/]+\/[^/]+\/(.+)$/.exec(href);
      if (!m) { return false; }
      var path = m[1].split("#")[0].split("?")[0];
      var ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
      return ["md", "markdown", "mdown", "mkd", "mdx"].indexOf(ext) !== -1;
    }

    function suffixFor(href) {
      var policy = payload.remoteLinkPolicy;
      if (!policy || !isGitHubDocLink(href)) { return ""; }
      if (policy === "ask") { return pmString("· asks where to open"); }
      var inApp = policy === "pullmark" ? !cmdHeld : cmdHeld;
      return inApp ? pmString("· opens in PullMark") : pmString("· opens in browser");
    }

    function render() {
      if (!currentAnchor) { status.style.display = "none"; return; }
      var href = currentAnchor.getAttribute("href") || "";
      if (!href) { status.style.display = "none"; return; }
      var label = href;
      ["pullmark-local:///", "pullmark-remote:///"].forEach(function (scheme) {
        if (href.startsWith(scheme)) {
          try { label = decodeURIComponent(href.slice(scheme.length)); } catch (e) { /* keep raw */ }
        }
      });
      // Two spans: the URL may ellipsize, the destination note never does.
      status.textContent = "";
      var labelEl = document.createElement("span");
      labelEl.className = "pm-link-status-label";
      labelEl.textContent = label;
      status.append(labelEl);
      var suffix = suffixFor(href);
      if (suffix) {
        var dest = document.createElement("span");
        dest.className = "pm-link-status-dest";
        dest.textContent = suffix;
        status.append(dest);
      }
      status.style.display = "flex";
    }

    document.addEventListener("mouseover", function (event) {
      currentAnchor = event.target.closest ? event.target.closest("a[href]") : null;
      render();
    });
    // metaKey rides mouse moves too, so the flip works even when key
    // events land elsewhere (sidebar focused).
    document.addEventListener("mousemove", function (event) {
      if (event.metaKey !== cmdHeld) { cmdHeld = event.metaKey; render(); }
    });
    window.addEventListener("keydown", function (event) {
      if (event.key === "Meta" && !cmdHeld) { cmdHeld = true; render(); }
    });
    window.addEventListener("keyup", function (event) {
      if (event.key === "Meta") { cmdHeld = false; render(); }
    });
    window.addEventListener("blur", function () {
      if (cmdHeld) { cmdHeld = false; render(); }
    });

    // Live policy updates (the first-click choice, Settings) reach every
    // open page without a reload.
    window.__pmSetRemoteLinkPolicy = function (policy) {
      payload.remoteLinkPolicy = policy;
      render();
    };
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
      // ...and the local-editing pencil, or mermaid blocks silently lose
      // editability.
      if (pre.classList.contains("pm-editable")) {
        div.classList.add("pm-editable");
        var pencil = pre.querySelector(".pm-edit-local");
        if (pencil) { div.append(pencil); }
      }
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
      label.textContent = pmString("Suggested change");
      if (pre.dataset.pmLines) { wrap.dataset.pmLines = pre.dataset.pmLines; }
      pre.replaceWith(wrap);
      wrap.append(label, pre);
    });
    root.querySelectorAll("pre code").forEach(function (el) {
      if (el.classList.contains("language-suggestion")) { return; }
      // Discussion hunk excerpts highlight per line at build time;
      // auto-detection here would colorize the plain (no-language) ones.
      if (el.closest(".pm-discussion-hunk")) { return; }
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
        empty.textContent = pmString("No headings");
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
        // Thread cards and marker chrome are annotations, not document
        // content — they never count toward words or reading time.
        return node.parentElement &&
          node.parentElement.closest(".pm-toc, .pm-frontmatter, .katex, .pm-annotation, .pm-threads")
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
  // Outline/⌘K/anchor jumps: the destination highlights immediately and
  // the spy stays quiet while the glide is in flight — every heading
  // between here and there lighting up in turn read as noise. User
  // input interrupts the suppression instantly; the spy resyncs once
  // the scroll settles (and self-corrects if the landing differs).
  var __jumpTarget = null;
  var __jumpSettleTimer = null;
  function armJumpSettle() {
    if (__jumpSettleTimer) { clearTimeout(__jumpSettleTimer); }
    __jumpSettleTimer = setTimeout(function () {
      __jumpTarget = null;
      __jumpSettleTimer = null;
      updateActiveSection();
    }, 180);
  }
  function cancelJump() {
    if (!__jumpTarget) { return; }
    __jumpTarget = null;
    if (__jumpSettleTimer) { clearTimeout(__jumpSettleTimer); __jumpSettleTimer = null; }
    updateActiveSection();
  }
  window.__pmJumpTo = function (id, smooth) {
    var el = document.getElementById(id);
    if (!el) { return; }
    __jumpTarget = id;
    if (id !== __activeSection) {
      __activeSection = id;
      post({ type: "activeSection", id: id });
    }
    el.scrollIntoView({ behavior: smooth ? "smooth" : "auto", block: "start" });
    armJumpSettle();
  };
  ["wheel", "mousedown", "keydown", "touchstart"].forEach(function (type) {
    window.addEventListener(type, cancelJump, { passive: true, capture: true });
  });
  (function () {
    var pending = false;
    window.addEventListener("scroll", function () {
      if (__jumpTarget) { armJumpSettle(); return; }
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
          // KaTeX ships an invisible MathML tree carrying the raw TeX —
          // matches there inflate the count and scroll to nothing.
          if (el.closest && el.closest(".katex-mathml")) {
            return NodeFilter.FILTER_REJECT;
          }
          // Review-thread text is annotation, not the document — find
          // stays about the content being read (spec interaction).
          if (el.closest && el.closest(".pm-threads, .pm-annotation")) {
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
      theme: darkQuery.matches ? "dark" : "default",
      themeVariables: {
        // Edge-label chips ("yes"/"no") default to an opaque gray that
        // clashes on dark and themed paper — sit them on the page surface
        // instead. Recomputed on every render, so appearance flips and
        // reading themes both track.
        edgeLabelBackground: getComputedStyle(document.body).backgroundColor
      }
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
        plain = plain || new MarkedCtor({ gfm: true });
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
        if (k === 0 && (tok.type === "list" || tok.type === "table")) {
          stampSubUnits(els[ei], tok, startLine);
        }
        ei += 1;
      }
      line = startLine + countNewlines(raw);
      srcPos = idx + raw.length;
      i += 1;
    }
    return true;
  }

  // ---- Sub-unit stamping (spec: nested-comment-targets) ----
  // Inside container blocks the meaningful comment target is the nested
  // structural unit: each list item and each table row is stamped with
  // data-pm-sublines="start-end". A separate attribute — never
  // data-pm-lines — so the block annotation's other consumers (copy,
  // blame, line numbers, editing) can't see the stamps; only the
  // commenting surfaces read both.

  function subUnitRange(el) {
    var m = /^(\d+)-(\d+)$/.exec(
      (el.getAttribute && el.getAttribute("data-pm-sublines")) || "");
    return m ? [+m[1], +m[2]] : null;
  }

  // Item raws concatenate to their list's raw line-for-line, at every
  // nesting depth — nested raws are de-indented but keep the exact line
  // structure, loose blanks included (verified against the vendored
  // marked; its intra-item TEXT tokens do not have this property, which
  // is why the walk below never consults them).
  function stampListItems(listEl, listTok, startLine) {
    if (!listEl) { return; }
    var lis = [];
    for (var c = listEl.firstElementChild; c; c = c.nextElementSibling) {
      if (c.tagName === "LI") { lis.push(c); }
    }
    var line = startLine;
    (listTok.items || []).forEach(function (item, i) {
      var raw = item.raw || "";
      var itemStart = line;
      line += (raw.match(/\n/g) || []).length;
      if (i >= lis.length) { return; }
      var trimmed = raw.replace(/\n+$/, "");
      var itemEnd = itemStart + (trimmed.match(/\n/g) || []).length;
      lis[i].setAttribute("data-pm-sublines", itemStart + "-" + itemEnd);
      stampNestedLists(lis[i], item, raw, itemStart);
    });
  }

  // A nested list's own raw is de-indented, so it can't be located by
  // indexOf in the parent item's raw. Its first item's first line CAN:
  // de-indenting only strips leading whitespace, so the parent line is
  // whitespace + that line, matched with a moving cursor.
  function stampNestedLists(itemEl, itemTok, itemRaw, itemStart) {
    var nestedEls = [];
    for (var c = itemEl.firstElementChild; c; c = c.nextElementSibling) {
      if (c.tagName === "UL" || c.tagName === "OL") { nestedEls.push(c); }
    }
    if (!nestedEls.length) { return; }
    var nestedToks = (itemTok.tokens || []).filter(function (t) {
      return t.type === "list";
    });
    var itemLines = itemRaw.split("\n");
    var cursor = 1; // a nested list never starts on the marker line
    var fence = null; // a list-shaped line inside a fence is code
    nestedToks.forEach(function (tok, i) {
      if (i >= nestedEls.length) { return; }
      var first = ((tok.items && tok.items[0] && tok.items[0].raw) || "")
        .split("\n")[0];
      if (!first) { return; }
      for (var li = cursor; li < itemLines.length; li++) {
        var lineText = itemLines[li];
        var bare = lineText.trim().slice(0, 3);
        if (fence) {
          if (bare === fence) { fence = null; }
          continue;
        }
        if (bare === "```" || bare === "~~~") { fence = bare; continue; }
        if (lineText.length >= first.length
            && lineText.slice(-first.length) === first
            && lineText.slice(0, lineText.length - first.length).trim() === "") {
          stampListItems(nestedEls[i], tok, itemStart + li);
          // Past the matched list's LAST line, not onto it — marked
          // trims the trailing newline from a nested list's raw, and a
          // cursor left on the last line lets a sibling list whose
          // first item repeats that text match the wrong region.
          cursor = li + ((tok.raw || "").replace(/\n+$/, "").match(/\n/g) || []).length + 1;
          break;
        }
      }
    });
  }

  // GFM table geometry is fixed: header line, delimiter line, then one
  // line per body row. The header pair is one target; each body row its
  // own.
  function stampTableRows(tableEl, tableTok, startLine) {
    if (!tableEl) { return; }
    var headRow = tableEl.querySelector(":scope > thead > tr");
    if (headRow) {
      headRow.setAttribute("data-pm-sublines", startLine + "-" + (startLine + 1));
    }
    var bodyRows = tableEl.querySelectorAll(":scope > tbody > tr");
    var count = Math.min(bodyRows.length, (tableTok.rows || []).length);
    for (var r = 0; r < count; r++) {
      var lineNo = startLine + 2 + r;
      bodyRows[r].setAttribute("data-pm-sublines", lineNo + "-" + lineNo);
    }
  }

  function stampSubUnits(el, tok, startLine) {
    if (!el) { return; }
    if (tok.type === "list") {
      if (el.tagName === "UL" || el.tagName === "OL") {
        stampListItems(el, tok, startLine);
      }
    } else if (tok.type === "table" && el.tagName === "TABLE") {
      stampTableRows(el, tok, startLine);
    }
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
        sha.title = pmString("View commit on GitHub");
      } else {
        sha = document.createElement("button");
        sha.type = "button";
        sha.title = pmString("Copy full SHA");
        sha.addEventListener("click", function (event) {
          event.stopPropagation();
          post({ type: "copySHA", sha: run.sha });
          sha.textContent = pmString("copied");
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
      hint.textContent = pmString("Click the gutter for history");
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
          // Hidden while its in-place editor is open: a zero rect would
          // smear this run's gutter entry to the viewport top.
          if (!block.el.offsetHeight) { return; }
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

  // ---- Line numbers (rendered views) ----
  // Rendered lines don't correspond to source lines, so numbering is per
  // block: each block's START line as a label in the left gutter, the
  // full range in its tooltip. Document/Result blocks derive labels from
  // their live data-pm-lines annotations (edits re-stamp those); diff
  // blocks are stamped with data-pm-num/-num-tip at render time, where
  // the per-side coordinates are known. Split cells are the exception —
  // their labels are grid items (see app.css), only nudged here.

  function rangeText(start, end) {
    return start === end ? pmFormat("Line {n}", {n: start})
                         : pmFormat("Lines {a}–{b}", {a: start, b: end});
  }

  // The y of the first line of visible content — not the box top: a
  // heading's interior margin would misplace a label aligned to the box
  // (the comment rail learned this the hard way).
  function firstContentTop(el) {
    var wraps;
    if (el.classList.contains("pm-cell")) {
      wraps = [el];
    } else if (el.classList.contains("pm-block")) {
      wraps = el.querySelectorAll(":scope > div:not(.pm-threads)");
    } else {
      return el.getBoundingClientRect().top;
    }
    for (var i = 0; i < wraps.length; i++) {
      for (var c = wraps[i].firstElementChild; c; c = c.nextElementSibling) {
        if (c.getBoundingClientRect().height > 0) {
          return c.getBoundingClientRect().top;
        }
      }
    }
    return el.getBoundingClientRect().top;
  }

  var lnLayer = null;

  function refreshLineNumbers() {
    if (!lnLayer
        || !document.documentElement.classList.contains("pm-line-numbers")) {
      return;
    }
    lnLayer.textContent = "";
    var cRect = content.getBoundingClientRect();
    var padLeft = parseFloat(getComputedStyle(content).paddingLeft) || 0;
    var targets = [];
    content.querySelectorAll("[data-pm-num], [data-pm-lines]")
      .forEach(function (el) {
        if (el.closest(".pm-split")) { return; }
        var num, tip, old = false;
        if (el.hasAttribute("data-pm-num")) {
          num = el.getAttribute("data-pm-num");
          tip = el.getAttribute("data-pm-num-tip") || "";
          old = el.hasAttribute("data-pm-num-old");
        } else {
          // Nested annotations (edit-mode splits) label the outer block only.
          if (el.parentElement
              && el.parentElement.closest("[data-pm-lines]")) { return; }
          var m = /^(\d+)-(\d+)$/.exec(el.getAttribute("data-pm-lines") || "");
          if (!m) { return; }
          num = m[1];
          tip = rangeText(+m[1], +m[2]);
        }
        // Hidden while its in-place editor is open.
        if (!el.offsetHeight) { return; }
        targets.push({ el: el, num: num, tip: tip, old: old });
      });
    // One aligned column per page, 12px clear of the widest box a block
    // can paint. Diff blocks and the open block editor bleed 14px left of
    // the text edge (negative margins), so diff and editable pages hold
    // the column out by that much — constant per page, so a number can
    // never drift out of the column and the column never jumps while an
    // editor opens.
    var bleed = (payload.mode === "diff" || payload.editable) ? 14 : 0;
    var labelLeft = Math.round(padLeft - bleed - 12 - 36);
    targets.forEach(function (t) {
      var label = document.createElement("span");
      label.className = "pm-linenum" + (t.old ? " pm-linenum-old" : "");
      label.textContent = t.num;
      label.title = t.tip;
      label.style.left = labelLeft + "px";
      label.style.top = Math.round(firstContentTop(t.el) - cRect.top) + "px";
      lnLayer.append(label);
    });
    content.querySelectorAll(".pm-split > .pm-linenum").forEach(function (label) {
      var cell = label.nextElementSibling;
      if (!cell || !cell.offsetHeight || !label.textContent) { return; }
      label.style.paddingTop = Math.round(
        firstContentTop(cell) - cell.getBoundingClientRect().top) + "px";
    });
  }

  function setupLineNumbers() {
    if (lnLayer || payload.preview) { return; }
    lnLayer = document.createElement("div");
    lnLayer.className = "pm-linenum-layer";
    content.append(lnLayer);
    refreshLineNumbers();
    if (typeof ResizeObserver === "function") {
      new ResizeObserver(refreshLineNumbers).observe(content);
    }
    window.addEventListener("resize", refreshLineNumbers);
  }

  // Live Settings flip: reserve/release the gutter and (re)build in place.
  // An explicit payload false is a page-level opt-out (PR overview body,
  // preview sheets) — those ignore the flip too.
  window.__pmSetLineNumbers = function (on) {
    if (payload.preview || payload.lineNumbers === false
        || (payload.mode !== "document" && payload.mode !== "diff")) { return; }
    document.documentElement.classList.toggle("pm-line-numbers", !!on);
    if (on) { setupLineNumbers(); }
    refreshLineNumbers();
  };

  // ---- Result-view thread markers (spec §1) ----
  // A small comment badge in the right margin, aligned with the anchored
  // block; the anchored range gets a subtle tinted highlight. Threads map
  // to blocks via the data-pm-lines annotations by containment only — no
  // nearest-block guessing (a misanchored highlight in a reading view is
  // worse than an absent one). Multiple threads on one block cluster into
  // a single badge; pending comments get their own, visually distinct one.

  function setupThreadMarkers(threads, pendings) {
    document.documentElement.classList.add("pm-markers-on");

    var layer = document.createElement("div");
    layer.className = "pm-marker-layer pm-annotation";
    content.append(layer);

    function blockFor(line) {
      for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
        var m = /^(\d+)-(\d+)$/.exec(
          (el.getAttribute && el.getAttribute("data-pm-lines")) || "");
        if (!(m && +m[1] <= line && line <= +m[2])) { continue; }
        // The deepest unit containing the line anchors the thread — the
        // item or row, not the whole list or table. `<=` so a nested
        // item (later in document order, never wider) beats its parent.
        var best = el;
        var bestSpan = +m[2] - +m[1];
        el.querySelectorAll("[data-pm-sublines]").forEach(function (unit) {
          var r = subUnitRange(unit);
          if (r && r[0] <= line && line <= r[1] && r[1] - r[0] <= bestSpan) {
            best = unit;
            bestSpan = r[1] - r[0];
          }
        });
        return best;
      }
      return null;
    }

    var clusters = [];
    // Open state is per kind: the blue badge opens the published cards,
    // the yellow badge the pending ones — the split visual honors the
    // clicked control (clicking the highlight itself opens both).
    function clusterFor(el) {
      for (var i = 0; i < clusters.length; i++) {
        if (clusters[i].el === el) { return clusters[i]; }
      }
      var cluster = { el: el, threads: [], pendings: [],
                      threadTint: [], pendingTint: [],
                      openThreads: false, openPending: false,
                      card: null, badge: null, pendingBadge: null };
      clusters.push(cluster);
      return cluster;
    }

    // A thread anchored to one unit can still cover a range that spans
    // its siblings (a multi-line comment across list items): those leaf
    // units get the anchor tint too, so the highlight shows the true
    // extent. The badge stays on the anchor unit — the range's end,
    // matching where GitHub pins multi-line comments.
    function tintExtras(anchor, startLine, endLine) {
      var extras = [];
      if (!anchor.hasAttribute || !anchor.hasAttribute("data-pm-sublines")) {
        return extras;
      }
      var blockEl = anchor;
      while (blockEl.parentElement && blockEl.parentElement !== content) {
        blockEl = blockEl.parentElement;
      }
      blockEl.querySelectorAll("[data-pm-sublines]").forEach(function (unit) {
        if (unit === anchor || unit.querySelector("[data-pm-sublines]")) { return; }
        var r = subUnitRange(unit);
        if (r && r[0] <= endLine && startLine <= r[1]) { extras.push(unit); }
      });
      return extras;
    }

    function mergeTint(into, extras) {
      extras.forEach(function (el) {
        if (into.indexOf(el) === -1) { into.push(el); }
      });
    }

    function clusterOpen(cluster) {
      return cluster.openThreads || cluster.openPending;
    }
    (threads || []).forEach(function (thread) {
      var el = blockFor(thread.anchorEnd || thread.anchorStart);
      if (el) {
        var cluster = clusterFor(el);
        cluster.threads.push(thread);
        mergeTint(cluster.threadTint,
                  tintExtras(el, thread.anchorStart || thread.anchorEnd,
                             thread.anchorEnd || thread.anchorStart));
      }
    });
    (pendings || []).forEach(function (item) {
      var el = blockFor(item.lineEnd || item.lineStart);
      if (el) {
        var cluster = clusterFor(el);
        cluster.pendings.push(item);
        mergeTint(cluster.pendingTint,
                  tintExtras(el, item.lineStart || item.lineEnd,
                             item.lineEnd || item.lineStart));
      }
    });

    function visibleThreads(cluster) {
      return cluster.threads.filter(function (t) {
        return t.resolved !== true || resolvedShown;
      });
    }

    function commentCount(list) {
      return list.reduce(function (sum, t) {
        return sum + (t.comments || []).length;
      }, 0);
    }

    function renderCard(cluster) {
      // A re-render destroys any reply/edit mini-composer inside the old
      // card: flush their typed text to drafts first (debounce can hold
      // up to 400ms of it).
      if (cluster.card) { flushLiveComposerDrafts(cluster.card); cluster.card.remove(); }
      var card = document.createElement("div");
      card.className = "pm-result-card pm-annotation";
      var visible = visibleThreads(cluster);
      if (cluster.openThreads && visible.length) { card.append(threadsEl(visible)); }
      if (cluster.openPending && cluster.pendings.length) {
        card.append(pendingEl(cluster.pendings));
      }
      // Cards always open at content level: a sub-unit anchor (list
      // item, table row) hoists to its enclosing block — a full-width
      // card doesn't belong inside a list or a scrolling table.
      var host = cluster.el;
      while (host.parentElement && host.parentElement !== content) {
        host = host.parentElement;
      }
      host.after(card);
      cluster.card = card;
    }

    function collapseCluster(cluster) {
      cluster.openThreads = false;
      cluster.openPending = false;
      cluster.el.classList.remove("pm-anchor-open");
      if (cluster.card) { flushLiveComposerDrafts(cluster.card); cluster.card.remove(); cluster.card = null; }
      positionMarkers();
    }

    function syncCard(cluster) {
      if (clusterOpen(cluster)) {
        cluster.el.classList.add("pm-anchor-open");
        renderCard(cluster);
      } else {
        cluster.el.classList.remove("pm-anchor-open");
        if (cluster.card) { flushLiveComposerDrafts(cluster.card); cluster.card.remove(); cluster.card = null; }
      }
      positionMarkers();
    }

    function toggleKind(cluster, kind) {
      if (kind === "pending") { cluster.openPending = !cluster.openPending; }
      else { cluster.openThreads = !cluster.openThreads; }
      syncCard(cluster);
    }

    // The highlight itself toggles the whole cluster: everything open when
    // any part is closed, everything closed otherwise.
    function toggleCluster(cluster) {
      if (clusterOpen(cluster)) { collapseCluster(cluster); return; }
      cluster.openThreads = visibleThreads(cluster).length > 0;
      cluster.openPending = cluster.pendings.length > 0;
      syncCard(cluster);
    }

    function badgeEl(cluster, pending) {
      var badge = document.createElement("button");
      badge.type = "button";
      badge.className = "pm-marker" + (pending ? " pm-marker-pending" : "");
      badge.innerHTML = COMMENT_ICON;
      var count = document.createElement("span");
      count.className = "pm-marker-count";
      badge.append(count);
      badge.addEventListener("click", function (event) {
        event.stopPropagation();
        toggleKind(cluster, pending ? "pending" : "threads");
      });
      return badge;
    }

    clusters.forEach(function (cluster) {
      cluster.badge = badgeEl(cluster, false);
      layer.append(cluster.badge);
      if (cluster.pendings.length) {
        cluster.pendingBadge = badgeEl(cluster, true);
        layer.append(cluster.pendingBadge);
      }
      // Clicking the highlight expands too; links, media, buttons, and
      // real text selections keep their own behavior.
      cluster.el.addEventListener("click", function (event) {
        if (event.target.closest("a, button, img, .mermaid, .katex, input, textarea")) { return; }
        if (!cluster.el.classList.contains("pm-commented")
            && !cluster.el.classList.contains("pm-pending-anchor")) { return; }
        var selection = window.getSelection();
        if (selection && !selection.isCollapsed) { return; }
        toggleCluster(cluster);
      });
    });

    // Quiet end-of-document control revealing resolved conversations;
    // mirrored by View ▸ Show Resolved Conversations through the bridge.
    var resolvedControl = null;
    var resolvedCount = clusters.reduce(function (sum, cluster) {
      return sum + cluster.threads.filter(function (t) {
        return t.resolved === true;
      }).length;
    }, 0);
    if (resolvedCount) {
      resolvedControl = document.createElement("button");
      resolvedControl.type = "button";
      resolvedControl.className = "pm-resolved-control pm-annotation";
      content.append(resolvedControl);
      resolvedControl.addEventListener("click", function () {
        window.__pmSetResolvedShown(!resolvedShown);
        post({ type: "resolvedVisibility", visible: resolvedShown });
      });
    }
    function updateResolvedControl() {
      if (!resolvedControl) { return; }
      // Symmetric verb labels: both states say what the click will do.
      resolvedControl.textContent = pmFormat(resolvedShown
        ? (resolvedCount === 1 ? "Hide {n} resolved conversation" : "Hide {n} resolved conversations")
        : (resolvedCount === 1 ? "Show {n} resolved conversation" : "Show {n} resolved conversations"),
        {n: resolvedCount});
    }

    function applyVisibility() {
      clusters.forEach(function (cluster) {
        var visible = visibleThreads(cluster);
        var hasThreads = visible.length > 0;
        var hasPending = cluster.pendings.length > 0;
        cluster.el.classList.toggle("pm-commented", hasThreads);
        cluster.el.classList.toggle("pm-pending-anchor", hasPending);
        cluster.threadTint.forEach(function (t) {
          t.classList.toggle("pm-commented", hasThreads);
        });
        cluster.pendingTint.forEach(function (t) {
          t.classList.toggle("pm-pending-anchor", hasPending);
        });
        cluster.badge.style.display = hasThreads ? "" : "none";
        if (hasThreads) {
          var count = commentCount(visible);
          cluster.badge.querySelector(".pm-marker-count").textContent = count;
          cluster.badge.classList.toggle("pm-marker-resolved",
            visible.every(function (t) { return t.resolved === true; }));
          cluster.badge.title = pmFormat(count === 1
            ? "{n} comment — click to expand"
            : "{n} comments — click to expand", {n: count});
          cluster.badge.setAttribute("aria-label", cluster.badge.title);
        }
        if (cluster.pendingBadge) {
          cluster.pendingBadge.style.display = hasPending ? "" : "none";
          cluster.pendingBadge.querySelector(".pm-marker-count").textContent =
            cluster.pendings.length;
          cluster.pendingBadge.title = pmString(cluster.pendings.length === 1
            ? "Pending comment — click to expand"
            : "Pending comments — click to expand");
          cluster.pendingBadge.setAttribute("aria-label", cluster.pendingBadge.title);
        }
        if (clusterOpen(cluster)) {
          if (!hasThreads) { cluster.openThreads = false; }
          if (!hasPending) { cluster.openPending = false; }
          syncCard(cluster);
        }
      });
      updateResolvedControl();
      positionMarkers();
    }

    // Open-card state survives Swift-side re-renders (reaction fold-in,
    // reply/edit/delete reload): the proxy reads the open anchors before
    // the reload and re-applies them once the fresh page has built its
    // clusters. Anchored by the element's line-range key; a sub-unit
    // anchor gets an "s:" prefix so a single-item list's item can never
    // be confused with its block (their ranges coincide).
    function clusterAnchorKey(el) {
      var sub = el.getAttribute("data-pm-sublines");
      if (sub) { return "s:" + sub; }
      return el.getAttribute("data-pm-lines") || "";
    }
    window.__pmOpenThreadAnchors = function () {
      var open = [];
      clusters.forEach(function (cluster) {
        if (!clusterOpen(cluster)) { return; }
        open.push({ anchor: clusterAnchorKey(cluster.el),
                    threads: cluster.openThreads, pending: cluster.openPending });
      });
      return open;
    };
    window.__pmRestoreOpenThreadAnchors = function (list) {
      (list || []).forEach(function (item) {
        clusters.forEach(function (cluster) {
          if (clusterAnchorKey(cluster.el) !== item.anchor) { return; }
          cluster.openThreads = !!item.threads && visibleThreads(cluster).length > 0;
          cluster.openPending = !!item.pending && cluster.pendings.length > 0;
          syncCard(cluster);
        });
      });
    };

    function positionMarkers() {
      var cRect = content.getBoundingClientRect();
      // In the margin when the content column leaves room for the WIDEST
      // badge (plus clearance); otherwise overlaying inside the content
      // edge, inset by each badge's real width. A badge must never extend
      // the document's scrollable width: absolutely positioned boxes
      // still grow scrollWidth, and one badge past the edge gives the
      // whole page a horizontal scrollbar. clientWidth, not innerWidth —
      // classic (non-overlay) scrollbars eat into the viewport.
      var viewport = document.documentElement.clientWidth;
      var widest = 0;
      clusters.forEach(function (cluster) {
        [cluster.badge, cluster.pendingBadge].forEach(function (badge) {
          if (!badge || badge.style.display === "none") { return; }
          widest = Math.max(widest, badge.offsetWidth);
        });
      });
      var inMargin = viewport - cRect.right >= widest + 18;
      clusters.forEach(function (cluster) {
        var rect = cluster.el.getBoundingClientRect();
        var offset = 0;
        [cluster.badge, cluster.pendingBadge].forEach(function (badge) {
          if (!badge || badge.style.display === "none") { return; }
          var x = inMargin ? cRect.width + 10
                           : cRect.width - badge.offsetWidth - 12;
          badge.style.left = Math.round(x) + "px";
          badge.style.top = Math.round(rect.top - cRect.top + offset) + "px";
          offset += 28;
        });
      });
    }

    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") { return; }
      var closed = false;
      clusters.forEach(function (cluster) {
        if (clusterOpen(cluster)) { collapseCluster(cluster); closed = true; }
      });
      if (closed) {
        event.preventDefault();
        event.stopPropagation();
      }
    });

    resolvedListeners.push(applyVisibility);
    applyVisibility();
    if (typeof ResizeObserver === "function") {
      new ResizeObserver(positionMarkers).observe(content);
    }
    window.addEventListener("resize", positionMarkers);
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
    label.textContent = pmString("(empty)");
    div.append(label);
  }

  // The bubble opens an empty in-page composer beneath the block; a text
  // selection inside the block narrows the range first (spec §5).
  function commentButton(seg, target) {
    var btn = document.createElement("button");
    btn.className = "pm-comment-btn";
    btn.type = "button";
    btn.innerHTML = COMMENT_ICON;
    btn.title = pmFormat(seg.side === "LEFT"
      ? "Comment on old lines {a}–{b}" : "Comment on new lines {a}–{b}",
      {a: seg.lineStart, b: seg.lineEnd});
    btn.setAttribute("aria-label", btn.title);
    btn.addEventListener("click", function (event) {
      event.stopPropagation();
      composerForSegment(seg, target, false);
    });
    return btn;
  }




  function threadsEl(threads) {
    var wrap = document.createElement("div");
    wrap.className = "pm-threads";
    threads.forEach(function (thread) {
      var box = document.createElement("div");
      box.className = "pm-thread";
      // The root id names the card for __pmRevealThread (the overview's
      // View in File jump) wherever cards render.
      if (thread.rootID) { box.setAttribute("data-pm-root", thread.rootID); }
      var header = document.createElement("div");
      header.className = "pm-thread-header";
      if (thread.resolved === true) {
        // Resolved threads collapse to a one-line header (author ·
        // "Resolved") that expands on click — settled conversations never
        // carry full-prominence cards (spec §2). The one-liner lives IN
        // the header row, so expanding folds it into the card header —
        // one header, "Resolved" said once.
        box.classList.add("pm-thread-resolved", "pm-thread-collapsed");
        var summary = document.createElement("button");
        summary.type = "button";
        summary.className = "pm-thread-summary";
        var author = (thread.comments && thread.comments[0] && thread.comments[0].author) || "";
        summary.textContent = (author ? author + " · " : "") + pmString("Resolved");
        // A real disclosure chevron that rotates on expand — one icon,
        // one width, no glyph-swap wobble.
        summary.prepend(svgIcon("chevron", "pm-summary-chevron"));
        summary.setAttribute("aria-expanded", "false");
        summary.addEventListener("click", function () {
          var collapsed = box.classList.toggle("pm-thread-collapsed");
          summary.setAttribute("aria-expanded", collapsed ? "false" : "true");
        });
        header.append(summary);
      }
      if (thread.lineLabel) {
        var label = document.createElement("div");
        label.className = "pm-thread-line";
        label.textContent = thread.lineLabel;
        header.append(label);
      }
      if (thread.rootID) {
        var actions = document.createElement("div");
        actions.className = "pm-thread-actions";
        var reply = document.createElement("button");
        reply.type = "button";
        reply.textContent = pmString("Reply");
        reply.addEventListener("click", function () {
          toggleReplyComposer(box, thread.rootID, reply);
        });
        actions.append(reply);
        if (thread.resolved !== null && thread.resolved !== undefined) {
          var resolve = document.createElement("button");
          resolve.type = "button";
          resolve.textContent = thread.resolved ? pmString("Unresolve") : pmString("Resolve");
          resolve.addEventListener("click", function () {
            post({ type: "threadResolve", rootID: thread.rootID, resolved: !thread.resolved });
          });
          actions.append(resolve);
        }
        header.append(actions);
      }
      box.append(header);
      (thread.comments || []).forEach(function (c) {
        box.append(commentEl(c));
      });
      wrap.append(box);
    });
    return wrap;
  }

  // One published comment card: byline (with GitHub's quiet "edited"
  // affordance), rendered body, the ⋯ menu on the viewer's own comments,
  // and the reaction chips at the foot. Pending comments never come
  // through here (pendingEl) — no reaction UI, no menu (spec).
  function commentEl(c) {
    var comment = document.createElement("div");
    comment.className = "pm-thread-comment";
    var head = document.createElement("div");
    head.className = "pm-thread-head";
    // Conversation cards carry avatars (spec: pr-cockpit); thread cards
    // stay text-only — their headers already carry line labels and
    // actions, and a face per excerpt would crowd them.
    if (c.source === "conversation") {
      head.append(conversationAvatarEl(c.author, c.avatarUrl));
    }
    var authorEl = document.createElement("span");
    authorEl.textContent = c.author;
    head.append(authorEl);
    // The bot tag annotates the NAME, not the date — GitHub's order.
    if (c.bot) {
      var botTag = document.createElement("span");
      botTag.className = "pm-bot-tag";
      botTag.textContent = pmString("bot");
      head.append(botTag);
    }
    head.append(document.createTextNode(c.dateLabel ? " · " + c.dateLabel : ""));
    if (c.edited) {
      var edited = document.createElement("span");
      edited.className = "pm-edited";
      edited.textContent = pmString(" · edited");
      head.append(edited);
    }
    var body = document.createElement("div");
    body.className = "pm-thread-body";
    body.innerHTML = render(c.body);
    comment.append(head, body);
    if (c.id && c.viewerOwned) {
      comment.classList.add("pm-owned");
      comment.append(commentMenuButton(c, comment, body));
    }
    if (c.id && ((c.reactions && c.reactions.length) || c.canReact)) {
      reactionComments[c.id] = c;
      var bar = document.createElement("div");
      bar.className = "pm-reactions";
      bar.setAttribute("data-pm-comment", c.id);
      renderReactionBar(bar, c);
      comment.append(bar);
    }
    return comment;
  }

  // ---- Emoji reactions on comments (spec) ----
  // Chips (emoji + count) at each published comment's foot, the viewer's
  // own tinted; a smiley on hover opens a picker limited to GitHub's
  // eight. Toggles are optimistic: the chip flips immediately, the bridge
  // posts the write, and Swift calls __pmReactionRevert on failure.

  var REACTION_SET = [
    ["+1", "👍"], ["-1", "👎"], ["laugh", "😄"], ["hooray", "🎉"],
    ["confused", "😕"], ["heart", "❤️"], ["rocket", "🚀"], ["eyes", "👀"]
  ];

  function reactionEmoji(content) {
    for (var i = 0; i < REACTION_SET.length; i++) {
      if (REACTION_SET[i][0] === content) { return REACTION_SET[i][1]; }
    }
    return content;
  }

  function reactionRank(content) {
    for (var i = 0; i < REACTION_SET.length; i++) {
      if (REACTION_SET[i][0] === content) { return i; }
    }
    return REACTION_SET.length;
  }

  // Live payload object per published comment id — the source of truth
  // the bars re-render from, so optimistic state survives a card being
  // collapsed and re-expanded.
  var reactionComments = {};

  function reactionChipOf(c, content) {
    var list = c.reactions || [];
    for (var i = 0; i < list.length; i++) {
      if (list[i].content === content) { return list[i]; }
    }
    return null;
  }

  // Chip math mirroring CommentReactions.applied: counts and the mine
  // flag move together; a chip at zero disappears; new chips slot into
  // canonical order.
  function applyReactionLocal(c, content, reacted) {
    var chip = reactionChipOf(c, content);
    if (reacted) {
      if (chip) {
        if (!chip.mine) { chip.count += 1; chip.mine = true; }
        return;
      }
      if (!c.reactions) { c.reactions = []; }
      var entry = { content: content, count: 1, mine: true };
      var at = c.reactions.length;
      for (var i = 0; i < c.reactions.length; i++) {
        if (reactionRank(c.reactions[i].content) > reactionRank(content)) { at = i; break; }
      }
      c.reactions.splice(at, 0, entry);
    } else if (chip && chip.mine) {
      chip.count -= 1;
      chip.mine = false;
      if (chip.count <= 0) { c.reactions.splice(c.reactions.indexOf(chip), 1); }
    }
  }

  function refreshReactionBars(id) {
    var c = reactionComments[id];
    if (!c) { return; }
    // Ids are server ints today, but they pass through attribute selectors
    // — escape rather than trust the shape.
    document.querySelectorAll('.pm-reactions[data-pm-comment="' + CSS.escape(String(id)) + '"]')
      .forEach(function (bar) { renderReactionBar(bar, c); });
  }

  function toggleReaction(c, content) {
    closeTransientPopup();
    var chip = reactionChipOf(c, content);
    var reacted = !(chip && chip.mine);
    applyReactionLocal(c, content, reacted);
    refreshReactionBars(c.id);
    post({ type: "reactionToggle", commentID: c.id, content: content, reacted: reacted,
           source: c.source });
  }

  // A failed write reverts the optimistic flip (Swift calls this with the
  // attempted direction) and Swift surfaces the error natively.
  window.__pmReactionRevert = function (commentID, content, attempted) {
    var c = reactionComments[commentID];
    if (!c) { return; }
    applyReactionLocal(c, content, !attempted);
    refreshReactionBars(commentID);
  };

  // Smiley in the SF-Symbols outline style of COMMENT_ICON.
  var SMILEY_ICON =
    '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor"' +
    ' stroke-width="1.4" stroke-linecap="round" aria-hidden="true">' +
    '<circle cx="8" cy="8" r="6.25"/>' +
    '<path d="M5.4 9.5a3.4 3.4 0 0 0 5.2 0"/>' +
    '<circle cx="5.9" cy="6.4" r="0.5" fill="currentColor" stroke="none"/>' +
    '<circle cx="10.1" cy="6.4" r="0.5" fill="currentColor" stroke="none"/>' +
    "</svg>";

  function renderReactionBar(bar, c) {
    bar.textContent = "";
    (c.reactions || []).forEach(function (chip) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "pm-reaction-chip" + (chip.mine ? " pm-reaction-mine" : "");
      btn.textContent = reactionEmoji(chip.content) + " " + chip.count;
      var label = (chip.mine ? "Remove your " : "React with ") + reactionEmoji(chip.content);
      btn.setAttribute("aria-pressed", chip.mine ? "true" : "false");
      // The tooltip names the reactors ("You and sam-ortega reacted");
      // the accessible label stays the action. Chips without roster
      // data (optimistic toggles, missing meta) fall back to the action.
      if (c.canReact) {
        btn.title = chip.who || label;
        btn.setAttribute("aria-label", label);
        btn.addEventListener("click", function () { toggleReaction(c, chip.content); });
      } else {
        if (chip.who) { btn.title = chip.who; }
        btn.disabled = true;
      }
      bar.append(btn);
    });
    if (c.canReact) {
      var add = document.createElement("button");
      add.type = "button";
      add.className = "pm-react-add";
      add.innerHTML = SMILEY_ICON;
      add.title = pmString("Add reaction");
      add.setAttribute("aria-label", pmString("Add reaction"));
      add.setAttribute("aria-haspopup", "true");
      add.addEventListener("click", function () {
        if (transientPopup && transientPopup.anchor === add) { closeTransientPopup(); return; }
        openReactionPicker(add, bar, c);
      });
      bar.append(add);
    }
  }

  function openReactionPicker(anchor, bar, c) {
    var pick = document.createElement("div");
    pick.className = "pm-react-picker";
    REACTION_SET.forEach(function (pair) {
      var chip = reactionChipOf(c, pair[0]);
      var mine = !!(chip && chip.mine);
      var option = document.createElement("button");
      option.type = "button";
      option.className = "pm-react-option" + (mine ? " pm-reaction-mine" : "");
      option.textContent = pair[1];
      var label = (mine ? "Remove your " : "React with ") + pair[1];
      option.title = label;
      option.setAttribute("aria-label", label);
      option.addEventListener("click", function () { toggleReaction(c, pair[0]); });
      pick.append(option);
    });
    bar.append(pick);
    showTransientPopup(pick, anchor);
  }

  // One transient popup (reaction picker / ⋯ menu) at a time; click-away
  // and Esc close it, Esc never leaking into the page's own handling.
  var transientPopup = null;

  function closeTransientPopup() {
    if (!transientPopup) { return; }
    var p = transientPopup;
    transientPopup = null;
    document.removeEventListener("mousedown", p.onAway, true);
    document.removeEventListener("keydown", p.onKey, true);
    p.el.remove();
  }

  // The popups position themselves relative to their card (menu below the
  // ⋯ button, picker above the smiley); near a viewport edge that default
  // side would clip — flip to the anchor's other side instead. Runs after
  // the popup is in the DOM, so real geometry decides.
  function fitPopupVertically(el, anchor) {
    var margin = 8;
    var rect = el.getBoundingClientRect();
    var overBottom = rect.bottom > window.innerHeight - margin;
    var overTop = rect.top < margin;
    if (!overBottom && !overTop) { return; }
    var aRect = anchor && anchor.getBoundingClientRect
      ? anchor.getBoundingClientRect() : rect;
    var parent = el.offsetParent;
    var parentTop = parent ? parent.getBoundingClientRect().top : 0;
    var top = overBottom
      ? aRect.top - parentTop - el.offsetHeight - 4   // above the anchor
      : aRect.bottom - parentTop + 4;                 // below the anchor
    el.style.bottom = "auto";
    el.style.top = Math.round(top) + "px";
  }

  // Popups must never run off the window's sides either — the overview's
  // full-width cards put the smiley at the content's right edge, where
  // the picker's natural position clips (design-review catch). Clamp
  // into the viewport after the vertical fit decides the row.
  function fitPopupHorizontally(el) {
    var margin = 8;
    var parent = el.offsetParent;
    var parentLeft = parent ? parent.getBoundingClientRect().left : 0;
    var rect = el.getBoundingClientRect();
    var over = rect.right - (window.innerWidth - margin);
    if (over > 0) {
      el.style.right = "auto";
      el.style.left = Math.round(rect.left - parentLeft - over) + "px";
      rect = el.getBoundingClientRect();
    }
    if (rect.left < margin) {
      el.style.right = "auto";
      el.style.left = Math.round(margin - parentLeft) + "px";
    }
  }

  function showTransientPopup(el, anchor) {
    closeTransientPopup();
    fitPopupVertically(el, anchor);
    fitPopupHorizontally(el);
    var p = { el: el, anchor: anchor };
    p.onAway = function (event) {
      if (el.contains(event.target) || event.target === anchor
          || (anchor && anchor.contains && anchor.contains(event.target))) { return; }
      closeTransientPopup();
    };
    p.onKey = function (event) {
      if (event.key !== "Escape") { return; }
      event.preventDefault();
      event.stopPropagation();
      closeTransientPopup();
      if (anchor && anchor.focus) { anchor.focus(); }
    };
    document.addEventListener("mousedown", p.onAway, true);
    document.addEventListener("keydown", p.onKey, true);
    transientPopup = p;
  }

  // ---- Editing and deleting your own comments (spec) ----
  // Viewer-authored published comments carry a hover ⋯ menu. Edit swaps
  // the body for the mini-composer pre-filled with the current Markdown;
  // Delete round-trips through the bridge so the destructive confirm is
  // native (the page never confirms with its own chrome).

  function commentMenuButton(c, card, bodyEl) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pm-comment-menu-btn";
    btn.textContent = "⋯";
    btn.title = pmString("Comment actions");
    btn.setAttribute("aria-label", pmString("Comment actions"));
    btn.setAttribute("aria-haspopup", "menu");
    btn.addEventListener("click", function () {
      if (transientPopup && transientPopup.anchor === btn) { closeTransientPopup(); return; }
      var menu = document.createElement("div");
      menu.className = "pm-comment-menu";
      menu.setAttribute("role", "menu");
      var edit = document.createElement("button");
      edit.type = "button";
      edit.setAttribute("role", "menuitem");
      edit.textContent = pmString("edit-action");
      edit.addEventListener("click", function () {
        closeTransientPopup();
        openEditComposer(c, card, bodyEl);
      });
      var del = document.createElement("button");
      del.type = "button";
      del.setAttribute("role", "menuitem");
      del.className = "pm-menu-destructive";
      del.textContent = pmString("Delete");
      del.addEventListener("click", function () {
        closeTransientPopup();
        post({ type: "commentDelete", commentID: c.id, source: c.source });
      });
      menu.append(edit, del);
      card.append(menu);
      showTransientPopup(menu, btn);
    });
    return btn;
  }

  // The reply mini-composer pattern, seeded with the comment's current
  // body. Click-away keeps the typed text as a draft on the comment;
  // Cancel discards; Save posts commentEdit and the card catches up when
  // the reloaded comments arrive (failures restore the draft app-side).
  function openEditComposer(c, card, bodyEl) {
    var existing = card.querySelector(".pm-edit-composer");
    if (existing) { existing.querySelector("textarea").focus(); return; }
    var draftKey = "edit:" + c.id;
    var root = document.createElement("div");
    root.className = "pm-reply-composer pm-edit-composer";
    var ta = document.createElement("textarea");
    ta.className = "pm-composer-text";
    ta.rows = 3;
    var actions = document.createElement("div");
    actions.className = "pm-composer-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.textContent = pmString("Cancel");
    var save = document.createElement("button");
    save.type = "button";
    save.className = "pm-composer-primary";
    save.textContent = pmString("Save");
    save.title = pmString("Save your edit (⌘↩)");
    actions.append(cancel, save);
    root.append(ta, actions);

    var syncTimer = null;
    function grow() {
      ta.style.height = "auto";
      ta.style.height = Math.max(56, ta.scrollHeight) + "px";
    }
    function close(keep) {
      document.removeEventListener("mousedown", onAway, true);
      if (syncTimer) { clearTimeout(syncTimer); }
      if (keep) {
        // An unchanged text is no draft — saving it would resurrect a
        // stale body after the comment moves on.
        if (ta.value === c.body) { draftDiscard(draftKey); }
        else { draftSave(draftKey, ta.value); }
      }
      root.remove();
      bodyEl.style.display = "";
    }
    function submit() {
      var body = ta.value.trim();
      if (body === "") { return; }
      post({ type: "commentEdit", commentID: c.id, body: body, draftKey: draftKey,
             source: c.source });
      draftDiscard(draftKey);
      close(false);
    }
    function onAway(event) {
      if (root.contains(event.target)) { return; }
      close(true);
    }
    document.addEventListener("mousedown", onAway, true);
    // Destroyed-from-outside path (card re-render): same keep-rule as
    // away — an unchanged text is no draft.
    root.__pmFlushDraft = function () {
      if (ta.value === c.body) { draftDiscard(draftKey); }
      else { draftSave(draftKey, ta.value); }
    };

    cancel.addEventListener("click", function () {
      draftDiscard(draftKey);
      close(false);
    });
    save.addEventListener("click", submit);
    ta.addEventListener("input", function () {
      grow();
      save.disabled = ta.value.trim() === "";
      if (syncTimer) { clearTimeout(syncTimer); }
      syncTimer = setTimeout(function () {
        syncTimer = null;
        if (ta.value !== c.body) { draftSave(draftKey, ta.value); }
      }, 400);
    });
    ta.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        event.stopPropagation();
        if (ta.value.trim() === "") {
          event.preventDefault();
          draftDiscard(draftKey);
          close(false);
        }
        return;
      }
      if (event.isComposing) { return; }
      if (event.key === "Enter" && event.metaKey) {
        event.preventDefault();
        event.stopPropagation();
        submit();
      }
    });

    ta.value = composerDrafts[draftKey] || c.body;
    save.disabled = ta.value.trim() === "";
    bodyEl.style.display = "none";
    bodyEl.after(root);
    grow();
    root.scrollIntoView({ block: "nearest", inline: "nearest" });
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
  }

  // The viewer's pending review comments at their anchors: always the
  // yellow Pending tag, never Reply/Resolve (those act on published
  // comments). One source of truth — the same pending set the review
  // popover lists (spec §3).
  function pendingEl(items) {
    var wrap = document.createElement("div");
    wrap.className = "pm-threads pm-pending-threads";
    items.forEach(function (item) {
      var box = document.createElement("div");
      box.className = "pm-thread pm-pending";
      var header = document.createElement("div");
      header.className = "pm-thread-header";
      var label = document.createElement("div");
      label.className = "pm-thread-line";
      label.textContent = item.lineLabel || "";
      var tags = document.createElement("div");
      tags.className = "pm-pending-tags";
      var tag = document.createElement("span");
      tag.className = "pm-pending-tag";
      tag.textContent = pmString("Pending");
      tags.append(tag);
      if (item.uploaded === false) {
        var queued = document.createElement("span");
        queued.className = "pm-pending-tag pm-pending-queued";
        queued.textContent = pmString("Not synced");
        tags.append(queued);
      }
      header.append(label, tags);
      box.append(header);
      var comment = document.createElement("div");
      comment.className = "pm-thread-comment";
      var body = document.createElement("div");
      body.className = "pm-thread-body";
      body.innerHTML = render(item.body);
      comment.append(body);
      box.append(comment);
      wrap.append(box);
    });
    return wrap;
  }

  // ---- In-page inline comment composer (spec §5) ----
  // The composer expands beneath the target block, styled as a sibling of
  // the thread cards — the document stays visible and the composer scrolls
  // with content. Click-away preserves the typed text as a draft keyed to
  // the block (mirrored to disk through the bridge); explicit Cancel (or
  // Esc while empty) discards. Actions follow review state: "Start a
  // review" until a pending review exists, then "Add review comment",
  // with "Add single comment" always secondary.

  var composerDrafts = {};
  // Swift pushes persisted drafts for this file after each page load.
  window.__pmSetComposerDrafts = function (map) {
    Object.keys(map || {}).forEach(function (key) {
      composerDrafts[key] = map[key];
    });
    // The conversation composer is built at page setup — before this
    // push arrives — so its restored draft must reach the live
    // textarea (reply composers open later and read the map in time).
    // Never clobber text typed in the meantime.
    var draft = composerDrafts["conversation:new"];
    if (draft) {
      var ta = document.querySelector(".pm-conversation-composer .pm-composer-text");
      if (ta && ta.value.trim() === "") {
        ta.value = draft;
        ta.dispatchEvent(new Event("input"));
      }
    }
  };

  function draftSave(key, text) {
    if (text.trim() === "") { draftDiscard(key); return; }
    composerDrafts[key] = text;
    post({ type: "composerDraft", key: key, text: text });
  }

  function draftDiscard(key) {
    delete composerDrafts[key];
    post({ type: "composerDraft", key: key, text: "" });
  }

  // Mini-composers (reply/edit) register a flush hook on their root;
  // anything that destroys their DOM (card re-render, resolved-visibility
  // toggle) calls this first, so no typed text ever waits on the 400ms
  // draft debounce when the textarea disappears.
  function flushLiveComposerDrafts(scope) {
    if (!scope || !scope.querySelectorAll) { return; }
    scope.querySelectorAll(".pm-reply-composer").forEach(function (el) {
      if (el.__pmFlushDraft) { el.__pmFlushDraft(); }
    });
  }

  // Commentable file-line runs (per-hunk, computed in Swift from the
  // patch): a comment range must sit inside one run — GitHub rejects
  // ranges that span hunks. An absent payload means membership is unknown;
  // validation then stays out of the way (failures surface at post time).
  function commentableRuns(side) {
    var lines = payload.commentableLines;
    if (!lines) { return null; }
    return (side === "LEFT" ? lines.left : lines.right) || [];
  }

  function rangeCommentable(side, start, end) {
    var runs = commentableRuns(side);
    if (!runs) { return true; }
    return runs.some(function (run) {
      return run[0] <= start && end <= run[1];
    });
  }

  // Largest single-run intersection (ties keep the earlier run), or null
  // when the range touches no run — mirrors CommentableLines.clamp.
  function clampRangeToRuns(side, start, end) {
    var runs = commentableRuns(side);
    if (!runs) { return [start, end]; }
    var best = null;
    runs.forEach(function (run) {
      var lo = Math.max(start, run[0]);
      var hi = Math.min(end, run[1]);
      if (lo > hi) { return; }
      if (!best || hi - lo > best[1] - best[0]) { best = [lo, hi]; }
    });
    return best;
  }

  // The current selection's text clamped to one element — a selection
  // spanning blocks narrows to the invoked block (spec §5).
  function selectionTextWithin(el) {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { return ""; }
    var range = sel.getRangeAt(0).cloneRange();
    var intersects;
    try { intersects = range.intersectsNode(el); } catch (e) { intersects = false; }
    if (!intersects) { return ""; }
    var bounds = document.createRange();
    bounds.selectNodeContents(el);
    try {
      if (bounds.comparePoint(range.startContainer, range.startOffset) < 0) {
        range.setStart(bounds.startContainer, bounds.startOffset);
      }
      if (bounds.comparePoint(range.endContainer, range.endOffset) > 0) {
        range.setEnd(bounds.endContainer, bounds.endOffset);
      }
    } catch (e) { return ""; }
    return range.toString();
  }

  // Maps selected rendered text back to 0-based indexes into the block's
  // source lines. Rendered text is a per-line substring of the source for
  // the constructs that matter (emphasis, links, code spans): match the
  // selection's first fragment forward — dropping trailing words, since a
  // rendered paragraph joins source lines — and its last fragment from
  // there, dropping leading words. Unmatchable selections return null →
  // the whole block; a wrong narrow would misanchor the comment, so null
  // is the safe answer. Exposed for the render harness.
  window.__pmNarrowToSelection = function (sourceLines, selectedText) {
    var fragments = (selectedText || "").split("\n")
      .map(function (s) { return s.trim(); })
      .filter(function (s) { return s.length > 0; });
    if (!fragments.length) { return null; }
    function find(fragment, from, dropLeading) {
      var words = fragment.split(/\s+/);
      while (words.length) {
        var probe = words.join(" ");
        for (var i = from; i < sourceLines.length; i++) {
          if (sourceLines[i].indexOf(probe) !== -1) { return i; }
        }
        if (dropLeading) { words.shift(); } else { words.pop(); }
      }
      return -1;
    }
    var start = find(fragments[0], 0, false);
    if (start === -1) { return null; }
    var end = find(fragments[fragments.length - 1], start, true);
    return [start, end === -1 ? start : end];
  };

  function narrowRangeTo(blockEl, sourceLines, lineBase) {
    var text = selectionTextWithin(blockEl);
    if (!text) { return null; }
    var mapped = window.__pmNarrowToSelection(sourceLines, text);
    if (!mapped) { return null; }
    return [lineBase + mapped[0], lineBase + mapped[1]];
  }

  // The fence grows past any backtick run inside the seed, so suggesting
  // an edit to a code fence can't break out of the ```suggestion block.
  function suggestionFence(seed) {
    var longest = 0;
    var run = 0;
    for (var ch of seed) {
      if (ch === "`") { run += 1; longest = Math.max(longest, run); }
      else { run = 0; }
    }
    return "`".repeat(Math.max(3, longest + 1));
  }

  function suggestionBlock(seed) {
    var fence = suggestionFence(seed);
    // An empty seed emits GitHub's delete-lines form: nothing at all
    // between the fences.
    return seed === ""
      ? fence + "suggestion\n" + fence
      : fence + "suggestion\n" + seed + "\n" + fence;
  }

  function rangeCaption(side, start, end) {
    var which = side === "LEFT" ? "old" : "new";
    return (start === end ? "Line " + start : "Lines " + start + "–" + end)
      + ", " + which;
  }

  var openComposer = null;

  function closeComposer(save) {
    if (!openComposer) { return; }
    var st = openComposer;
    openComposer = null;
    document.removeEventListener("mousedown", st.onAway, true);
    if (st.syncTimer) { clearTimeout(st.syncTimer); }
    if (save) { draftSave(st.draftKey, st.ta.value); }
    st.container.remove();
    if (st.onClose) { st.onClose(); }
  }

  // opts: { anchor (node the composer inserts after), side, range [s, e],
  //   lineBase, sourceLines (side's source, indexed from lineBase; null →
  //   no suggestion), seedFor (optional override returning the current
  //   lines for the range), draftKey, prefillSuggestion, splitGrid,
  //   onClose }
  function composerOpen(opts) {
    if (openComposer && openComposer.draftKey === opts.draftKey) {
      // The affordance that opened it toggles its own composer closed.
      closeComposer(true);
      return;
    }
    closeComposer(true);

    var root = document.createElement("div");
    root.className = "pm-composer pm-annotation";

    var bar = document.createElement("div");
    bar.className = "pm-composer-toolbar";
    var suggest = document.createElement("button");
    suggest.type = "button";
    suggest.className = "pm-composer-suggest";
    suggest.textContent = pmString("Add a suggestion");
    var caption = document.createElement("span");
    caption.className = "pm-composer-caption";
    bar.append(suggest, caption);

    var ta = document.createElement("textarea");
    ta.className = "pm-composer-text";
    ta.placeholder = pmString("Leave a comment");
    ta.rows = 3;

    var note = document.createElement("div");
    note.className = "pm-composer-note";
    note.textContent = pmString("These lines are outside the pull request's diff, so GitHub can't attach a comment to them.");

    var actions = document.createElement("div");
    actions.className = "pm-composer-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.textContent = pmString("Cancel");
    var secondary = document.createElement("button");
    secondary.type = "button";
    secondary.textContent = pmString("Add single comment");
    secondary.title = pmString("Post immediately, outside any pending review (⇧⌘↩)");
    var primary = document.createElement("button");
    primary.type = "button";
    primary.className = "pm-composer-primary";
    primary.textContent = payload.reviewPending
      ? pmString("Add review comment") : pmString("Start a review");
    primary.title = payload.reviewPending
      ? pmString("Add to your pending review — it posts when you submit the review (⌘↩)")
      : pmString("Start a pending review with this comment (⌘↩)");
    actions.append(cancel, secondary, primary);

    root.append(bar, ta, note, actions);

    var container = root;
    if (opts.splitGrid) {
      container = document.createElement("div");
      container.className = "pm-split-full pm-annotation";
      container.append(root);
    }

    var st = {
      root: root, container: container, ta: ta, range: opts.range.slice(),
      draftKey: opts.draftKey, syncTimer: null, onClose: opts.onClose || null
    };

    function seedText() {
      if (opts.seedFor) { return opts.seedFor(st.range); }
      if (!opts.sourceLines) { return null; }
      var lo = st.range[0] - opts.lineBase;
      var hi = st.range[1] - opts.lineBase;
      if (lo < 0 || hi >= opts.sourceLines.length || lo > hi) { return null; }
      return opts.sourceLines.slice(lo, hi + 1).join("\n");
    }

    function updateState() {
      var valid = rangeCommentable(opts.side, st.range[0], st.range[1]);
      var empty = ta.value.trim() === "";
      caption.textContent = rangeCaption(opts.side, st.range[0], st.range[1]);
      note.style.display = valid ? "none" : "";
      primary.disabled = !valid || empty;
      secondary.disabled = !valid || empty;
      if (opts.side !== "RIGHT") {
        suggest.disabled = true;
        suggest.title = pmString("Suggestions can only target new-file lines — GitHub applies them in place of the commented lines.");
      } else if (seedText() === null || !valid) {
        suggest.disabled = true;
        suggest.title = pmString("The targeted lines aren't available to suggest an edit to.");
      } else {
        suggest.disabled = false;
        suggest.title = pmString("Insert a ```suggestion block pre-filled with the current lines");
      }
    }

    st.setRange = function (range) {
      st.range = range.slice();
      updateState();
    };
    st.moveAfter = function (anchor) {
      anchor.after(container);
    };

    function grow() {
      ta.style.height = "auto";
      ta.style.height = Math.max(72, ta.scrollHeight) + "px";
    }

    function scheduleDraftSync() {
      if (st.syncTimer) { clearTimeout(st.syncTimer); }
      // Synced while typing (debounced) so a page re-render underneath the
      // composer — a pending comment arriving, the refresh loop — can
      // never lose more than a beat of text.
      st.syncTimer = setTimeout(function () {
        st.syncTimer = null;
        draftSave(st.draftKey, ta.value);
      }, 400);
    }

    function submit(review) {
      var body = ta.value.trim();
      if (body === "" || primary.disabled) { return; }
      post({ type: "composerSubmit", review: !!review,
             lineStart: st.range[0], lineEnd: st.range[1], side: opts.side,
             body: body, draftKey: st.draftKey });
      draftDiscard(st.draftKey);
      closeComposer(false);
    }

    suggest.addEventListener("click", function () {
      var seed = seedText();
      if (seed === null) { return; }
      if (ta.value !== "" && !/\n$/.test(ta.value)) { ta.value += "\n"; }
      // Caret at the end of the seeded lines, INSIDE the fence, ready to
      // edit — same landing as the pencil's prefill.
      var caret = ta.value.length + suggestionFence(seed).length
        + "suggestion\n".length + seed.length;
      ta.value += suggestionBlock(seed) + "\n";
      grow();
      updateState();
      scheduleDraftSync();
      ta.focus();
      ta.setSelectionRange(caret, caret);
    });
    cancel.addEventListener("click", function () {
      draftDiscard(st.draftKey);
      closeComposer(false);
    });
    secondary.addEventListener("click", function () { submit(false); });
    primary.addEventListener("click", function () { submit(true); });

    ta.addEventListener("input", function () {
      grow();
      updateState();
      scheduleDraftSync();
    });
    ta.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        // Never bubbles into the page's own Escape handling (marker
        // collapse) while the composer has focus.
        event.stopPropagation();
        if (ta.value.trim() === "") {
          event.preventDefault();
          draftDiscard(st.draftKey);
          closeComposer(false);
        }
        // Non-empty: the text is kept and the composer stays — only
        // Cancel discards; click-away saves (spec §5).
        return;
      }
      if (event.isComposing) { return; }
      if (event.key === "Enter" && event.metaKey && !event.altKey && !event.ctrlKey) {
        event.preventDefault();
        event.stopPropagation();
        submit(!event.shiftKey);
      }
    });

    // Click-away saves (HIG nonmodal rule). Capture phase so it runs
    // before whatever the click does; the comment affordances manage the
    // composer themselves (toggle/move), so they are exempt.
    st.onAway = function (event) {
      if (root.contains(event.target)) { return; }
      if (event.target.closest
          && event.target.closest(".pm-comment-btn, .pm-patch-lineno")) { return; }
      closeComposer(true);
    };
    document.addEventListener("mousedown", st.onAway, true);

    var draft = composerDrafts[opts.draftKey];
    if (draft) {
      ta.value = draft;
    } else if (opts.prefillSuggestion) {
      var seed = seedText();
      if (seed !== null) {
        ta.value = suggestionBlock(seed) + "\n";
      }
    }

    opts.anchor.after(container);
    openComposer = st;
    updateState();
    grow();
    // The rail bubble can open a composer that lands below the fold —
    // WebKit's focus scroll reveals only enough textarea to type, not
    // the actions. Bring the whole card in (nearest: no motion when it
    // is already visible).
    container.scrollIntoView({ block: "nearest", inline: "nearest" });
    ta.focus();
    if (!draft && opts.prefillSuggestion && ta.value !== "") {
      // Caret at the end of the seeded lines, inside the fence, ready to
      // edit — the pencil's whole point.
      var head = suggestionFence(seedText() || "") + "suggestion\n";
      var caret = head.length + (seedText() || "").length;
      ta.setSelectionRange(caret, caret);
    } else {
      ta.setSelectionRange(ta.value.length, ta.value.length);
    }
  }

  // Opens the composer for a rendered-diff segment: default anchor is the
  // whole block — or one sub-unit's lines when `unitRange` is given (a
  // list item's or table row's bubble). A text selection inside the
  // block narrows (or, from a unit, widens) the range (spec §5 —
  // narrowing is a gesture, not a widget).
  function composerForSegment(seg, target, suggest, unitRange) {
    var sourceLines = (seg.text || "").split("\n");
    var range = unitRange ? unitRange.slice() : [seg.lineStart, seg.lineEnd];
    var keyRange = range.slice();
    var narrowed = narrowRangeTo(target.block, sourceLines, seg.lineStart);
    if (narrowed) {
      range = narrowed;
    } else if (!rangeCommentable(seg.side, range[0], range[1])) {
      // The whole-block default pokes outside its hunk (context blocks):
      // clamp into the diff rather than opening pre-invalidated. A range
      // the user narrowed deliberately is never clamped — validation
      // explains instead.
      var clamped = clampRangeToRuns(seg.side, range[0], range[1]);
      if (clamped) { range = clamped; }
    }
    composerOpen({
      anchor: target.anchor,
      side: seg.side,
      range: range,
      lineBase: seg.lineStart,
      sourceLines: seg.side === "RIGHT" ? sourceLines : null,
      draftKey: seg.side + ":" + keyRange[0] + "-" + keyRange[1],
      prefillSuggestion: suggest,
      splitGrid: target.split
    });
  }

  // Replies move in-page too (spec §5): the Reply button expands a mini-
  // composer inside the thread card — text area, Cancel, one Reply action.
  // Click-away keeps the typed text as a draft on the thread.
  function toggleReplyComposer(box, rootID, opener) {
    var existing = box.querySelector(".pm-reply-composer");
    if (existing) { existing.__pmClose(true); return; }
    var draftKey = "reply:" + rootID;
    var root = document.createElement("div");
    root.className = "pm-reply-composer";
    var ta = document.createElement("textarea");
    ta.className = "pm-composer-text";
    ta.placeholder = pmString("Write a reply");
    ta.rows = 2;
    var actions = document.createElement("div");
    actions.className = "pm-composer-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.textContent = pmString("Cancel");
    var send = document.createElement("button");
    send.type = "button";
    send.className = "pm-composer-primary";
    send.textContent = pmString("Reply");
    send.title = pmString("Reply to this thread (⌘↩)");
    actions.append(cancel, send);
    root.append(ta, actions);

    var syncTimer = null;
    function grow() {
      ta.style.height = "auto";
      ta.style.height = Math.max(56, ta.scrollHeight) + "px";
    }
    function close(save) {
      document.removeEventListener("mousedown", onAway, true);
      if (syncTimer) { clearTimeout(syncTimer); }
      if (save) { draftSave(draftKey, ta.value); }
      root.remove();
    }
    root.__pmClose = close;
    function submit() {
      var body = ta.value.trim();
      if (body === "") { return; }
      post({ type: "threadReplySubmit", rootID: rootID, body: body, draftKey: draftKey });
      draftDiscard(draftKey);
      close(false);
    }
    function onAway(event) {
      if (root.contains(event.target) || event.target === opener) { return; }
      close(true);
    }
    document.addEventListener("mousedown", onAway, true);
    // Destroyed-from-outside path (card re-render): same save as away.
    root.__pmFlushDraft = function () { draftSave(draftKey, ta.value); };

    cancel.addEventListener("click", function () {
      draftDiscard(draftKey);
      close(false);
    });
    send.addEventListener("click", submit);
    ta.addEventListener("input", function () {
      grow();
      send.disabled = ta.value.trim() === "";
      if (syncTimer) { clearTimeout(syncTimer); }
      syncTimer = setTimeout(function () {
        syncTimer = null;
        draftSave(draftKey, ta.value);
      }, 400);
    });
    ta.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        event.stopPropagation();
        if (ta.value.trim() === "") {
          event.preventDefault();
          draftDiscard(draftKey);
          close(false);
        }
        return;
      }
      if (event.isComposing) { return; }
      if (event.key === "Enter" && event.metaKey) {
        event.preventDefault();
        event.stopPropagation();
        submit();
      }
    });

    var draft = composerDrafts[draftKey];
    if (draft) { ta.value = draft; }
    send.disabled = ta.value.trim() === "";
    box.append(root);
    grow();
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
  }

  // The rail bubbles' left offset (layer coordinates): 6px inside the
  // content's right edge, but never closer than 18px to the viewport's
  // right edge — a narrow web view puts the content edge AT the viewport
  // edge, where the macOS overlay scrollbar draws.
  function railLeft(cRect, tw) {
    return Math.min(cRect.width - tw - 6,
                    window.innerWidth - cRect.left - tw - 18);
  }

  // A target taller than the viewport must not strand its bubble above
  // the scroll: pin the bubble's natural y into the target's visible
  // slice (10px under the viewport top, held inside the target's
  // bottom). The scroll re-probe re-runs every positioner, so this
  // clamp alone keeps bubbles sticky while a long block scrolls by.
  function stickyRailY(naturalTop, targetBottom) {
    return Math.min(Math.max(naturalTop, 10), targetBottom - 34);
  }

  // ---- Result-view comment affordances (spec §5) ----
  // Commenting is offered on blocks that map into the PR diff; on blocks
  // that don't, the affordance explains why not instead of vanishing.
  // Default anchor is the block's diff-mapped range; a text selection
  // narrows it, exactly like the diff views.
  function setupResultCommenting() {
    var docLines = (payload.markdown || "").split("\n");
    // Affordances live in a content-level layer, like the markers — NOT
    // inside the blocks. A block like a table clips and scrolls
    // (github-markdown gives tables overflow:auto), so anything hanging
    // past its edge from inside would grow the block its own scrollbar.
    document.documentElement.classList.add("pm-commenting-on");
    var layer = document.createElement("div");
    layer.className = "pm-affordance-layer pm-annotation";
    content.append(layer);
    for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
      var m = /^(\d+)-(\d+)$/.exec(
        (el.getAttribute && el.getAttribute("data-pm-lines")) || "");
      if (!m) { continue; }
      var block = { el: el, start: +m[1], end: +m[2] };
      var subs = el.querySelectorAll("[data-pm-sublines]");
      if (subs.length) {
        // Container blocks delegate to their units (spec:
        // nested-comment-targets): the comment range is the item's or
        // row's own lines, so in a partially changed list the changed
        // items comment and the untouched ones explain themselves.
        subs.forEach(function (unit) {
          var r = subUnitRange(unit);
          if (r) { attachResultAffordance(layer, unit, r[0], r[1], docLines, block); }
        });
      } else {
        attachResultAffordance(layer, el, block.start, block.end, docLines, block);
      }
    }
  }

  function attachResultAffordance(layer, el, blockStart, blockEnd, docLines, block) {
    el.classList.add("pm-commentable");
    var mapped = clampRangeToRuns("RIGHT", blockStart, blockEnd);
    // Both affordances share one hover container beside the block, in the
    // content column's right padding gutter where the markers live —
    // never overlaying wide content. Shown via JS hover with a short
    // grace so the pointer can cross from the block onto the buttons;
    // positioned at show time, so re-layouts can't leave it stale.
    var tools = document.createElement("div");
    tools.className = "pm-result-tools";
    tools.setAttribute("data-pm-for", blockStart + "-" + blockEnd);
    var hideTimer = null;
    function hideNow() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      tools.style.display = "none";
      el.classList.remove("pm-hover-target");
    }
    function position() {
      var cRect = content.getBoundingClientRect();
      var rect = el.getBoundingClientRect();
      // Below any marker badges stacked at the block top (one row each).
      var badges = (el.classList.contains("pm-commented") ? 1 : 0)
        + (el.classList.contains("pm-pending-anchor") ? 1 : 0);
      var tw = tools.getBoundingClientRect().width || 28;
      // The margin rail: the page reserves comment-room padding, so the
      // bubble aligns across blocks and never overlaps content — clamped
      // clear of the viewport edge, where a narrow web view (sidebar +
      // outline open) would otherwise put it under the overlay scrollbar.
      tools.style.left = Math.round(railLeft(cRect, tw)) + "px";
      tools.style.top = Math.round(
        stickyRailY(rect.top + 2 + badges * 28, rect.bottom) - cRect.top) + "px";
    }
    function show() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      if (activeBlockBubble && activeBlockBubble !== hideNow) { activeBlockBubble(); }
      activeBlockBubble = hideNow;
      // Keep the probe's claim on the block that actually showed last: a
      // fast flick can real-enter a block between probe ticks, and a
      // stale claim would steal its bubble back on the next dead row.
      virtualHover = el;
      el.classList.add("pm-hover-target");
      tools.style.display = "flex";
      position();
    }
    function hide() {
      if (hideTimer) { clearTimeout(hideTimer); }
      hideTimer = setTimeout(function () {
        tools.style.display = "none";
        el.classList.remove("pm-hover-target");
      }, 120);
    }
    el.addEventListener("mouseenter", show);
    el.addEventListener("mouseleave", hide);
    tools.addEventListener("mouseenter", show);
    tools.addEventListener("mouseleave", hide);
    var bubble = document.createElement("button");
    bubble.type = "button";
    bubble.className = "pm-comment-btn";
    bubble.innerHTML = COMMENT_ICON;
    if (!mapped) {
      bubble.classList.add("pm-comment-unavailable");
      bubble.title = pmString("This block isn't part of the pull request's diff — GitHub can only attach comments to changed lines.");
      bubble.setAttribute("aria-disabled", "true");
      bubble.setAttribute("aria-label", bubble.title);
      tools.append(bubble);
      layer.append(tools);
      return;
    }
    // Selection narrowing (and widening, for a sub-unit) works against
    // the whole block: selecting across several list items and clicking
    // any of their bubbles comments on the covered lines.
    var sourceLines = docLines.slice(block.start - 1, block.end);
    function open(suggest) {
      var range = mapped;
      var narrowed = narrowRangeTo(block.el, sourceLines, block.start);
      if (narrowed) { range = narrowed; }
      // A sibling of the marker card when one is open, matching the
      // diff views' card order. Sub-unit composers open at content
      // level too — under the enclosing block.
      var anchor = block.el;
      if (anchor.nextElementSibling
          && anchor.nextElementSibling.classList.contains("pm-result-card")) {
        anchor = anchor.nextElementSibling;
      }
      composerOpen({
        anchor: anchor,
        side: "RIGHT",
        range: range,
        lineBase: block.start,
        sourceLines: sourceLines,
        draftKey: "RIGHT:" + blockStart + "-" + blockEnd,
        prefillSuggestion: suggest
      });
    }
    bubble.title = pmFormat("Comment on lines {a}–{b}", {a: mapped[0], b: mapped[1]});
    bubble.setAttribute("aria-label", bubble.title);
    bubble.addEventListener("click", function (event) {
      event.stopPropagation();
      open(false);
    });
    // One affordance: the bubble. Suggestion editing lives inside the
    // composer (pm-composer-suggest) — a second hover button doubled it
    // and the stacked pair collided with short neighbors.
    tools.append(bubble);
    layer.append(tools);
  }

  // ---- Margin notes (beta) ----
  // `<!-- note @author: … -->` comments render as bubbles pinned to the
  // comment's own spot in the document. Swift parses the file
  // (Core/MarginNotes) and passes the notes in document order; the page
  // pairs them with the DOM comment nodes matching the same marker —
  // same grammar, same order — so no positional math is ever needed.
  // Authoring (local documents) posts noteAdd/noteEdit/noteDelete over
  // the bridge; Swift rewrites the file and the reload re-renders.

  var NOTE_MARKER = /^\s*note\s+@/;
  var openNoteEditor = null;

  // First-use intro (spec: margin-notes-graduation). Armed by Swift
  // after page load — never carried in the page payload, so the
  // seen-flip can't force a re-render. While armed, every write
  // affordance stashes its action and asks Swift instead of acting;
  // __pmNoteIntroResolved(true) runs the stash (Keep Using resumes the
  // exact click), false drops it and stays armed (Esc, "not now").
  var noteIntroPending = false;
  var noteIntroStash = null;

  window.__pmSetNoteIntroPending = function (pending) {
    noteIntroPending = !!pending;
    if (!noteIntroPending) { noteIntroStash = null; }
  };

  window.__pmNoteIntroResolved = function (proceed) {
    var stash = noteIntroStash;
    noteIntroStash = null;
    if (proceed) {
      noteIntroPending = false;
      if (stash) { stash(); }
    }
  };

  function noteIntroGate(action) {
    if (!noteIntroPending) { action(); return; }
    noteIntroStash = action;
    post({ type: "noteIntroRequested" });
  }

  function noteCommentNodes() {
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_COMMENT);
    var nodes = [];
    var node;
    while ((node = walker.nextNode())) {
      if (NOTE_MARKER.test(node.nodeValue || "")) { nodes.push(node); }
    }
    return nodes;
  }

  function closeNoteEditor(save) {
    if (!openNoteEditor) { return; }
    var st = openNoteEditor;
    openNoteEditor = null;
    document.removeEventListener("mousedown", st.onAway, true);
    st.container.remove();
    if (st.onClose) { st.onClose(save); }
    post({ type: "editingState", active: false });
  }

  // Minimal composer shared by add and edit: a textarea with Cancel and
  // one primary action. Opening posts editingState so Swift defers
  // file-watcher reloads under the draft, exactly like the block editor.
  // opts: { anchor (insert after; null → prepend to content), seed,
  //   placeholder, primaryLabel, onSubmit(body), onClose }
  function noteComposerOpen(opts) {
    closeNoteEditor(false);
    closeComposer(true);

    var root = document.createElement("div");
    root.className = "pm-composer pm-note-composer pm-annotation";
    var ta = document.createElement("textarea");
    ta.className = "pm-composer-text";
    ta.placeholder = opts.placeholder || pmString("Leave a margin note");
    ta.rows = 3;
    var actions = document.createElement("div");
    actions.className = "pm-composer-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.textContent = pmString("Cancel");
    var primary = document.createElement("button");
    primary.type = "button";
    primary.className = "pm-composer-primary";
    primary.textContent = opts.primaryLabel || pmString("Add Note");
    primary.title = "⌘↩";
    actions.append(cancel, primary);
    root.append(ta, actions);

    var st = { container: root, ta: ta, onClose: opts.onClose || null };

    function grow() {
      ta.style.height = "auto";
      ta.style.height = Math.max(72, ta.scrollHeight) + "px";
    }
    function updateState() {
      primary.disabled = ta.value.trim() === "";
    }
    function submit() {
      var body = ta.value.trim();
      if (body === "") { return; }
      // The note post goes FIRST: closing releases any deferred reload
      // (editingState false), and a stale disk read must never beat the
      // write into the page — same ordering rule as commitReveal.
      opts.onSubmit(body);
      closeNoteEditor(true);
    }

    cancel.addEventListener("click", function () { closeNoteEditor(false); });
    primary.addEventListener("click", submit);
    ta.addEventListener("input", function () { grow(); updateState(); });
    ta.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        event.stopPropagation();
        event.preventDefault();
        closeNoteEditor(false);
        return;
      }
      if (event.isComposing) { return; }
      if (event.key === "Enter" && event.metaKey && !event.altKey && !event.ctrlKey) {
        event.preventDefault();
        event.stopPropagation();
        submit();
      }
    });
    st.onAway = function (event) {
      if (root.contains(event.target)) { return; }
      if (event.target.closest && event.target.closest(".pm-comment-btn")) { return; }
      closeNoteEditor(false);
    };
    document.addEventListener("mousedown", st.onAway, true);

    ta.value = opts.seed || "";
    if (opts.parent) {
      // In-item note entry: the composer opens inside the list item,
      // where the note itself will render.
      opts.parent.append(root);
    } else if (opts.anchor) {
      opts.anchor.after(root);
    } else {
      content.prepend(root);
    }
    openNoteEditor = st;
    post({ type: "editingState", active: true });
    updateState();
    grow();
    root.scrollIntoView({ block: "nearest", inline: "nearest" });
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
  }

  function noteCardEl(note, authoring) {
    var card = document.createElement("div");
    card.className = "pm-note pm-annotation" + (note.fileLevel ? " pm-note-file" : "");
    var head = document.createElement("div");
    head.className = "pm-note-head";
    var author = document.createElement("span");
    author.className = "pm-note-author";
    author.textContent = "@" + note.author;
    head.append(author);
    if (note.fileLevel) {
      var scope = document.createElement("span");
      scope.className = "pm-note-scope";
      scope.textContent = pmString("whole document");
      head.append(scope);
    }
    var body = document.createElement("div");
    body.className = "pm-note-body";
    body.innerHTML = render(note.body);
    rewriteLocalResources(body);
    rewriteRemoteResources(body);
    rewriteAttachmentImages(body);
    enhance(body);
    card.append(head, body);
    if (authoring) {
      var actions = document.createElement("div");
      actions.className = "pm-note-actions";
      var edit = document.createElement("button");
      edit.type = "button";
      edit.textContent = pmString("edit-action");
      edit.addEventListener("click", function () {
        noteIntroGate(function () {
          card.style.display = "none";
          noteComposerOpen({
            anchor: card,
            seed: note.body,
            primaryLabel: pmString("Save"),
            onSubmit: function (text) {
              post({ type: "noteEdit", index: note.index, body: text });
            },
            onClose: function () { card.style.display = ""; }
          });
        });
      });
      var del = document.createElement("button");
      del.type = "button";
      del.textContent = pmString("Delete");
      del.addEventListener("click", function () {
        noteIntroGate(function () {
          post({ type: "noteDelete", index: note.index });
        });
      });
      actions.append(edit, del);
      head.append(actions);
    }
    return card;
  }

  // Replaces each note comment's position with its bubble. The comment
  // node itself stays in the DOM (invisible, harmless) so indices remain
  // stable however many bubbles render.
  function setupMarginNotes(notes, authoring) {
    var nodes = noteCommentNodes();
    notes.forEach(function (note, i) {
      if (i >= nodes.length) { return; }
      var node = nodes[i];
      var card = noteCardEl(note, authoring);
      // Anchor at the nearest content-level position: the comment sits
      // between blocks normally, but an unspaced one can end up inside a
      // rendered element — the bubble then follows that element.
      // A note living inside a list item renders its card right there,
      // at the comment's own spot in the item (a div is valid flow
      // content inside an li). Anything else keeps the content-level
      // hoist.
      var itemHost = null;
      for (var p = node.parentNode; p && p !== content; p = p.parentNode) {
        if (p.tagName === "LI") { itemHost = p; break; }
      }
      if (itemHost) {
        var inItem = node;
        while (inItem.parentNode !== itemHost) { inItem = inItem.parentNode; }
        itemHost.insertBefore(card, inItem.nextSibling);
        return;
      }
      var host = node;
      while (host.parentNode && host.parentNode !== content) {
        host = host.parentNode;
      }
      if (host === node) {
        content.insertBefore(card, node.nextSibling);
      } else {
        host.after(card);
      }
    });
  }

  // In-item placement plan for a sub-unit: the innermost ancestor item
  // (the unit itself included) whose content indent the note grammar
  // tolerates — at most 3 leading spaces, since 4 reads as an indented
  // code block. Null when no item qualifies (table rows, items nested
  // too deep, wide ordered markers like "10."): those fall back to an
  // after-block note that quotes the unit.
  function itemNotePlan(unitEl, blockEl) {
    var lines = (payload.markdown || "").split("\n");
    for (var a = unitEl; a && a !== blockEl; a = a.parentElement) {
      if (a.tagName !== "LI") { continue; }
      var r = subUnitRange(a);
      if (!r) { continue; }
      var m = /^(\s*)(?:[-*+]|\d{1,9}[.)])\s+/.exec(lines[r[0] - 1] || "");
      if (!m || m[0].length > 3) { continue; }
      return { anchorEl: a, afterLine: r[1],
               itemIndent: Array(m[0].length + 1).join(" ") };
    }
    return null;
  }

  // Sub-unit note entry (spec: nested-comment-targets). A list item
  // that can hold an indented note gets the composer inside the item
  // and the note written there; anything else gets an after-block note
  // seeded with a quote of the unit's first source line — the same
  // convention selection-quoting uses to point at a sentence.
  function openUnitNoteComposer(unitEl, blockEl, blockEnd) {
    var plan = itemNotePlan(unitEl, blockEl);
    var selected = selectionTextWithin(unitEl);
    var seed = "";
    if (selected) {
      seed = selected.split("\n").map(function (line) {
        return "> " + line;
      }).join("\n") + "\n\n";
    }
    if (plan) {
      noteComposerOpen({
        parent: plan.anchorEl,
        seed: seed,
        onSubmit: function (body) {
          post({ type: "noteAdd", afterLine: plan.afterLine, body: body,
                 itemIndent: plan.itemIndent });
        }
      });
      return;
    }
    if (!seed) {
      var r = subUnitRange(unitEl);
      var first = r
        ? ((payload.markdown || "").split("\n")[r[0] - 1] || "").trim()
        : "";
      if (first) { seed = "> " + first + "\n\n"; }
    }
    var anchor = blockEl;
    while (anchor.nextElementSibling
           && anchor.nextElementSibling.classList.contains("pm-note")) {
      anchor = anchor.nextElementSibling;
    }
    noteComposerOpen({
      anchor: anchor,
      seed: seed,
      onSubmit: function (body) {
        post({ type: "noteAdd", afterLine: blockEnd, body: body });
      }
    });
  }

  // Hover affordance on blocks of a local document: the margin-rail
  // bubble opens the note composer under the block. A text selection
  // inside the block is quoted into the seed — how a note points at a
  // sentence instead of a paragraph. Container blocks pass their units
  // here instead (el !== blockEl): the bubble then belongs to the item
  // or row under the pointer.
  function attachNoteAffordance(layer, el, blockEl, blockEnd) {
    el.classList.add("pm-commentable");
    var tools = document.createElement("div");
    tools.className = "pm-result-tools";
    var hideTimer = null;
    function hideNow() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      tools.style.display = "none";
      el.classList.remove("pm-hover-target");
    }
    function position() {
      var cRect = content.getBoundingClientRect();
      var rect = el.getBoundingClientRect();
      var tw = tools.getBoundingClientRect().width || 28;
      tools.style.left = Math.round(railLeft(cRect, tw)) + "px";
      tools.style.top = Math.round(
        stickyRailY(rect.top + 2, rect.bottom) - cRect.top) + "px";
    }
    function show() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      if (activeBlockBubble && activeBlockBubble !== hideNow) { activeBlockBubble(); }
      activeBlockBubble = hideNow;
      // Keep the probe's claim on the block that actually showed last: a
      // fast flick can real-enter a block between probe ticks, and a
      // stale claim would steal its bubble back on the next dead row.
      virtualHover = el;
      el.classList.add("pm-hover-target");
      tools.style.display = "flex";
      position();
    }
    function hide() {
      if (hideTimer) { clearTimeout(hideTimer); }
      hideTimer = setTimeout(function () {
        tools.style.display = "none";
        el.classList.remove("pm-hover-target");
      }, 120);
    }
    el.addEventListener("mouseenter", show);
    el.addEventListener("mouseleave", hide);
    tools.addEventListener("mouseenter", show);
    tools.addEventListener("mouseleave", hide);
    var bubble = document.createElement("button");
    bubble.type = "button";
    bubble.className = "pm-comment-btn";
    bubble.innerHTML = COMMENT_ICON;
    bubble.title = pmString("Add a margin note");
    bubble.setAttribute("aria-label", bubble.title);
    bubble.addEventListener("click", function (event) {
      event.stopPropagation();
      noteIntroGate(function () {
        if (el === blockEl) { openNoteComposerAt(el, blockEnd); }
        else { openUnitNoteComposer(el, blockEl, blockEnd); }
      });
    });
    tools.append(bubble);
    layer.append(tools);
  }

  // The composer lands after the block's trailing note bubbles, matching
  // where the note itself will render.
  function openNoteComposerAt(el, afterLine) {
    var selected = selectionTextWithin(el);
    var seed = "";
    if (selected) {
      seed = selected.split("\n").map(function (line) {
        return "> " + line;
      }).join("\n") + "\n\n";
    }
    var anchor = el;
    while (anchor.nextElementSibling
           && anchor.nextElementSibling.classList.contains("pm-note")) {
      anchor = anchor.nextElementSibling;
    }
    noteComposerOpen({
      anchor: anchor,
      seed: seed,
      onSubmit: function (body) {
        post({ type: "noteAdd", afterLine: afterLine, body: body });
      }
    });
  }

  function setupNoteAffordances() {
    document.documentElement.classList.add("pm-commenting-on");
    var layer = document.createElement("div");
    layer.className = "pm-affordance-layer pm-annotation";
    content.append(layer);
    for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
      var m = /^(\d+)-(\d+)$/.exec(
        (el.getAttribute && el.getAttribute("data-pm-lines")) || "");
      if (!m) { continue; }
      var subs = el.querySelectorAll("[data-pm-sublines]");
      if (subs.length) {
        // Container blocks delegate to their units: the item or row
        // under the pointer is the target, never the whole list or
        // table (spec: nested-comment-targets).
        var blockEl = el;
        var blockEnd = +m[2];
        subs.forEach(function (unit) {
          attachNoteAffordance(layer, unit, blockEl, blockEnd);
        });
      } else {
        attachNoteAffordance(layer, el, el, +m[2]);
      }
    }
  }

  // Menu-driven entry (Add Margin Note / File Margin Note): file-level
  // opens at the top; otherwise the composer opens on the block nearest
  // the top of the viewport — the one the reader is on.
  window.__pmOpenNoteComposer = function (fileLevel) {
    if (fileLevel) {
      noteComposerOpen({
        anchor: null,
        placeholder: pmString("Leave a note about the whole document"),
        onSubmit: function (body) {
          post({ type: "noteAdd", afterLine: 0, body: body });
        }
      });
      return;
    }
    var target = null;
    var targetEnd = 0;
    for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
      var m = /^(\d+)-(\d+)$/.exec(
        (el.getAttribute && el.getAttribute("data-pm-lines")) || "");
      if (!m) { continue; }
      if (!target) { target = el; targetEnd = +m[2]; }
      if (el.getBoundingClientRect().bottom > 80) {
        target = el;
        targetEnd = +m[2];
        break;
      }
    }
    if (target) { openNoteComposerAt(target, targetEnd); }
  };

  // ---- Review discussion (PR overview, spec: pr-review-discussion) ----
  // Every review thread on the PR, grouped by file — including files
  // PullMark doesn't render. Cards are the standard thread cards
  // (reply, reactions, resolve, collapsed-resolved) plus a clamped
  // hunk-tail excerpt whose last line is the commented line, and one
  // routing action: Markdown files jump in-app, others open the root
  // comment's #discussion_r permalink on GitHub (the one link that
  // still lands when a thread is outdated).

  // Markdown threads default to a rich preview: the commented passage
  // rendered as Markdown — showing it as it reads, which is the app's
  // whole point. Change highlighting matches the main rendered-diff
  // view's band treatment: contiguous added lines render as a
  // green-banded fragment, deleted lines as a red-banded one, context
  // plain. Code files keep the raw hunk tail.
  function discussionPreviewEl(item) {
    var runs = [];
    (item.excerpt || []).forEach(function (line) {
      var last = runs[runs.length - 1];
      if (last && last.kind === line.kind) { last.lines.push(line.text); }
      else { runs.push({ kind: line.kind, lines: [line.text] }); }
    });
    var div = document.createElement("div");
    div.className = "pm-discussion-preview";
    var any = false;
    runs.forEach(function (run) {
      var src = run.lines.join("\n");
      if (!src.trim()) { return; }
      var part = document.createElement("div");
      part.className = "pm-preview-" + run.kind;
      part.innerHTML = render(src);
      div.append(part);
      any = true;
    });
    return any ? div : null;
  }

  // A passage that is entirely table rows joins into ONE rendered
  // table — separate per-run renders would orphan an added row into a
  // pipe-text fragment. Rows tint by kind like the main view's bands;
  // a tail that lost its header up the clamp renders under a hidden
  // synthesized one. Null when the passage isn't all table rows.
  function discussionTablePreviewEl(item) {
    var lines = (item.excerpt || []).filter(function (line) {
      return line.text.trim() !== "";
    });
    if (lines.length < 2) { return null; }
    var allTable = lines.every(function (line) {
      return line.text.trim().charAt(0) === "|";
    });
    if (!allTable) { return null; }
    var delim = /^\|?[\s:|-]+\|?$/;
    var hasHeader = delim.test(lines[1].text.trim())
      && !delim.test(lines[0].text.trim());
    var src = [];
    var body;
    if (hasHeader) {
      src.push(lines[0].text, lines[1].text);
      body = lines.slice(2);
    } else {
      var cols = Math.max(1, (lines[0].text.match(/\|/g) || []).length - 1);
      src.push("|" + Array(cols + 1).join("   |"),
               "|" + Array(cols + 1).join(" - |"));
      body = lines.filter(function (line) { return !delim.test(line.text.trim()); });
    }
    body.forEach(function (line) { src.push(line.text); });
    var host = document.createElement("div");
    host.innerHTML = render(src.join("\n"));
    var table = host.querySelector("table");
    if (!table) { return null; }
    var rows = table.querySelectorAll("tbody tr");
    for (var i = 0; i < rows.length && i < body.length; i++) {
      if (body[i].kind === "add") { rows[i].classList.add("pm-preview-row-add"); }
      else if (body[i].kind === "del") { rows[i].classList.add("pm-preview-row-del"); }
    }
    var div = document.createElement("div");
    div.className = "pm-discussion-preview"
      + (hasHeader ? "" : " pm-preview-headless");
    while (host.firstChild) { div.append(host.firstChild); }
    return div;
  }

  function discussionExcerptEl(item) {
    if (!(item.excerpt || []).length) { return null; }
    var pre = document.createElement("pre");
    pre.className = "pm-discussion-hunk";
    item.excerpt.forEach(function (line) {
      var row = document.createElement("div");
      row.className = "pm-hunk-line pm-hunk-" + line.kind;
      var marker = document.createElement("span");
      marker.className = "pm-hunk-marker";
      marker.textContent = line.kind === "add" ? "+"
        : line.kind === "del" ? "-" : " ";
      var code = document.createElement("code");
      if (item.language) { code.className = "language-" + item.language; }
      code.textContent = line.text;
      if (item.language && window.hljs) {
        try { hljs.highlightElement(code); } catch (e) { /* plain is fine */ }
      }
      row.append(marker, code);
      pre.append(row);
    });
    return pre;
  }

  function discussionActionEl(group, item) {
    // No permalink (demo data, deleted comments) → no dead button.
    if (!group.isMarkdown && !item.htmlUrl) { return null; }
    var action = document.createElement("button");
    action.type = "button";
    action.className = "pm-discussion-action";
    if (group.isMarkdown) {
      action.textContent = pmString("View in File");
      action.title = pmFormat("Open {path} and jump to this conversation", {path: group.path});
      action.addEventListener("click", function () {
        post({ type: "openPRComment", path: group.path, rootID: item.rootID });
      });
    } else {
      action.textContent = pmString("Show on GitHub");
      action.title = pmString("Open this conversation on GitHub — PullMark doesn't render this file");
      action.addEventListener("click", function () {
        if (item.htmlUrl) { post({ type: "openExternal", url: item.htmlUrl }); }
      });
    }
    return action;
  }

  // ---- Conversation timeline (PR overview, spec: pr-cockpit) ----
  // Issue comments interleaved with review verdicts, chronological.
  // Cards reuse the thread-card chrome; `source` on each card object
  // routes its bridge messages to the issue-comment/review endpoints
  // instead of /pulls/comments.

  // Conversation cards show faces — a timeline of people talking wants
  // avatars the way GitHub's does. The wrapper survives the img-error
  // swap to initials (blameAvatarEl replaces its own node).
  function conversationAvatarEl(author, avatarUrl) {
    var wrap = document.createElement("span");
    wrap.className = "pm-conv-avatar";
    wrap.append(blameAvatarEl(author, avatarUrl));
    return wrap;
  }

  function verdictText(kind) {
    switch (kind) {
      case "approved": return pmString("approved these changes");
      case "changes_requested": return pmString("requested changes");
      case "dismissed": return pmString("dismissed their review");
      default: return pmString("reviewed");
    }
  }

  // A review's inline threads render nested and indented under its
  // verdict card — GitHub's conversation-tab shape: the summary and
  // the line comments it came with stay connected.
  function conversationThreadsEl(threads) {
    var nest = document.createElement("div");
    nest.className = "pm-conversation-threads";
    threads.forEach(function (t) {
      nest.append(discussionThreadCardEl(
        { path: t.path, isMarkdown: t.isMarkdown }, t.item, true));
    });
    return nest;
  }

  function conversationCardEl(entry) {
    var c = entry.card;
    c.source = entry.kind === "comment" ? "conversation" : "review";
    var box = document.createElement("div");
    box.className = "pm-thread pm-conversation-card";
    if (entry.kind !== "comment") {
      var verdict = document.createElement("div");
      verdict.className = "pm-verdict pm-verdict-" + entry.kind;
      verdict.append(conversationAvatarEl(c.author, c.avatarUrl));
      // Only real verdicts get a glyph — a "reviewed" line with a dot
      // in front reads as an artifact, not an icon.
      if (entry.kind === "approved" || entry.kind === "changes_requested") {
        verdict.append(svgIcon(entry.kind === "approved"
          ? "check-circle" : "plusminus-circle", "pm-verdict-icon"));
      }
      var text = document.createElement("span");
      // The verdict line owns author + date — the card byline beneath
      // would repeat both, so review cards hide it (CSS).
      text.textContent = c.author + " " + verdictText(entry.kind)
        + (c.dateLabel ? " · " + c.dateLabel : "");
      verdict.append(text);
      box.append(verdict);
      // A verdict with no summary is complete as a headline — no empty
      // body beneath it (APPROVED usually says nothing). Only REAL
      // chips earn the comment shell; a canReact-only shell renders as
      // a dead band under a rule, which reads as a failed load.
      var hasChips = c.id && c.reactions && c.reactions.length;
      if ((c.body || "").trim() || hasChips) {
        var reviewComment = commentEl(c);
        if (!(c.body || "").trim()) {
          var emptyBody = reviewComment.querySelector(".pm-thread-body");
          if (emptyBody) { emptyBody.remove(); }
        }
        box.append(reviewComment);
      }
      if ((entry.threads || []).length) {
        box.append(conversationThreadsEl(entry.threads));
      }
      return box;
    }
    box.append(commentEl(c));
    return box;
  }

  // The section-foot composer: always present (GitHub's convention),
  // draft-persistent, ⌘↩ submits. Unlike reply composers it never
  // closes — input just syncs the draft.
  function conversationComposerEl() {
    var draftKey = "conversation:new";
    var root = document.createElement("div");
    root.className = "pm-reply-composer pm-conversation-composer";
    var ta = document.createElement("textarea");
    ta.className = "pm-composer-text";
    ta.placeholder = pmString("Comment on the pull request conversation");
    ta.rows = 2;
    var actions = document.createElement("div");
    actions.className = "pm-composer-actions";
    var send = document.createElement("button");
    send.type = "button";
    send.className = "pm-composer-primary";
    send.textContent = pmString("Comment");
    send.title = pmString("Post to the PR conversation right away — not part of a review (⌘↩)");
    actions.append(send);
    root.append(ta, actions);

    var syncTimer = null;
    function grow() {
      ta.style.height = "auto";
      ta.style.height = Math.max(56, ta.scrollHeight) + "px";
    }
    function submit() {
      var body = ta.value.trim();
      if (body === "") { return; }
      post({ type: "conversationSubmit", body: body, draftKey: draftKey });
      draftDiscard(draftKey);
      ta.value = "";
      send.disabled = true;
      grow();
    }
    send.addEventListener("click", submit);
    ta.addEventListener("input", function () {
      grow();
      send.disabled = ta.value.trim() === "";
      if (syncTimer) { clearTimeout(syncTimer); }
      syncTimer = setTimeout(function () {
        syncTimer = null;
        draftSave(draftKey, ta.value);
      }, 400);
    });
    ta.addEventListener("keydown", function (event) {
      if (event.isComposing) { return; }
      if (event.key === "Enter" && event.metaKey) {
        event.preventDefault();
        event.stopPropagation();
        submit();
      }
    });
    root.__pmFlushDraft = function () { draftSave(draftKey, ta.value); };
    var draft = composerDrafts[draftKey];
    if (draft) { ta.value = draft; }
    send.disabled = ta.value.trim() === "";
    // The restored draft needs a layout pass before scrollHeight is
    // real — grow after insertion (the caller appends synchronously).
    setTimeout(grow, 0);
    return root;
  }

  function setupConversation(entries) {
    var section = document.createElement("section");
    section.className = "pm-conversation pm-annotation";
    var heading = document.createElement("h2");
    heading.className = "pm-discussion-heading";
    heading.textContent = pmString("Conversation");
    if (entries.length) {
      // The count carries state, not arithmetic — "5 entries" counts
      // what's already visible; reviews vs comments says what kind of
      // conversation this is (design-review catch).
      var reviews = entries.filter(function (e) { return e.kind !== "comment"; }).length;
      var comments = entries.length - reviews;
      var parts = [];
      if (reviews) {
        parts.push(pmFormat(reviews === 1 ? "{n} review" : "{n} reviews", {n: reviews}));
      }
      if (comments) {
        parts.push(pmFormat(comments === 1 ? "{n} comment" : "{n} comments", {n: comments}));
      }
      var count = document.createElement("span");
      count.className = "pm-discussion-count";
      count.textContent = parts.join(" · ");
      heading.append(count);
    }
    section.append(heading);
    if (payload.conversationUnavailable) {
      var note = document.createElement("p");
      note.className = "pm-empty-note";
      note.textContent = pmString("The conversation could not be loaded — retrying.");
      section.append(note);
    }
    entries.forEach(function (entry) {
      section.append(conversationCardEl(entry));
    });
    if (payload.conversationComposer) {
      section.append(conversationComposerEl());
    }
    rewriteRemoteResources(section);
    rewriteAttachmentImages(section);
    enhance(section);
    content.append(section);
  }

  // One review thread as a card: the standard thread card (reply,
  // reactions, resolve, collapsed resolved) with the excerpt slotted
  // above the comments and the routing action in the header row.
  // `group` carries {path, isMarkdown}; `withPath` prepends the file
  // path into the header — nested timeline cards have no per-file
  // group header to inherit it from.
  function discussionThreadCardEl(group, item, withPath) {
    var wrap = threadsEl([item]);
    var box = wrap.querySelector(".pm-thread");
    if (box) {
      var boxHeader = box.querySelector(".pm-thread-header");
      if (withPath && boxHeader) {
        var pathEl = document.createElement("span");
        pathEl.className = "pm-thread-path";
        pathEl.textContent = group.path;
        boxHeader.prepend(pathEl);
      }
      var action = discussionActionEl(group, item);
      if (boxHeader && action) { boxHeader.append(action); }
      // Markdown gets the rich preview unless the raw form is more
      // honest: a thread anchored ON a deleted line (the discussed
      // text isn't in the new side), or a clamped tail that crosses
      // a fence boundary (fence-interior text would masquerade as
      // Markdown). Empty previews also fall back.
      var excerpt = null;
      if (group.isMarkdown) {
        var last = (item.excerpt || [])[item.excerpt.length - 1];
        var crossesFence = (item.excerpt || []).some(function (line) {
          var bare = line.text.trim().slice(0, 3);
          return bare === "```" || bare === "~~~";
        });
        if (!(last && last.kind === "del") && !crossesFence) {
          excerpt = discussionTablePreviewEl(item) || discussionPreviewEl(item);
        }
      }
      if (!excerpt) { excerpt = discussionExcerptEl(item); }
      if (excerpt) {
        if (boxHeader) { boxHeader.after(excerpt); }
        else { box.prepend(excerpt); }
      }
    }
    return wrap;
  }

  function setupDiscussion(groups) {
    var section = document.createElement("section");
    section.className = "pm-discussion pm-annotation";
    var unresolved = groups.reduce(function (sum, g) {
      return sum + g.unresolvedCount;
    }, 0);
    var heading = document.createElement("h2");
    heading.className = "pm-discussion-heading";
    heading.textContent = pmString("Review discussion");
    var count = document.createElement("span");
    count.className = "pm-discussion-count";
    count.textContent = unresolved === 0
      ? pmString("all conversations resolved")
      : pmFormat(unresolved === 1 ? "{n} unresolved conversation"
                                  : "{n} unresolved conversations", {n: unresolved});
    heading.append(count);
    section.append(heading);

    groups.forEach(function (group) {
      var header = document.createElement("div");
      header.className = "pm-discussion-file";
      var path = document.createElement("span");
      path.className = "pm-discussion-path";
      path.textContent = group.path;
      header.append(path);
      if (group.unresolvedCount > 0) {
        var badge = document.createElement("span");
        badge.className = "pm-discussion-file-count";
        badge.textContent = group.unresolvedCount + " unresolved";
        header.append(badge);
      }
      section.append(header);

      group.threads.forEach(function (item) {
        section.append(discussionThreadCardEl(group, item, false));
      });
    });
    // The same enhancement pass file views give thread cards: suggestion
    // blocks get their container, fenced code in comment bodies gets
    // highlighting, remote images resolve. The excerpt lines are exempt
    // inside enhance() — auto-detection would colorize plain hunks.
    rewriteRemoteResources(section);
    rewriteAttachmentImages(section);
    enhance(section);
    content.append(section);
  }

  // The overview's View in File jump lands here after the file's page
  // loads: find the thread's card, expand it if resolved-collapsed,
  // scroll it to center, and flash it. False when the card isn't on
  // this page (Swift falls back to plain navigation).
  window.__pmRevealThread = function (rootID) {
    var box = content.querySelector('.pm-thread[data-pm-root="' + rootID + '"]');
    if (!box) { return false; }
    if (box.classList.contains("pm-thread-collapsed")) {
      var summary = box.querySelector(".pm-thread-summary");
      if (summary) { summary.click(); }
    }
    box.scrollIntoView({ block: "center" });
    box.classList.add("pm-thread-flash");
    setTimeout(function () { box.classList.remove("pm-thread-flash"); }, 1800);
    return true;
  };

  // ---- Resolved-conversation visibility (Result view, spec §1) ----
  // Hidden by default; the in-page "N resolved conversations" control and
  // the native View menu item mirror each other through this hook.

  var resolvedShown = false;
  var resolvedListeners = [];
  window.__pmSetResolvedShown = function (visible) {
    visible = !!visible;
    if (visible === resolvedShown) { return; }
    resolvedShown = visible;
    resolvedListeners.forEach(function (fn) { fn(visible); });
  };

  // Exports are the document only (spec): Swift serializes this instead of
  // the raw DOM, so markers, highlights, thread cards, and controls never
  // reach an exported file.
  window.__pmExportDOM = function () {
    var clone = document.documentElement.cloneNode(true);
    clone.querySelectorAll(".pm-annotation, .pm-threads").forEach(function (el) {
      el.remove();
    });
    clone.querySelectorAll(".pm-commented, .pm-pending-anchor, .pm-anchor-open, "
        + ".pm-commentable, .pm-hover-target, .pm-delegates")
      .forEach(function (el) {
        el.classList.remove("pm-commented", "pm-pending-anchor", "pm-anchor-open",
                            "pm-commentable", "pm-hover-target", "pm-delegates");
      });
    clone.classList.remove("pm-markers-on", "pm-commenting-on", "pm-exporting");
    return clone.outerHTML;
  };

  // "moved" marker: the diff engine recognized this block as relocated
  // verbatim, so it renders once — here — instead of as red + green noise.
  function movedChip(seg) {
    var chip = document.createElement("span");
    chip.className = "pm-moved-chip";
    chip.textContent = pmString("moved");
    if (seg.movedFromLine) {
      chip.title = pmFormat("Moved from line {n} — content unchanged", {n: seg.movedFromLine});
    }
    return chip;
  }

  function inlineSegmentEl(seg, target) {
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
      renderSegmentText(div, seg.text, seg.fmText,
                        seg.kind === "added" || seg.kind === "removed");
      if (seg.kind === "added" || seg.kind === "removed") { markEmptyBlock(div); }
      wrap.append(div);
      if (seg.kind === "moved") { wrap.append(movedChip(seg)); }
      // Sub-unit targets exist only where the rendered structure IS the
      // new side's source (spec: nested-comment-targets): added and
      // unchanged segments. Modified merges old and new lines; removed
      // is the old side.
      if ((seg.kind === "added" || seg.kind === "unchanged") && !seg.fmText) {
        stampSegmentSubUnits(div, seg.text, seg.lineStart);
      }
    }
    if (payload.commentable !== false) {
      var units = wrap.querySelectorAll("[data-pm-sublines]");
      if (units.length) {
        wrap.classList.add("pm-delegates");
        units.forEach(function (unit) {
          attachUnitHover(wrap, unit, seg, target);
        });
      } else {
        wrap.append(commentButton(seg, target));
        attachBlockHover(wrap);
      }
    }
    stampSegmentNumber(wrap, seg);
    return wrap;
  }

  // A diff segment renders exactly one Markdown block; when that block
  // is a list or table its units get their own line stamps, offset to
  // the segment's new-file coordinates. "footnotes" is marked-footnote's
  // synthetic container token, emitted first on every lex — same skip
  // annotateBlockLines does.
  function stampSegmentSubUnits(container, text, startLine) {
    var el = container.firstElementChild;
    if (!el) { return; }
    var tokens;
    try { tokens = marked.lexer(text || ""); } catch (e) { return; }
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i].type === "space" || tokens[i].type === "footnotes") { continue; }
      stampSubUnits(el, tokens[i], startLine);
      return;
    }
  }

  // The diff-view sibling of attachBlockHover, for one unit of a
  // delegated block: same rail placement, latch, and probe claim, but
  // the button aligns to the item or row and comments on its own lines.
  function attachUnitHover(wrap, unit, seg, target) {
    var r = subUnitRange(unit);
    if (!r) { return; }
    unit.classList.add("pm-commentable");
    var btn = document.createElement("button");
    btn.className = "pm-comment-btn";
    btn.type = "button";
    btn.innerHTML = COMMENT_ICON;
    btn.title = r[1] === r[0]
      ? pmFormat("Comment on new line {n}", {n: r[0]})
      : pmFormat("Comment on new lines {a}–{b}", {a: r[0], b: r[1]});
    btn.setAttribute("aria-label", btn.title);
    btn.style.display = "none";
    btn.addEventListener("click", function (event) {
      event.stopPropagation();
      composerForSegment(seg, target, false, r);
    });
    wrap.append(btn);
    var hideTimer = null;
    function hideNow() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      btn.style.display = "none";
      unit.classList.remove("pm-hover-target");
    }
    function place() {
      btn.style.display = "flex";
      var wr = wrap.getBoundingClientRect();
      var art = content.getBoundingClientRect();
      var bw = btn.getBoundingClientRect().width || 28;
      btn.style.left = Math.round(art.right - art.left - bw - 6 - (wr.left - art.left)) + "px";
      btn.style.right = "auto";
      var ur = unit.getBoundingClientRect();
      btn.style.top = Math.round(stickyRailY(ur.top, ur.bottom) - wr.top) + "px";
    }
    function show() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      if (activeBlockBubble && activeBlockBubble !== hideNow) { activeBlockBubble(); }
      activeBlockBubble = hideNow;
      virtualHover = unit;
      unit.classList.add("pm-hover-target");
      place();
    }
    function hide() {
      if (hideTimer) { clearTimeout(hideTimer); }
      hideTimer = setTimeout(function () {
        btn.style.display = "none";
        unit.classList.remove("pm-hover-target");
      }, 120);
    }
    unit.addEventListener("mouseenter", show);
    unit.addEventListener("mouseleave", hide);
    btn.addEventListener("mouseenter", show);
    btn.addEventListener("mouseleave", hide);
  }

  // Line-number annotations for a diff block, resolved here where the
  // segment's sides are known. One number per block — new-file by default;
  // a removed block's is an old-file coordinate and styled as such. The
  // word-diff merged rendering is a single block, so it gets a single
  // new-side number with both truths in the tooltip.
  function stampSegmentNumber(wrap, seg) {
    var tip = rangeText(seg.lineStart, seg.lineEnd);
    if (seg.kind === "removed") {
      tip = seg.lineStart === seg.lineEnd
        ? pmFormat("Old line {n}", {n: seg.lineStart})
        : pmFormat("Old lines {a}–{b}", {a: seg.lineStart, b: seg.lineEnd});
      wrap.setAttribute("data-pm-num-old", "1");
    } else if (seg.kind === "modified" && seg.oldLineStart) {
      tip += pmFormat(" · was {r}", {r: seg.oldLineStart === seg.oldLineEnd
        ? seg.oldLineStart : seg.oldLineStart + "–" + seg.oldLineEnd});
    } else if (seg.kind === "moved" && seg.movedFromLine) {
      tip += " · moved from " + seg.movedFromLine;
    }
    wrap.setAttribute("data-pm-num", seg.lineStart);
    wrap.setAttribute("data-pm-num-tip", tip);
  }

  // Inline-diff affordances get the Result-view treatment: positioned at
  // hover time against the block's real CONTENT — a narrow table's own
  // edge, not the full-column wrapper (which put buttons a window away at
  // Full Width), and the first line's text top, not the wrapper box (which
  // floated them into a heading's interior margin). Fully outside the
  // content edge, stacked like .pm-result-tools; JS show/hide with the
  // same grace so buttons past the wrapper's hover box stay reachable.
  function attachBlockHover(wrap) {
    var btn = wrap.querySelector(":scope > .pm-comment-btn");
    if (!btn) { return; }
    var hideTimer = null;
    function hideNow() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      btn.style.display = "none";
      wrap.classList.remove("pm-hover-target");
    }
    function place() {
      btn.style.display = "flex";
      var wr = wrap.getBoundingClientRect();
      var art = content.getBoundingClientRect();
      var bw = btn.getBoundingClientRect().width || 28;
      // The page reserves comment-room padding (app.css), so the rail
      // always fits: inset from the article edge, clear of the block
      // bleed, aligned across blocks.
      btn.style.left = Math.round(art.right - art.left - bw - 6 - (wr.left - art.left)) + "px";
      btn.style.right = "auto";
      // Anchored to the first line of visible content, not the wrapper
      // box — a heading's interior margin must not float the bubble.
      var top = null;
      wrap.querySelectorAll(":scope > div:not(.pm-threads)").forEach(function (d) {
        if (top !== null) { return; }
        for (var c = d.firstElementChild; c; c = c.nextElementSibling) {
          var r = c.getBoundingClientRect();
          if (r.height) { top = r.top; break; }
        }
        if (top === null) {
          var dr = d.getBoundingClientRect();
          if (dr.height) { top = dr.top; }
        }
      });
      if (top === null) { top = wr.top; }
      btn.style.top = Math.round(stickyRailY(top, wr.bottom) - wr.top) + "px";
    }
    function show() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      // Exactly one bubble at a time: a lingering neighbor (hide grace)
      // must vanish the moment another block's bubble appears.
      if (activeBlockBubble && activeBlockBubble !== hideNow) { activeBlockBubble(); }
      activeBlockBubble = hideNow;
      // Keep the probe's claim on the block that actually showed last: a
      // fast flick can real-enter a block between probe ticks, and a
      // stale claim would steal its bubble back on the next dead row.
      virtualHover = wrap;
      wrap.classList.add("pm-hover-target");
      place();
    }
    function hide() {
      if (hideTimer) { clearTimeout(hideTimer); }
      hideTimer = setTimeout(function () {
        btn.style.display = "none";
        wrap.classList.remove("pm-hover-target");
      }, 120);
    }
    wrap.addEventListener("mouseenter", show);
    wrap.addEventListener("mouseleave", hide);
    btn.addEventListener("mouseenter", show);
    btn.addEventListener("mouseleave", hide);
  }
  var activeBlockBubble = null;

  // The content surface is one continuous hover zone. Blocks' real hover
  // boxes end at their bleed, but the affordance must survive everywhere
  // a pointer travels en route to a bubble: the reserved right margin,
  // the vertical gaps between blocks, the rows beside note and thread
  // cards, and the wide dead stretch beside a narrow table. This virtual
  // hover probes which block sits at the pointer's height whenever the
  // pointer is over the content, re-evaluated on scroll; rows that
  // resolve to no block keep the last live one, so only genuinely
  // leaving the surface (or another block claiming the rail) retires a
  // bubble.
  var pointerAt = null;
  var virtualHover = null;
  var probeQueued = false;
  function setVirtualHover(target) {
    if (virtualHover === target) {
      // Refresh, don't no-op: the block's REAL mouseleave (fired when the
      // pointer crossed its edge into the rail) starts a hide timer that
      // only a fresh enter cancels. A probe that agrees "still this block"
      // must say so, or the bubble dies mid-reach.
      if (target) { target.dispatchEvent(new Event("mouseenter")); }
      return;
    }
    if (virtualHover) { virtualHover.dispatchEvent(new Event("mouseleave")); }
    virtualHover = target;
    if (target) { target.dispatchEvent(new Event("mouseenter")); }
  }
  function surfaceHoverProbe() {
    probeQueued = false;
    if (!pointerAt) { return; }
    if (!document.documentElement.classList.contains("pm-comment-room")
        && !document.documentElement.classList.contains("pm-commenting-on")) { return; }
    var art = content.getBoundingClientRect();
    // The whole content surface, not just a rail-side strip: the journey
    // from a narrow block (a small table) to its rail bubble crosses a
    // wide stretch that hovers nothing, and every such dead spot used to
    // blink the bubble away mid-reach.
    var overContent = pointerAt.x >= art.left && pointerAt.x <= art.right + 4
      && pointerAt.y >= art.top && pointerAt.y <= art.bottom;
    if (!overContent) {
      // Off the surface. If the pointer sits inside the claimed block's
      // own box (its bleed extends past the content edge), real hover
      // owns it — quietly drop the claim, because a synthetic leave
      // would un-hover a block the pointer is genuinely inside and
      // nothing re-fires a real enter until it exits and returns.
      // Anywhere else, retire the bubble properly.
      if (virtualHover) {
        var r = virtualHover.getBoundingClientRect();
        if (pointerAt.x >= r.left && pointerAt.x <= r.right
            && pointerAt.y >= r.top && pointerAt.y <= r.bottom) {
          virtualHover = null;
        } else {
          setVirtualHover(null);
        }
      }
      return;
    }
    // Resolve the block at the pointer's row. Away from the rail the
    // pointer itself is the truth — probing anywhere else can resurrect
    // a stale block and fight the real hover. In the rail zone the
    // bubble may sit under the pointer, so probe at dodged x positions,
    // several depths deep, because a shrink-to-fit table's box ends
    // well left of the deepest one.
    var candidates = pointerAt.x >= art.right - 60
      ? [Math.max(art.left + 20, art.right - 90),
         art.left + (art.right - art.left) * 0.5,
         art.left + (art.right - art.left) * 0.15]
      : [pointerAt.x];
    var target = null;
    for (var ci = 0; ci < candidates.length && !target; ci++) {
      var probe = document.elementFromPoint(candidates[ci], pointerAt.y);
      target = probe && probe.closest
        ? probe.closest(".pm-block, .pm-commentable") : null;
      // A container that delegated to its units (a diff block whose
      // list comments per item) has no bubble of its own: claiming it
      // would kill the item bubble on every between-items row. Treat
      // it as a dead row so the sticky claim below keeps the item.
      if (target && target.classList.contains("pm-delegates")) { target = null; }
    }
    // Dead rows — the margin gap between blocks, the rows beside a
    // note/thread card, the stretch beside a narrow block — probe to
    // nothing. While the pointer stays on the surface, keep the last
    // live block: the page must read as one continuous hover surface,
    // or every dead spot crossed en route to a bubble blinks it away
    // (the reported flicker). A kept block must still be rendered — a
    // zero-height rect means it was hidden (a block-edit reveal) or
    // detached, and resurrecting it would pin a phantom bubble to its
    // collapsed rect.
    if (!target && virtualHover
        && virtualHover.getBoundingClientRect().height > 0) {
      target = virtualHover;
    }
    setVirtualHover(target);
  }
  function queueProbe() {
    if (probeQueued) { return; }
    probeQueued = true;
    // A timeout, not requestAnimationFrame: rAF stalls in occluded or
    // headless webviews, and this must fire while scrolling regardless.
    setTimeout(surfaceHoverProbe, 16);
  }
  document.addEventListener("mousemove", function (event) {
    pointerAt = { x: event.clientX, y: event.clientY };
    queueProbe();
  }, { passive: true });
  window.addEventListener("scroll", queueProbe, { passive: true });
  // The pointer leaving the page entirely must retire the claim: the
  // trailing 16ms probe otherwise outlives the blocks' real mouseleave
  // and keeps a bubble lit in an unhovered window — and the scroll
  // re-probe would keep lighting fresh ones with the stranded position.
  document.addEventListener("mouseout", function (event) {
    if (event.relatedTarget === null) {
      pointerAt = null;
      setVirtualHover(null);
    }
  });
  window.addEventListener("blur", function () {
    pointerAt = null;
    setVirtualHover(null);
  });

  function renderInline(segments) {
    if (payload.commentable !== false) {
      document.documentElement.classList.add("pm-comment-room");
    }
    segments.forEach(function (seg) {
      // The composer inserts after the segment's LAST associated element
      // (thread and pending cards included) — a sibling of the cards.
      var target = { block: null, anchor: null, split: false };
      var wrap = inlineSegmentEl(seg, target);
      target.block = wrap;
      target.anchor = wrap;
      content.append(wrap);
      if (seg.threads && seg.threads.length) {
        var threads = threadsEl(seg.threads);
        content.append(threads);
        target.anchor = threads;
      }
      if (seg.pending && seg.pending.length) {
        var pending = pendingEl(seg.pending);
        content.append(pending);
        target.anchor = pending;
      }
    });
  }

  // A split-view line-number grid item. Both columns are first-class
  // sides here, so numbers are plain; the tooltip still names the old
  // file on the left. Empty cells get an empty item (placement filler).
  function splitNumberEl(range, oldSide) {
    var label = document.createElement("span");
    label.className = "pm-linenum";
    if (range) {
      label.textContent = range[0];
      var text = rangeText(range[0], range[1]);
      label.title = oldSide ? "Old " + text.toLowerCase() : text;
    }
    return label;
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
      } else if (seg.kind === "moved") {
        renderSegmentText(left, seg.text, seg.fmText, false);
        renderSegmentText(right, seg.text, seg.fmText, false);
        right.classList.add("pm-cell-moved");
        right.append(movedChip(seg));
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
      var target = { block: seg.side === "LEFT" ? left : right,
                     anchor: right, split: true };
      if (payload.commentable !== false) {
        (seg.side === "LEFT" ? left : right).append(commentButton(seg, target));
      }
      // Line-number grid items — one per cell, empty for empty cells, so
      // each row always contributes four items and auto-placement holds.
      var leftRange = null;
      var rightRange = null;
      if (seg.kind === "removed") {
        leftRange = [seg.lineStart, seg.lineEnd];
      } else {
        if (seg.oldLineStart) { leftRange = [seg.oldLineStart, seg.oldLineEnd]; }
        rightRange = [seg.lineStart, seg.lineEnd];
      }
      grid.append(splitNumberEl(leftRange, true), left,
                  splitNumberEl(rightRange, false), right);
      if (seg.threads && seg.threads.length) {
        var full = document.createElement("div");
        full.className = "pm-split-full";
        full.append(threadsEl(seg.threads));
        grid.append(full);
        target.anchor = full;
      }
      if (seg.pending && seg.pending.length) {
        var pendingFull = document.createElement("div");
        pendingFull.className = "pm-split-full";
        pendingFull.append(pendingEl(seg.pending));
        grid.append(pendingFull);
        target.anchor = pendingFull;
      }
    });
    content.append(grid);
  }

  function appendOutdated() {
    // Whole-file comments first (deliberately unanchored), then the
    // genuinely outdated line threads.
    var fileThreads = payload.fileThreads || [];
    if (fileThreads.length) {
      var fileHeading = document.createElement("h2");
      fileHeading.className = "pm-outdated-heading";
      fileHeading.textContent = pmString("File comments");
      content.append(fileHeading, threadsEl(fileThreads));
    }
    var threads = payload.outdatedThreads || [];
    if (!threads.length) { return; }
    var heading = document.createElement("h2");
    heading.className = "pm-outdated-heading";
    heading.textContent = pmString("Outdated review comments");
    content.append(heading, threadsEl(threads));
  }

  // Source Diff with gutter badges on commented lines (spec §1, last
  // bullet): Swift maps threads and pending comments to 0-based patch line
  // indexes (PatchAnchors); clicking a badge expands the thread cards
  // inline beneath the line.
  function renderPatch(patch, rows) {
    var byIndex = {};
    (rows || []).forEach(function (row) { byIndex[row.lineIndex] = row; });
    var pre = document.createElement("pre");
    pre.className = "pm-patch";
    if (rows && rows.length) { pre.classList.add("pm-patch-annotated"); }
    var placed = [];
    var lineEls = {};
    var rawLines = (patch || "").split("\n");
    rawLines.forEach(function (line, index) {
      var span = document.createElement("span");
      if (line.startsWith("+")) { span.className = "pm-line-add"; }
      else if (line.startsWith("-")) { span.className = "pm-line-del"; }
      else if (line.startsWith("@@")) { span.className = "pm-line-hunk"; }
      span.textContent = line;
      pre.append(span, document.createTextNode("\n"));
      lineEls[index] = span;
      var row = byIndex[index];
      if (!row) { return; }
      span.classList.add("pm-patch-commented");
      var card = document.createElement("div");
      card.className = "pm-patch-threads pm-annotation";
      card.style.display = "none";
      if (row.threads && row.threads.length) { card.append(threadsEl(row.threads)); }
      if (row.pending && row.pending.length) { card.append(pendingEl(row.pending)); }
      pre.append(card);
      var threadTotal = (row.threads || []).reduce(function (sum, t) {
        return sum + (t.comments || []).length;
      }, 0);
      var pendingTotal = (row.pending || []).length;
      var badge = document.createElement("button");
      badge.type = "button";
      badge.className = "pm-marker pm-patch-badge pm-annotation";
      if (pendingTotal && !threadTotal) { badge.classList.add("pm-marker-pending"); }
      if (threadTotal && (row.threads || []).every(function (t) {
        return t.resolved === true;
      })) { badge.classList.add("pm-marker-resolved"); }
      badge.innerHTML = COMMENT_ICON;
      var count = document.createElement("span");
      count.className = "pm-marker-count";
      count.textContent = threadTotal + pendingTotal;
      badge.append(count);
      badge.title = pmFormat(threadTotal + pendingTotal === 1
        ? "{n} comment — click to expand"
        : "{n} comments — click to expand", {n: threadTotal + pendingTotal});
      badge.setAttribute("aria-label", badge.title);
      badge.setAttribute("aria-expanded", "false");
      badge.addEventListener("click", function (event) {
        event.stopPropagation();
        var open = card.style.display === "none";
        card.style.display = open ? "" : "none";
        badge.setAttribute("aria-expanded", open ? "true" : "false");
      });
      pre.append(badge);
      placed.push({ badge: badge, span: span });
    });
    content.append(pre);
    if ((payload.patchLines || []).length) {
      setupPatchCommenting(pre, lineEls, rawLines);
    }
    // Badges sit in the patch's left gutter, aligned per line; reposition
    // as cards open/close (and on wraps from window resizes).
    function positionPatchBadges() {
      placed.forEach(function (item) {
        item.badge.style.top = item.span.offsetTop + "px";
      });
    }
    positionPatchBadges();
    if (placed.length && typeof ResizeObserver === "function") {
      new ResizeObserver(positionPatchBadges).observe(pre);
    }
  }

  // ---- Source Diff line-number targeting (spec §5) ----
  // Click a line number to comment on that line; shift-click extends the
  // range GitHub-style (within one hunk, one side). The composer expands
  // beneath the range's last line. Every patch line is inside the diff by
  // construction, so no membership validation applies here.
  function setupPatchCommenting(pre, lineEls, rawLines) {
    pre.classList.add("pm-patch-numbered");
    var originByIndex = {};
    (payload.patchLines || []).forEach(function (origin) {
      originByIndex[origin.index] = origin;
    });

    var sel = null; // { side, anchorIndex, startIndex, endIndex }

    function sideOf(index) {
      return rawLines[index].charAt(0) === "-" ? "LEFT" : "RIGHT";
    }
    function fileLine(index, side) {
      var origin = originByIndex[index];
      if (!origin) { return null; }
      var line = side === "LEFT" ? origin.old : origin.new;
      return line === undefined || line === null ? null : line;
    }
    // A range must stay inside one hunk (GitHub's rule): no header row
    // between the endpoints.
    function sameHunk(a, b) {
      for (var i = Math.min(a, b); i <= Math.max(a, b); i++) {
        if (rawLines[i].indexOf("@@") === 0) { return false; }
      }
      return true;
    }
    function applyHighlight() {
      Object.keys(originByIndex).forEach(function (key) {
        var index = +key;
        var span = lineEls[index];
        if (!span) { return; }
        span.classList.toggle("pm-patch-selected",
          !!sel && sel.startIndex <= index && index <= sel.endIndex);
      });
    }
    // Clears only the selection it was created for: closing the previous
    // composer (a new line was clicked) must not wipe the new selection.
    function selectionClearer(owned) {
      return function () {
        if (sel === owned) {
          sel = null;
          applyHighlight();
        }
      };
    }
    // The node the composer inserts after: the end line's newline, past
    // any thread card or badge already sitting there.
    function composerAnchorFor(index) {
      var node = lineEls[index].nextSibling;
      while (node && node.nextSibling && node.nextSibling.nodeType === 1
             && (node.nextSibling.classList.contains("pm-patch-threads")
                 || node.nextSibling.classList.contains("pm-patch-badge"))) {
        node = node.nextSibling;
      }
      return node || lineEls[index];
    }
    // The current lines of the selected new-side range, for suggestions
    // ("-" rows have no new-side content and are skipped).
    function newSideSeed() {
      if (!sel || sel.side !== "RIGHT") { return null; }
      var lines = [];
      for (var i = sel.startIndex; i <= sel.endIndex; i++) {
        var origin = originByIndex[i];
        if (origin && origin.new !== undefined && origin.new !== null) {
          lines.push(rawLines[i].slice(1));
        }
      }
      return lines.join("\n");
    }
    function openFor(anchorLine, extending) {
      var start = fileLine(sel.startIndex, sel.side);
      var end = fileLine(sel.endIndex, sel.side);
      if (start === null || end === null) { return; }
      var key = sel.side + ":" + anchorLine + "-" + anchorLine;
      if (extending && openComposer && openComposer.draftKey === key) {
        // Shift-extension of the open composer: keep the text, move the
        // card and update the caption.
        openComposer.setRange([start, end]);
        openComposer.moveAfter(composerAnchorFor(sel.endIndex));
        return;
      }
      var owned = sel;
      composerOpen({
        anchor: composerAnchorFor(sel.endIndex),
        side: sel.side,
        range: [start, end],
        lineBase: start,
        sourceLines: null,
        seedFor: newSideSeed,
        draftKey: key,
        onClose: selectionClearer(owned)
      });
      if (!openComposer) { selectionClearer(owned)(); } // the click toggled it shut
    }

    Object.keys(originByIndex).forEach(function (key) {
      var index = +key;
      var span = lineEls[index];
      if (!span) { return; }
      var side = sideOf(index);
      var number = fileLine(index, side);
      if (number === null) { return; }
      var lineno = document.createElement("button");
      lineno.type = "button";
      lineno.className = "pm-patch-lineno pm-annotation";
      lineno.textContent = String(number);
      lineno.title = pmFormat(side === "LEFT"
        ? "Comment on old line {n} — shift-click extends the range"
        : "Comment on new line {n} — shift-click extends the range", {n: number});
      lineno.setAttribute("aria-label", lineno.title);
      lineno.addEventListener("click", function (event) {
        event.stopPropagation();
        var extending = event.shiftKey && !!sel && sel.side === side
          && sameHunk(sel.anchorIndex, index);
        if (extending) {
          sel.startIndex = Math.min(sel.anchorIndex, index);
          sel.endIndex = Math.max(sel.anchorIndex, index);
        } else {
          sel = { side: side, anchorIndex: index,
                  startIndex: index, endIndex: index };
        }
        applyHighlight();
        openFor(fileLine(sel.anchorIndex, sel.side), extending);
      });
      span.prepend(lineno);
    });
  }

  // ---- Lightbox: click media to inspect it (rendered natively) ----
  // The page only reports WHAT was clicked; the app presents a native
  // full-modal inspector. Diagrams ship their SVG text so zoom and
  // exports stay vector-crisp; images ship their source for original-
  // byte resolution on the native side.

  function lightboxSource(node) {
    if (!node || !node.closest) { return null; }
    // Linked images navigate; edit mode owns clicks entirely; the blame
    // gutter's avatars are UI (they open the history sheet), not content.
    if (node.closest("a")) { return null; }
    if (document.documentElement.classList.contains("pm-edit-mode")) { return null; }
    if (node.closest(".pm-blame-gutter")) { return null; }
    var img = node.closest("img");
    if (img && img.closest("#content")) {
      // A broken image would inspect as an empty box.
      return img.naturalWidth ? img : null;
    }
    var mermaid = node.closest(".mermaid");
    if (mermaid) { return mermaid.querySelector("svg"); }
    var katex = node.closest(".katex-display");
    // The inner .katex box hugs the formula; the display block spans the
    // whole reading column.
    if (katex) { return katex.querySelector(".katex") || katex; }
    return null;
  }

  function lightboxRequest(source) {
    var kind = source.tagName === "IMG" ? "img"
             : source.tagName === "svg" ? "svg" : "katex";
    var name = "content";
    if (kind === "img") {
      var srcPath = (source.getAttribute("src") || "").split(/[?#]/)[0];
      // Decode BEFORE taking the basename, then strip leading dots:
      // %2F-encoded slashes must not smuggle a path into a filename.
      var basename = decodeURIComponent(srcPath).split("/").pop() || "";
      basename = basename.replace(/^\.+/, "");
      name = (basename.replace(/\.[a-z0-9]+$/i, "") || "image");
    } else {
      name = kind === "svg" ? "diagram" : "formula";
    }
    var r = source.getBoundingClientRect();
    var w = r.width;
    var h = r.height;
    if (kind === "svg" && source.viewBox && source.viewBox.baseVal
        && source.viewBox.baseVal.width > 0) {
      // The reading column squeezes wide diagrams; the viewBox carries
      // the intrinsic size the inspector should lay out at.
      w = Math.max(w, source.viewBox.baseVal.width);
      h = w / Math.max(source.viewBox.baseVal.width, 1)
        * source.viewBox.baseVal.height;
    }
    var message = { type: "lightboxRequest", kind: kind, name: name,
                    x: r.left, y: r.top, w: w, h: h,
                    src: kind === "img"
                      ? (source.currentSrc || source.getAttribute("src") || "")
                      : "",
                    exportWidth: Math.min(
                      kind === "img" ? (source.naturalWidth || r.width || 1)
                                     : Math.ceil((w || 1) * 3),
                      4096) };
    if (kind === "svg") {
      try { message.svg = new XMLSerializer().serializeToString(source); }
      catch (e) { message.svg = ""; }
    }
    // KaTeX measures tight via the union of rendered line boxes.
    if (kind === "katex") {
      var tight = null;
      source.querySelectorAll(".katex-html > span").forEach(function (base) {
        var b = base.getBoundingClientRect();
        if (!b.width) { return; }
        tight = tight ? { left: Math.min(tight.left, b.left),
                          top: Math.min(tight.top, b.top),
                          right: Math.max(tight.right, b.right),
                          bottom: Math.max(tight.bottom, b.bottom) }
                      : { left: b.left, top: b.top, right: b.right, bottom: b.bottom };
      });
      if (tight) {
        message.x = tight.left;
        message.y = tight.top;
        message.w = tight.right - tight.left;
        message.h = tight.bottom - tight.top;
        message.exportWidth = Math.min(Math.ceil(message.w * 3), 4096);
      }
    }
    post(message);
  }

  // While the native inspector is open, the page still drives the
  // pointer (its tracking outlives native overlays) — so the inspector
  // reports its content frame and this region advertises the grab hand
  // there. Real clicks never reach the page while the modal is up.
  var inspectRegion = null;
  window.__pmInspectRegion = function (x, y, w, h) {
    if (x === null || x === undefined) {
      if (inspectRegion) { inspectRegion.remove(); inspectRegion = null; }
      return;
    }
    if (!inspectRegion) {
      inspectRegion = document.createElement("div");
      inspectRegion.id = "pm-inspect-region";
      inspectRegion.style.position = "fixed";
      inspectRegion.style.zIndex = "2000";
      inspectRegion.style.cursor = "grab";
      inspectRegion.style.background = "transparent";
      document.body.append(inspectRegion);
    }
    inspectRegion.style.left = x + "px";
    inspectRegion.style.top = y + "px";
    inspectRegion.style.width = w + "px";
    inspectRegion.style.height = h + "px";
  };
  window.__pmInspectHoverUI = function (over) {
    if (inspectRegion) { inspectRegion.style.cursor = over ? "auto" : "grab"; }
  };

  document.addEventListener("click", function (event) {
    var source = lightboxSource(event.target);
    if (!source) { return; }
    event.preventDefault();
    event.stopPropagation();
    // Snapshot-based content (formulas, unresolvable images) can only be
    // captured where it's visible — bring it fully into view, then
    // measure on the next frame.
    source.scrollIntoView({ block: "nearest" });
    requestAnimationFrame(function () { lightboxRequest(source); });
  }, true);

  if (!payload.editable) {
    document.documentElement.classList.add("pm-lightbox-enabled");
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
    // Local editing, in place: the pencil (or a double-click) swaps the
    // rendered block for an editor right in the page. ⌘↩ commits through
    // the bridge (Swift applies it with the same guarded, versioned write
    // path as ever), Esc restores the rendered block untouched.
    // ---- Edit mode: in-place source reveal ----
    // Click a rendered block and it reveals its source in place; leaving
    // the block (blur/Esc/click elsewhere) commits through the guarded
    // bridge. Backspace at the very start swallows the previous block into
    // the edit region (merge); blank lines typed inside split into blocks
    // on commit via the normal re-render. Deleting the region's text
    // deletes those lines.
    var revealState = null;

    // The edit-mode toggle combo, pushed by Swift on page load (users can
    // rebind it in Settings → Keyboard). Shape: {key, meta, ctrl, alt,
    // shift} with `key` in the app's canonical form ("e", "escape", "f5").
    var editToggleKey = { key: "e", meta: true, ctrl: false, alt: false, shift: false };
    window.__pmSetEditToggleKey = function (combo) { editToggleKey = combo; };

    function canonicalEventKey(event) {
      var named = {
        "Escape": "escape", "Enter": "return", "Tab": "tab", " ": "space",
        "Backspace": "delete", "Delete": "forwarddelete",
        "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left",
        "ArrowRight": "right", "Home": "home", "End": "end",
        "PageUp": "pageup", "PageDown": "pagedown",
      };
      if (named[event.key]) { return named[event.key]; }
      if (/^F([1-9]|1[0-2])$/.test(event.key)) { return event.key.toLowerCase(); }
      return event.key.length === 1 ? event.key.toLowerCase() : null;
    }

    // event.code is a US-QWERTY physical position, so it only stands in
    // for the character when Option composed the character away ("ç" for
    // ⌥C). Consulting it otherwise would fire on the wrong key for anyone
    // on Dvorak or AZERTY.
    var codeToKey = {
      Backquote: "`", Minus: "-", Equal: "=", BracketLeft: "[",
      BracketRight: "]", Backslash: "\\", Semicolon: ";", Quote: "'",
      Comma: ",", Period: ".", Slash: "/",
    };

    function physicalKey(event) {
      var code = event.code || "";
      var m = /^Key([A-Z])$/.exec(code);
      if (m) { return m[1].toLowerCase(); }
      m = /^Digit([0-9])$/.exec(code);
      if (m) { return m[1]; }
      return codeToKey[code] || null;
    }

    function matchesEditToggle(event) {
      if (!editToggleKey) { return false; }
      var key = canonicalEventKey(event);
      var matched = key === editToggleKey.key
        || (event.altKey && physicalKey(event) === editToggleKey.key);
      return matched
        && event.metaKey === !!editToggleKey.meta
        && event.ctrlKey === !!editToggleKey.ctrl
        && event.altKey === !!editToggleKey.alt
        && event.shiftKey === !!editToggleKey.shift;
    }

    function regionSource(lo, hi) {
      return (payload.markdown || "").split("\n").slice(lo - 1, hi).join("\n");
    }

    function autoGrow(ta) {
      ta.style.height = "auto";
      ta.style.height = ta.scrollHeight + "px";
    }

    function closeReveal() {
      if (!revealState) { return; }
      post({ type: "editingState", active: false });
      revealState.hidden.forEach(function (el) { el.style.display = ""; });
      revealState.wrap.remove();
      window.__pmCancelInlineEdit = null;
      revealState = null;
    }

    // Textareas normalize CRLF to LF on seed, so a byte-equal compare
    // "changes" every CRLF block just by visiting it; trailing blank
    // lines are block separators, not content.
    function seedUnchanged(value, seed) {
      var norm = function (t) { return t.replace(/\r\n?/g, "\n").replace(/\s+$/, ""); };
      return norm(value) === norm(seed);
    }

    function commitReveal(nextRevealLine) {
      var st = revealState;
      if (!st) { return; }
      if (seedUnchanged(st.ta.value, st.seed)) { closeReveal(); return; }
      st.ta.disabled = true;
      // Nulled BEFORE posting: the blur timer must never double-commit
      // (duplicate write + duplicate history snapshot, or a spurious
      // "changed underneath" notice after a successful save).
      revealState = null;
      var message = { type: "editLocal",
                      lineStart: st.lo, lineEnd: st.hi,
                      replacement: st.ta.value, seed: st.seed };
      if (nextRevealLine) { message.nextRevealLine = nextRevealLine; }
      // editLocal FIRST: the deferred-reload release (editingState) must
      // not let a stale disk read beat the edit into displayText.
      post(message);
      post({ type: "editingState", active: false });
      var cleanup = st;
      window.__pmCancelInlineEdit = function () {
        cleanup.hidden.forEach(function (el) { el.style.display = ""; });
        cleanup.wrap.remove();
        window.__pmCancelInlineEdit = null;
      };
    }

    function expandUp() {
      var st = revealState;
      if (!st) { return; }
      var prev = null;
      for (var el = content.firstElementChild; el && el !== st.wrap; el = el.nextElementSibling) {
        var r = ((el.getAttribute && el.getAttribute("data-pm-lines")) || "").split("-");
        if (el !== st.wrap && el.style.display !== "none" && r.length === 2
            && el.classList.contains("pm-editable")) {
          prev = el;
        }
      }
      if (!prev) { return; }
      var newLo = parseInt(prev.getAttribute("data-pm-lines").split("-")[0], 10);
      var prefix = regionSource(newLo, st.lo - 1);
      var caret = prefix.length + 1;
      st.ta.value = prefix + "\n" + st.ta.value;
      st.lo = newLo;
      st.seed = regionSource(st.lo, st.hi);
      prev.style.display = "none";
      st.hidden.push(prev);
      st.wrap.setAttribute("data-pm-lines", st.lo + "-" + st.hi);
      autoGrow(st.ta);
      st.ta.setSelectionRange(caret, caret);
    }

    function reveal(el, lo, hi) {
      var wrap = document.createElement("div");
      wrap.className = "pm-reveal";
      wrap.setAttribute("data-pm-lines", lo + "-" + hi);
      var ta = document.createElement("textarea");
      var seed = regionSource(lo, hi);
      ta.value = seed;
      ta.spellcheck = false;
      wrap.append(ta);
      el.style.display = "none";
      el.after(wrap);
      revealState = { wrap: wrap, ta: ta, lo: lo, hi: hi, seed: seed, hidden: [el] };
      window.__pmCancelInlineEdit = closeReveal;
      post({ type: "editingState", active: true });
      autoGrow(ta);
      ta.focus();
      ta.addEventListener("input", function () { autoGrow(ta); });
      function caretLine() {
        return ta.value.slice(0, ta.selectionStart).split("\n").length;
      }
      function navigate(direction) {
        var st = revealState;
        if (!st) { return; }
        if (!seedUnchanged(st.ta.value, st.seed)) {
          // Changed: commit, telling Swift where the caret continues after
          // the reload. The landing line is approximate (separator counts
          // vary) — __pmRevealAtLine snaps to the nearest block.
          var newLines = st.ta.value.split("\n").length;
          var target = direction > 0 ? st.lo + newLines + 1 : st.lo - 1;
          commitReveal(direction > 0 ? target : -target);
          return;
        }
        // Anchor on a block that survives closeReveal (the wrap itself is
        // removed by it): downward from the original block, upward from the
        // topmost block the region swallowed.
        var anchor = direction > 0 ? st.hidden[0] : st.hidden[st.hidden.length - 1];
        closeReveal();
        var el = direction > 0 ? anchor.nextElementSibling : anchor.previousElementSibling;
        while (el && (!el.classList || !el.classList.contains("pm-editable"))) {
          el = direction > 0 ? el.nextElementSibling : el.previousElementSibling;
        }
        if (!el) {
          // Walked past the last block: continue into the append target.
          if (direction > 0 && window.__pmAppendReveal) { window.__pmAppendReveal(); }
          return;
        }
        var parts = el.getAttribute("data-pm-lines").split("-");
        reveal(el, parseInt(parts[0], 10), parseInt(parts[1], 10));
        if (revealState) {
          // Arriving from above: caret at the start; from below: at the end.
          var n = direction > 0 ? 0 : revealState.ta.value.length;
          revealState.ta.setSelectionRange(n, n);
        }
      }
      ta.addEventListener("keydown", function (event) {
        if (matchesEditToggle(event)) {
          // The toolbar toggle's key equivalent never wins against a
          // focused text field — handle the edit-mode key (⌘E unless
          // rebound) here: commit and leave the mode.
          event.preventDefault();
          event.stopPropagation();
          commitReveal();
          post({ type: "toggleEditMode" });
          return;
        }
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          closeReveal(); // revert — leaving the block is what commits
        }
        if (event.key === "Backspace"
            && ta.selectionStart === 0 && ta.selectionEnd === 0) {
          event.preventDefault();
          expandUp();
        }
        if (event.key === "ArrowDown" && ta.selectionStart === ta.selectionEnd
            && caretLine() === ta.value.split("\n").length) {
          event.preventDefault();
          navigate(1);
        }
        if (event.key === "ArrowUp" && ta.selectionStart === ta.selectionEnd
            && caretLine() === 1) {
          event.preventDefault();
          navigate(-1);
        }
      });
      ta.addEventListener("blur", function () {
        // Leaving the block commits — leaving is the save gesture. Clicks on
        // other blocks are handled synchronously first; this covers
        // focus wandering anywhere else.
        setTimeout(function () {
          if (revealState && revealState.ta === ta) { commitReveal(); }
        }, 100);
      });
    }

    // The source line of the topmost block still visible in the viewport —
    // Swift captures it before an edit-mode flip so the re-rendered page
    // can put the reader back on the block they were reading.
    window.__pmFirstVisibleLine = function () {
      for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
        var r = ((el.getAttribute && el.getAttribute("data-pm-lines")) || "").split("-");
        if (r.length !== 2) { continue; }
        if (el.getBoundingClientRect().bottom > 12) { return parseInt(r[0], 10); }
      }
      return null;
    };

    // Continue keyboard navigation across a commit-triggered reload:
    // Swift calls this after the page loads. Negative line = caret at end.
    window.__pmRevealAtLine = function (signedLine) {
      var line = Math.abs(signedLine);
      var atEnd = signedLine < 0;
      // The requested line is approximate (blank separators vary): exact
      // containment wins, else snap to the nearest block in the travel
      // direction — downward takes the first block at/after the line,
      // upward the last block at/before it.
      var exact = null, after = null, before = null;
      for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
        var r = ((el.getAttribute && el.getAttribute("data-pm-lines")) || "").split("-");
        if (r.length !== 2 || !el.classList.contains("pm-editable")) { continue; }
        var lo = parseInt(r[0], 10), hi = parseInt(r[1], 10);
        if (lo <= line && line <= hi) { exact = el; break; }
        if (lo > line && !after) { after = el; }
        if (hi < line) { before = el; }
      }
      var target = exact || (atEnd ? before : after) || (atEnd ? after : before);
      if (!target) { return; }
      var parts = target.getAttribute("data-pm-lines").split("-");
      reveal(target, parseInt(parts[0], 10), parseInt(parts[1], 10));
      if (revealState && atEnd) {
        var n = revealState.ta.value.length;
        revealState.ta.setSelectionRange(n, n);
      }
    };

    // ⌘E lands ready to type: reveal the block under the selection, or
    // the first block — no click needed after entering edit mode.
    window.__pmRevealFocused = function () {
      if (revealState) { return; }
      var host = null;
      var selection = window.getSelection();
      if (selection && selection.anchorNode) {
        var node = selection.anchorNode.nodeType === 1
          ? selection.anchorNode : selection.anchorNode.parentElement;
        host = node && node.closest && node.closest(".pm-editable[data-pm-lines]");
      }
      if (!host) {
        for (var el = content.firstElementChild; el; el = el.nextElementSibling) {
          if (el.classList.contains("pm-editable")) { host = el; break; }
        }
      }
      if (!host) {
        if (window.__pmAppendReveal) { window.__pmAppendReveal(); }
        return;
      }
      var parts = host.getAttribute("data-pm-lines").split("-");
      reveal(host, parseInt(parts[0], 10), parseInt(parts[1], 10));
    };

    // Swift calls this before any state flip that re-renders the page
    // (⌘E off, theme change): an open reveal must commit synchronously or
    // the draft dies with the page.
    window.__pmCommitNow = function () { commitReveal(); };

    if (payload.editable && linesAnnotated) {
      document.documentElement.classList.add("pm-edit-mode");
      for (var ec = content.firstElementChild; ec; ec = ec.nextElementSibling) {
        var range = (ec.getAttribute("data-pm-lines") || "").split("-");
        if (range.length === 2) { ec.classList.add("pm-editable"); }
      }
      // End-of-document affordance: an empty doc has nothing to click,
      // and appending after the last block deserves one obvious target.
      var phantom = document.createElement("div");
      phantom.className = "pm-append";
      phantom.textContent = "+";
      phantom.title = pmString("Write at the end of the document");
      content.append(phantom);
      function appendReveal() {
        if (revealState) { commitReveal(); return; }
        var last = null;
        for (var e = content.firstElementChild; e; e = e.nextElementSibling) {
          if (e.classList.contains("pm-editable")) { last = e; }
        }
        if (last) {
          var parts = last.getAttribute("data-pm-lines").split("-");
          reveal(last, parseInt(parts[0], 10), parseInt(parts[1], 10));
        } else {
          var total = (payload.markdown || "").split("\n").length;
          reveal(phantom, 1, Math.max(1, total));
        }
        if (revealState) {
          var ta2 = revealState.ta;
          if (ta2.value !== "") { ta2.value += "\n\n"; }
          ta2.dispatchEvent(new Event("input"));
          ta2.setSelectionRange(ta2.value.length, ta2.value.length);
        }
      }
      window.__pmAppendReveal = appendReveal;
      phantom.addEventListener("click", function (event) {
        event.stopPropagation();
        appendReveal();
      });

      content.addEventListener("click", function (event) {
        if (event.target.closest("a, textarea, button, .pm-reveal")) { return; }
        var host = event.target.closest(".pm-editable[data-pm-lines]");
        if (revealState) {
          var st = revealState;
          var changed = !seedUnchanged(st.ta.value, st.seed);
          if (changed) {
            var next = 0;
            if (host && host.style.display !== "none") {
              var hostLo = parseInt(host.getAttribute("data-pm-lines").split("-")[0], 10);
              var delta = st.ta.value.split("\n").length - (st.hi - st.lo + 1);
              next = hostLo > st.hi ? hostLo + delta : hostLo;
            }
            commitReveal(next || undefined);
            return; // reload continues the reveal at the clicked block
          }
          commitReveal();
        }
        if (!host || host.style.display === "none") { return; }
        var parts = host.getAttribute("data-pm-lines").split("-");
        reveal(host, parseInt(parts[0], 10), parseInt(parts[1], 10));
      });

      // Screenshot-generator hook (pullmark://capture/reveal, gated
      // Swift-side to capture runs): reveal the block containing a
      // source line. Blocks aren't individually reachable through the
      // accessibility tree — the click listener above is delegated —
      // so scene scripts can't activate one without a real cursor.
      window.__pmRevealBlock = function (line) {
        // Mirror the click path: close any open editor first (edit-mode
        // entry auto-reveals the focused block) or two editors stack.
        if (revealState) { commitReveal(); }
        var host = null;
        content.querySelectorAll(".pm-editable[data-pm-lines]").forEach(function (el) {
          if (host || el.style.display === "none") { return; }
          var parts = el.getAttribute("data-pm-lines").split("-");
          if (parseInt(parts[0], 10) <= line && line <= parseInt(parts[1], 10)) {
            host = el;
          }
        });
        if (!host) { return; }
        var parts = host.getAttribute("data-pm-lines").split("-");
        reveal(host, parseInt(parts[0], 10), parseInt(parts[1], 10));
      };
    }

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
    rewriteAttachmentImages(content);
    setupHeadingAnchors(content);
    populateToc(reportOutline(content));
    enhance(content);
    reportStats(content);
    // Margin notes render after stats (bubble text is not document text)
    // and before mermaid, so diagrams inside note bodies render too.
    if ((payload.marginNotes || []).length) {
      setupMarginNotes(payload.marginNotes,
                       !!payload.noteAuthoring && !payload.preview);
    }
    renderMermaid();
    if (blameAnnotated) { setupBlameGutter(payload.blame); }
    if (linesAnnotated
        && ((payload.threads || []).length || (payload.pendingComments || []).length)) {
      setupThreadMarkers(payload.threads || [], payload.pendingComments || []);
    }
    // Result view of a PR file: comment affordances on blocks (spec §5).
    // Only PR Result pages carry commentableLines; local documents, the
    // overview, and browsed repo docs never grow comment chrome.
    if (linesAnnotated && payload.commentableLines && !payload.preview
        && !payload.editable) {
      setupResultCommenting();
    }
    // Local documents: the margin-note affordance on every block. Edit
    // mode keeps the page clear for block reveals (bubbles still carry
    // their own Edit/Delete there).
    if (linesAnnotated && payload.noteAuthoring && !payload.preview
        && !payload.editable) {
      setupNoteAffordances();
    }
    // PR overview: the conversation timeline first, then the review
    // discussion list beneath it (spec: pr-cockpit) — what was decided
    // and said, then what's open where.
    if ((payload.conversation || []).length || payload.conversationComposer
        || payload.conversationUnavailable) {
      setupConversation(payload.conversation || []);
    }
    // PR overview: the review discussion list (spec: pr-review-discussion).
    if ((payload.discussion || []).length) {
      setupDiscussion(payload.discussion);
    }
  } else if (payload.mode === "diff") {
    var segments = payload.segments || [];
    if (!segments.length && !payload.allNew) {
      var note = document.createElement("p");
      note.className = "pm-empty-note";
      note.textContent = pmString("This file is empty on both sides of the diff.");
      content.append(note);
    }
    if (payload.allNew) {
      // A brand-new file: tinting every block green says nothing — one
      // note up top carries the fact, and the CSS drops the per-block
      // added styling (comments and suggestions still work as usual).
      content.classList.add("pm-all-new");
      var newNote = document.createElement("div");
      newNote.className = "pm-newfile-note";
      newNote.textContent = segments.length
        ? "New file — everything here is added by the pull request."
        : "This new file is empty.";
      content.append(newNote);
    }
    if (payload.layout === "split") {
      renderSplit(segments);
    } else {
      renderInline(segments);
    }
    appendOutdated();
    rewriteRemoteResources(content);
    rewriteAttachmentImages(content);
    setupHeadingAnchors(content);
    populateToc(reportOutline(content));
    enhance(content);
    renderMermaid();
  } else if (payload.mode === "source") {
    // Raw Markdown source ("Show Markdown Source" / Quick Look preference):
    // textContent assignment keeps hostile content inert by construction.
    var sourcePre = document.createElement("pre");
    sourcePre.className = "pm-source-view";
    var sourceCode = document.createElement("code");
    sourceCode.className = "language-markdown";
    sourceCode.textContent = payload.markdown || "";
    sourcePre.append(sourceCode);
    content.append(sourcePre);
    if (window.hljs) { try { hljs.highlightElement(sourceCode); } catch (e) {} }
  } else if (payload.mode === "patch") {
    renderPatch(payload.patch, payload.patchThreads);
  }

  if (document.documentElement.classList.contains("pm-line-numbers")) {
    setupLineNumbers();
  }
})();
