// Drives the mounted editor: untouched round trip, then a scripted
// one-word edit, and reports both into #out for the harness to read.
(function () {
  var out = { ok: false };
  function report() {
    var el = document.getElementById("out") || document.body.appendChild(document.createElement("pre"));
    el.id = "out"; el.textContent = JSON.stringify(out);
  }
  try {
    var v = window.__pmRichEditorView;
    if (!v || !window.__pmRichEditorText) {
      var raw = document.querySelector("pre.pm-raw");
      out.error = "editor not mounted" + (raw ? ": " + raw.textContent.slice(0, 400) : "");
      report(); return;
    }
    var fixture = window.__pmFixture;
    var untouched = window.__pmRichEditorText();
    out.noteCards = document.querySelectorAll(".ProseMirror .pm-note").length;
    out.rawBlocks = document.querySelectorAll(".ProseMirror pre.pm-raw").length;
    var owners = [];
    v.state.doc.descendants(function (node) {
      if (node.attrs && node.attrs.notes && node.attrs.notes.length) {
        owners.push(node.type.name + ":" + node.attrs.notes.map(function (n) { return (n.before ? "^" : "") + n.body.slice(0, 12); }).join("|"));
      }
      return true;
    });
    out.noteOwners = owners;
    out.callouts = document.querySelectorAll(".ProseMirror .markdown-alert").length;
    out.footnoteRefs = document.querySelectorAll(".ProseMirror .pm-footnote-ref").length;
    out.footnoteDefs = document.querySelectorAll(".ProseMirror .pm-footnote-def").length;
    // Spreadsheet paste into the first table's second body cell: the
    // table grows to fit and the pasted cells land in place.
    var table = null, tablePos = null;
    v.state.doc.forEach(function (node, offset) { if (!table && node.type.name === "table") { table = node; tablePos = offset; } });
    if (table && window.__pmRichEditorPasteText && (window.__pmExpect || {}).pastedOK !== undefined) {
      var map = window.PM.tables.TableMap.get(table);
      var cell = tablePos + 1 + map.map[1 * map.width + 1];   // row 1, col 1
      v.dispatch(v.state.tr.setSelection(window.PM.state.TextSelection.create(v.state.doc, cell + 2)));
      window.__pmRichEditorPasteText("7\tM5\tnew\n9\tM6\tnewer\n11\tM8\tnewest");
      var pasted = window.__pmRichEditorText();
      out.pastedOK = pasted.indexOf("| Bolt | 7 | M5 | new |") >= 0 && pasted.indexOf("|  | 11 | M8 | newest |") >= 0
        && pasted.split("\n").filter(function (l) { return l.indexOf("|") === 0; }).length === 5;
      if (!out.pastedOK) { out.pasted = pasted; }
      window.PM.history.undo(v.state, v.dispatch);
    }
    // Hover affordance: a mousemove over the first paragraph must show the bubble.
    var firstPara = document.querySelector(".ProseMirror > p");
    if (firstPara) {
      var r = firstPara.getBoundingClientRect();
      firstPara.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: r.left + 10, clientY: r.top + 5 }));
      var tools = document.querySelector(".pm-affordance-layer .pm-result-tools");
      out.bubbleShown = !!tools && tools.style.display !== "none";
      out.bubbleStyle = tools ? (tools.style.left + "," + tools.style.top) : "none";
      if (tools) {
        var cs = getComputedStyle(tools), br = tools.getBoundingClientRect();
        out.bubbleComputed = cs.display + "/" + cs.visibility + "/" + cs.opacity + "/" + Math.round(br.width) + "x" + Math.round(br.height) + "@" + Math.round(br.left) + "," + Math.round(br.top);
        var btn = tools.querySelector("button"); var bs = btn ? getComputedStyle(btn) : null;
        out.buttonComputed = bs ? bs.display + "/" + bs.visibility + "/" + bs.opacity + "/" + bs.width : "none";
      }
    }
    out.untouchedIdentical = untouched === fixture;
    if (!out.untouchedIdentical) { out.untouched = untouched; }
    // Edit: replace the first occurrence of the marker word, if present.
    var marker = window.__pmEditWord;
    var target = null;
    v.state.doc.descendants(function (node, pos) {
      if (target === null && node.isText && node.text.indexOf(marker) >= 0) {
        target = { pos: pos + node.text.indexOf(marker), len: marker.length };
      }
    });
    if (target) {
      v.dispatch(v.state.tr.insertText("EDITED", target.pos, target.pos + target.len));
      var edited = window.__pmRichEditorText();
      var a = fixture.split("\n"), b = edited.split("\n");
      var changed = 0;
      for (var i = 0; i < Math.max(a.length, b.length); i++) { if (a[i] !== b[i]) { changed++; } }
      out.editedChangedLines = changed;
      out.editedContainsWord = edited.indexOf("EDITED") >= 0;
      if (changed !== 1) { out.edited = edited; }
    }
    // Margin-note composer: open on the second block, type, submit — the
    // note lands after that block in the saved text; delete removes it.
    var beforeNote = window.__pmRichEditorText();
    if (window.__pmRichEditorOpenNoteComposer && window.__pmRichEditorOpenNoteComposer(1)) {
      var ta = document.querySelector(".ProseMirror .pm-note-composer textarea");
      var primary = document.querySelector(".ProseMirror .pm-note-composer .pm-composer-primary");
      if (ta && primary) {
        ta.value = "Composer note body";
        ta.dispatchEvent(new Event("input", { bubbles: true }));
        primary.click();
        var withNote = window.__pmRichEditorText();
        out.composerAdded = withNote.indexOf("<!-- note @tester: Composer note body -->") >= 0;
        var addedLines = withNote.split("\n").length - beforeNote.split("\n").length;
        out.composerAddedLines = addedLines;
        var card = Array.prototype.find.call(document.querySelectorAll(".ProseMirror .pm-note"), function (c) {
          return c.textContent.indexOf("Composer note body") >= 0; });
        var del = card && card.querySelector(".pm-note-actions button:last-child");
        if (del) { del.click(); }
        out.composerDeletedRoundTrip = window.__pmRichEditorText() === beforeNote;
        if (!out.composerAdded || !out.composerDeletedRoundTrip) { out.withNote = withNote.slice(0, 600); }
      } else { out.composerAdded = false; }
    }
    // Escape hatch: the second block edited as Markdown becomes a raw
    // island holding its own source, and rendering it again restores the
    // document exactly.
    if (window.__pmRichEditorEditAsMarkdown) {
      var beforeHatch = window.__pmRichEditorText();
      var second = null, secondPos = null, n = 0;
      v.state.doc.forEach(function (node, offset) { if (n === 1 && second === null) { second = node; secondPos = offset; } n++; });
      if (second && second.type.name !== "raw_block") {
        v.dispatch(v.state.tr.setSelection(window.PM.state.Selection.near(v.state.doc.resolve(secondPos + 1))));
        out.hatchEdited = window.__pmRichEditorEditAsMarkdown();
        out.hatchRaw = document.querySelectorAll('.ProseMirror pre.pm-raw[data-kind="markdown"]').length === 1;
        out.hatchTextKept = window.__pmRichEditorText() === beforeHatch;
        out.hatchRendered = window.__pmRichEditorRenderMarkdown();
        out.hatchRoundTrip = window.__pmRichEditorText() === beforeHatch;
        if (!out.hatchRoundTrip) { out.hatchAfter = window.__pmRichEditorText().slice(0, 500); }
      }
    }
    var expect = window.__pmExpect || {};
    out.expectOK = Object.keys(expect).every(function (k) { return out[k] === expect[k]; });
    if (!out.expectOK) { out.expected = expect; }
    out.ok = out.untouchedIdentical && (!target || out.editedChangedLines === 1) && out.expectOK
      && out.composerAdded !== false && out.composerDeletedRoundTrip !== false
      && out.hatchRaw !== false && out.hatchRoundTrip !== false;
  } catch (e) { out.error = String(e && e.stack || e); }
  report();
})();
