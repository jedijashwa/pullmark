(function () {
  "use strict";

  var payload = window.__PAYLOAD__ || { mode: "document", markdown: "" };
  var content = document.getElementById("content");
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  if (typeof markedAlert === "function") {
    marked.use(markedAlert());
  }
  marked.use({ gfm: true });

  function post(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
      window.webkit.messageHandlers.bridge.postMessage(message);
    }
  }

  function render(markdown) {
    return marked.parse(markdown || "");
  }

  // Convert mermaid code fences into mermaid containers (keeping the source
  // around for theme re-renders) and syntax-highlight everything else.
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

  function segmentElement(seg) {
    var wrap = document.createElement("div");
    wrap.className = "pm-block pm-" + seg.kind;
    if (seg.kind === "modified") {
      var oldDiv = document.createElement("div");
      oldDiv.className = "pm-old";
      oldDiv.innerHTML = render(seg.oldText);
      var newDiv = document.createElement("div");
      newDiv.className = "pm-new";
      newDiv.innerHTML = render(seg.text);
      wrap.append(oldDiv, newDiv);
    } else {
      var div = document.createElement("div");
      div.innerHTML = render(seg.text);
      wrap.append(div);
    }
    var btn = document.createElement("button");
    btn.className = "pm-comment-btn";
    btn.type = "button";
    btn.textContent = "💬";
    btn.title = "Comment on " + (seg.side === "LEFT" ? "old" : "new") +
      " lines " + seg.lineStart + "–" + seg.lineEnd;
    btn.addEventListener("click", function (event) {
      event.stopPropagation();
      post({ type: "comment", lineStart: seg.lineStart, lineEnd: seg.lineEnd, side: seg.side });
    });
    wrap.append(btn);
    return wrap;
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

  if (payload.mode === "document") {
    content.innerHTML = render(payload.markdown);
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
    segments.forEach(function (seg) {
      content.append(segmentElement(seg));
    });
    enhance(content);
    renderMermaid();
  } else if (payload.mode === "patch") {
    renderPatch(payload.patch);
  }
})();
