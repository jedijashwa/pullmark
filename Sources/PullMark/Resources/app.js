(function () {
  "use strict";

  var payload = window.__PAYLOAD__ || { mode: "document", markdown: "" };
  var content = document.getElementById("content");
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  if (typeof markedAlert === "function") {
    marked.use(markedAlert());
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

  // ---- Code + mermaid enhancement ----

  function enhance(root) {
    root.querySelectorAll("pre code.language-mermaid").forEach(function (el) {
      var div = document.createElement("div");
      div.className = "mermaid";
      div.dataset.source = el.textContent;
      div.textContent = el.textContent;
      el.closest("pre").replaceWith(div);
    });
    root.querySelectorAll("pre code").forEach(function (el) {
      try { hljs.highlightElement(el); } catch (e) { /* unknown language */ }
    });
  }

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

  // ---- Diff rendering ----

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
      if (thread.lineLabel) {
        var label = document.createElement("div");
        label.className = "pm-thread-line";
        label.textContent = thread.lineLabel;
        box.append(label);
      }
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
      oldDiv.innerHTML = render(seg.oldText);
      var newDiv = document.createElement("div");
      newDiv.className = "pm-new";
      newDiv.innerHTML = render(seg.text);
      wrap.append(oldDiv, newDiv);
    } else {
      wrap.className = "pm-block pm-" + seg.kind;
      var div = document.createElement("div");
      div.innerHTML = render(seg.text);
      wrap.append(div);
    }
    wrap.append(commentButton(seg));
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
        left.innerHTML = render(seg.text);
        right.innerHTML = render(seg.text);
      } else if (seg.kind === "added") {
        left.classList.add("pm-cell-empty");
        right.classList.add("pm-cell-added");
        right.innerHTML = render(seg.text);
      } else if (seg.kind === "removed") {
        left.classList.add("pm-cell-removed");
        left.innerHTML = render(seg.text);
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
          left.innerHTML = render(seg.oldText);
          right.innerHTML = render(seg.text);
        }
      }
      (seg.side === "LEFT" ? left : right).append(commentButton(seg));
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

  if (payload.mode === "document") {
    content.innerHTML = render(payload.markdown);
    rewriteLocalResources(content);
    enhance(content);
    renderMermaid();
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
    enhance(content);
    renderMermaid();
  } else if (payload.mode === "patch") {
    renderPatch(payload.patch);
  }
})();
