(function () {
  "use strict";

  var payload = window.__PAYLOAD__ || { mode: "document", markdown: "" };
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
      var div = document.createElement("div");
      div.className = "mermaid";
      div.dataset.source = el.textContent;
      div.textContent = el.textContent;
      el.closest("pre").replaceWith(div);
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
      var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
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

  // ---- Blame annotations (document mode) ----
  // Swift computes everything (relative dates, primary commit, extra
  // contributors); this only builds DOM. Avatars are remote https images in
  // a non-persistent web view; when no avatar URL exists (local-only blame)
  // a deterministic initials circle stands in.

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

  function blameStripEl(entry) {
    var strip = document.createElement("div");
    strip.className = "pm-blame";
    if (entry.headline) { strip.title = entry.headline; }

    var avatars = document.createElement("span");
    avatars.className = "pm-blame-avatars";
    avatars.append(blameAvatarEl(entry.author, entry.avatarUrl));
    (entry.others || []).forEach(function (other) {
      avatars.append(blameAvatarEl(other.name, other.avatarUrl));
    });
    strip.append(avatars);

    var author = document.createElement("span");
    author.className = "pm-blame-author";
    author.textContent = entry.uncommitted ? "Uncommitted changes" : (entry.author || "");
    strip.append(author);

    if (entry.dateLabel) {
      var date = document.createElement("span");
      date.className = "pm-blame-date";
      date.textContent = entry.dateLabel;
      strip.append(date);
    }

    if (entry.shortSHA && !entry.uncommitted) {
      var sha;
      if (entry.url) {
        sha = document.createElement("a");
        sha.href = entry.url; // opened externally by the navigation delegate
        sha.title = (entry.headline ? entry.headline + " — " : "") + "View commit on GitHub";
      } else {
        sha = document.createElement("button");
        sha.type = "button";
        sha.title = (entry.headline ? entry.headline + " — " : "") + "Copy full SHA";
        sha.addEventListener("click", function () {
          post({ type: "copySHA", sha: entry.sha });
          sha.textContent = "copied";
          setTimeout(function () { sha.textContent = entry.shortSHA; }, 900);
        });
      }
      sha.className = "pm-blame-sha";
      sha.textContent = entry.shortSHA;
      strip.append(sha);
    }
    return strip;
  }

  function blameNoteEl(text) {
    var note = document.createElement("div");
    note.className = "pm-blame-note";
    note.textContent = text;
    return note;
  }

  function renderBlameDocument(entries) {
    entries.forEach(function (entry) {
      var wrap = document.createElement("div");
      wrap.className = "pm-blame-block";
      var body = document.createElement("div");
      body.innerHTML = render(entry.text);
      wrap.append(body);
      if (entry.sha) { wrap.append(blameStripEl(entry)); }
      content.append(wrap);
    });
  }

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
    if (payload.blame && payload.blame.length) {
      renderBlameDocument(payload.blame);
    } else {
      content.innerHTML = render(payload.markdown);
    }
    if (payload.blameNote) { content.prepend(blameNoteEl(payload.blameNote)); }
    rewriteLocalResources(content);
    rewriteRemoteResources(content);
    setupHeadingAnchors(content);
    reportOutline(content);
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
    rewriteRemoteResources(content);
    setupHeadingAnchors(content);
    reportOutline(content);
    enhance(content);
    renderMermaid();
  } else if (payload.mode === "patch") {
    renderPatch(payload.patch);
  }
})();
