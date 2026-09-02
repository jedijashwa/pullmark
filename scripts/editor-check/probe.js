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
    if (!v || !window.__pmRichEditorText) { out.error = "editor not mounted"; report(); return; }
    var fixture = window.__pmFixture;
    var untouched = window.__pmRichEditorText();
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
    out.ok = out.untouchedIdentical && (!target || out.editedChangedLines === 1);
  } catch (e) { out.error = String(e && e.stack || e); }
  report();
})();
