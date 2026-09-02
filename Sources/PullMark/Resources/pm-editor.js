// The rich editor (spec: rich-editor). Loaded after app.js only when the
// page carries payload.richEditor; mounts a ProseMirror view over the
// rendered document and saves through the bridge as Markdown.
//
// Minimal-diff saves (spec §3): the file arrives as blocks + the exact
// gaps between them. Each block parses on its own into editor nodes;
// its position range is mapped through every transaction; on save, a
// block whose content still equals the original emits its original
// source, byte for byte — only touched and new blocks are serialized.
(function () {
  "use strict";
  // app.js keeps its payload private; read the page's own copy.
  var payload = { mode: "document" };
  var payloadElement = document.getElementById("pm-payload");
  if (payloadElement) {
    try { payload = JSON.parse(payloadElement.textContent); } catch (e) { return; }
  }
  if (!window.PM || !payload.richEditor) { return; }
  var spec = payload.richEditor;
  var model = PM.model, state = PM.state, view = PM.view;
  var markdown = PM.markdown, tables = PM.tables, listCmds = PM.schemaList;
  var commands = PM.commands, inputrules = PM.inputrules;
  function pmString(key) {
    return (payload.strings && payload.strings[key]) || key;
  }
  var host = document.querySelector(".markdown-body") || document.body;
  function fail(error) {
    // An editor that can't mount says so in the page rather than
    // leaving a silent, uneditable document.
    var pre = document.createElement("pre");
    pre.className = "pm-raw";
    pre.textContent = "Rich editor failed to start: " + (error && error.stack || error);
    host.prepend(pre);
  }
  try {

  // ---------------------------------------------------------------------
  // Schema: prosemirror-markdown's nodes and marks, plus GFM tables, a raw
  // block (HTML, front matter — kept verbatim), a bullet character and a
  // task checkbox on list items.
  var base = markdown.schema.spec;
  var nodes = base.nodes;
  nodes = nodes.update("bullet_list", Object.assign({}, nodes.get("bullet_list"), {
    attrs: { tight: { default: false }, bullet: { default: "-" } },
  }));
  nodes = nodes.update("list_item", Object.assign({}, nodes.get("list_item"), {
    attrs: { checked: { default: null } },
    toDOM: function (node) {
      if (node.attrs.checked === null) { return ["li", 0]; }
      return ["li", { class: "task-list-item", "data-checked": node.attrs.checked ? "true" : "false" },
        ["input", { type: "checkbox", class: "task-list-item-checkbox", contenteditable: "false",
                    checked: node.attrs.checked ? "checked" : null }], ["div", { class: "pm-task-body" }, 0]];
    },
  }));
  nodes = nodes.addToEnd("raw_block", {
    content: "text*", marks: "", group: "block", code: true, defining: true,
    attrs: { kind: { default: "html" } },
    parseDOM: [{ tag: "pre.pm-raw", preserveWhitespace: "full" }],
    toDOM: function (node) { return ["pre", { class: "pm-raw", "data-kind": node.attrs.kind }, ["code", 0]]; },
  });
  nodes = nodes.append(tables.tableNodes({
    tableGroup: "block",
    cellContent: "inline*",
    cellAttributes: {
      align: {
        default: null,
        getFromDOM: function (dom) { return dom.style.textAlign || null; },
        setDOMAttr: function (value, attrs) { if (value) { attrs.style = "text-align:" + value; } },
      },
    },
  }));
  var schema = new model.Schema({ nodes: nodes, marks: base.marks });

  // ---------------------------------------------------------------------
  // Parser: markdown-it with tables and html on; block tokens map to the
  // schema above. Task boxes are recognized after parsing.
  var md = PM.MarkdownIt("commonmark", { html: true }).enable("table");
  var tokens = Object.assign({}, markdown.defaultMarkdownParser.tokens, {
    bullet_list: { block: "bullet_list", getAttrs: function (tok, toks, i) {
      return { tight: listIsTight(toks, i), bullet: tok.markup || "-" }; } },
    ordered_list: { block: "ordered_list", getAttrs: function (tok, toks, i) {
      return { order: +tok.attrGet("start") || 1, tight: listIsTight(toks, i) }; } },
    html_block: { block: "raw_block", noCloseToken: true, getAttrs: function () { return { kind: "html" }; } },
    table: { block: "table" },
    thead: { ignore: true },
    tbody: { ignore: true },
    tr: { block: "table_row" },
    th: { block: "table_header", getAttrs: cellAttrs },
    td: { block: "table_cell", getAttrs: cellAttrs },
  });
  function cellAttrs(tok) {
    var style = tok.attrGet("style") || "";
    var m = /text-align:\s*(left|center|right)/.exec(style);
    return { align: m ? m[1] : null };
  }
  function listIsTight(toks, i) {
    for (var j = i + 1; j < toks.length; j++) {
      if (toks[j].type !== "list_item_open") { return toks[j].hidden; }
    }
    return false;
  }
  var parser = new markdown.MarkdownParser(schema, md, tokens);

  function parseBlock(text, isFrontMatter) {
    if (isFrontMatter) {
      return [schema.nodes.raw_block.create({ kind: "frontmatter" }, text ? schema.text(text) : null)];
    }
    var doc;
    try { doc = parser.parse(text); } catch (e) { doc = null; }
    if (!doc || doc.childCount === 0) {
      // Whatever markdown-it dropped stays as raw source rather than vanishing.
      return [schema.nodes.raw_block.create({ kind: "html" }, text ? schema.text(text) : null)];
    }
    var out = [];
    doc.content.forEach(function (n) { out.push(taskify(n)); });
    return out;
  }
  // "[ ] " / "[x] " at the start of a list item's first paragraph.
  function taskify(node) {
    if (node.type.name === "list_item" && node.firstChild && node.firstChild.type.name === "paragraph"
        && node.firstChild.firstChild && node.firstChild.firstChild.isText) {
      var m = /^\[( |x|X)\] /.exec(node.firstChild.firstChild.text);
      if (m) {
        var para = node.firstChild;
        var first = para.firstChild;
        var rest = first.text.slice(m[0].length);
        var content = [];
        if (rest) { content.push(schema.text(rest, first.marks)); }
        para.content.forEach(function (c, _, idx) { if (idx > 0) { content.push(c); } });
        var newPara = para.type.create(para.attrs, model.Fragment.from(content));
        var children = [newPara];
        node.content.forEach(function (c, _, idx) { if (idx > 0) { children.push(c); } });
        return node.type.create({ checked: m[1] !== " " }, model.Fragment.from(children));
      }
    }
    if (node.childCount) {
      var mapped = [];
      node.content.forEach(function (c) { mapped.push(taskify(c)); });
      return node.copy(model.Fragment.from(mapped));
    }
    return node;
  }

  // ---------------------------------------------------------------------
  // Serializer: prosemirror-markdown's, plus tables (GFM pipes), raw
  // blocks verbatim, task boxes, the remembered bullet character.
  var baseNodes = markdown.defaultMarkdownSerializer.nodes;
  var serializerNodes = Object.assign({}, baseNodes, {
    bullet_list: function (st, node) {
      st.renderList(node, "  ", function () { return (node.attrs.bullet || "-") + " "; });
    },
    list_item: function (st, node) {
      if (node.attrs.checked !== null) { st.write(node.attrs.checked ? "[x] " : "[ ] "); }
      st.renderContent(node);
    },
    raw_block: function (st, node) {
      st.text(node.textContent, false);
      st.closeBlock(node);
    },
    table: function (st, node) {
      var rows = [];
      var aligns = [];
      node.forEach(function (row, _, rowIndex) {
        var cells = [];
        row.forEach(function (cell, __, cellIndex) {
          cells.push(inlineToMarkdown(cell).replace(/\|/g, "\\|").replace(/\n/g, " "));
          if (rowIndex === 0) { aligns[cellIndex] = cell.attrs.align; }
        });
        rows.push(cells);
      });
      var width = rows.reduce(function (w, r) { return Math.max(w, r.length); }, 0);
      function line(cells) {
        var padded = cells.slice();
        while (padded.length < width) { padded.push(""); }
        return "| " + padded.join(" | ") + " |";
      }
      var out = [line(rows[0] || [])];
      var sep = [];
      for (var c = 0; c < width; c++) {
        var a = aligns[c];
        sep.push(a === "center" ? ":---:" : a === "right" ? "---:" : a === "left" ? ":---" : "---");
      }
      out.push("| " + sep.join(" | ") + " |");
      for (var r = 1; r < rows.length; r++) { out.push(line(rows[r])); }
      st.write(out.join("\n"));
      st.closeBlock(node);
    },
  });
  var serializer = new markdown.MarkdownSerializer(serializerNodes, markdown.defaultMarkdownSerializer.marks);
  function inlineToMarkdown(cell) {
    var para = schema.nodes.paragraph.create(null, cell.content);
    return serializer.serialize(schema.nodes.doc.create(null, [para])).trim();
  }
  function serializeFragment(fragment) {
    return serializer.serialize(schema.nodes.doc.create(null, fragment)).replace(/\n+$/, "");
  }

  // ---------------------------------------------------------------------
  // The document: blocks → nodes, with each block's position range kept.
  var blocks = spec.blocks || [];
  var gaps = spec.gaps || { leading: "", between: [], trailing: "" };
  var originals = [];   // Fragment per block
  var ranges = [];      // {from, to} per block, mapped through transactions
  var allNodes = [];
  var pos = 0;
  blocks.forEach(function (b, i) {
    var parsed = parseBlock(b.text, i === 0 && spec.frontMatterLines > 0);
    var from = pos;
    parsed.forEach(function (n) { allNodes.push(n); pos += n.nodeSize; });
    ranges.push({ from: from, to: pos });
    originals.push(model.Fragment.from(parsed));
  });
  if (!allNodes.length) { allNodes.push(schema.nodes.paragraph.create()); }
  var doc = schema.nodes.doc.create(null, allNodes);

  // Rebuilds the file: original text for untouched blocks, serialized
  // Markdown for touched or new ones, original gaps where both neighbours
  // are original consecutive blocks, a blank line elsewhere.
  function assemble(currentDoc) {
    var groups = [];   // {block: index|null, nodes: [Node]}
    var index = 0;
    currentDoc.forEach(function (node, offset) {
      var end = offset + node.nodeSize;
      var owner = null;
      for (var i = 0; i < ranges.length; i++) {
        if (offset >= ranges[i].from && end <= ranges[i].to) { owner = i; break; }
      }
      var last = groups[groups.length - 1];
      if (last && last.block === owner && owner !== null) {
        last.nodes.push(node);
      } else if (last && last.block === null && owner === null) {
        last.nodes.push(node);
      } else {
        groups.push({ block: owner, nodes: [node] });
      }
      index++;
    });
    var parts = [];
    var prevBlock = null;
    groups.forEach(function (g, gi) {
      var text;
      if (g.block !== null && model.Fragment.from(g.nodes).eq(originals[g.block])) {
        text = blocks[g.block].text;
      } else {
        text = serializeFragment(model.Fragment.from(g.nodes));
      }
      if (gi > 0) {
        var gap = "\n\n";
        if (prevBlock !== null && g.block === prevBlock + 1 && gaps.between[prevBlock] !== undefined) {
          gap = gaps.between[prevBlock];
        }
        parts.push(gap);
      }
      parts.push(text);
      prevBlock = g.block;
    });
    var out = gaps.leading + parts.join("");
    if (groups.length && groups[groups.length - 1].block === blocks.length - 1) {
      out += gaps.trailing;
    } else if (gaps.trailing) {
      out += "\n";
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Commands and keys.
  function markActive(st, type) {
    var sel = st.selection;
    if (sel.empty) { return !!type.isInSet(st.storedMarks || sel.$from.marks()); }
    return st.doc.rangeHasMark(sel.from, sel.to, type);
  }
  function toggleLink(st, dispatch) {
    var link = schema.marks.link;
    if (markActive(st, link)) { return commands.toggleMark(link)(st, dispatch); }
    if (st.selection.empty) { return false; }
    var href = window.prompt(pmString("Link address"), "https://");
    if (!href) { return false; }
    return commands.toggleMark(link, { href: href })(st, dispatch);
  }
  function tableTab(dir) {
    return function (st, dispatch, v) {
      if (!tables.isInTable(st)) { return false; }
      if (tables.goToNextCell(dir)(st, dispatch)) { return true; }
      if (dir > 0) {
        tables.addRowAfter(st, dispatch);
        return tables.goToNextCell(1)(v.state, dispatch);
      }
      return true;
    };
  }
  function tableEnter(st, dispatch, v) {
    if (!tables.isInTable(st)) { return false; }
    tables.addRowAfter(st, dispatch);
    return tables.goToNextCell(1)(v.state, dispatch);
  }
  var pendingSave = null;
  function requestSave(immediate) {
    if (pendingSave) { clearTimeout(pendingSave); pendingSave = null; }
    if (immediate) { postSave(); return; }
    pendingSave = setTimeout(postSave, 600);
  }
  var lastSaved = null;
  function postSave() {
    pendingSave = null;
    var text = assemble(editorView.state.doc);
    if (text === lastSaved) { return; }
    lastSaved = text;
    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge
      && window.webkit.messageHandlers.bridge.postMessage({ type: "richEditorSave", text: text });
  }
  function saveCommand() { requestSave(true); return true; }

  var keys = {
    "Mod-z": PM.history.undo,
    "Shift-Mod-z": PM.history.redo,
    "Mod-y": PM.history.redo,
    "Mod-b": commands.toggleMark(schema.marks.strong),
    "Mod-i": commands.toggleMark(schema.marks.em),
    "Mod-`": commands.toggleMark(schema.marks.code),
    "Mod-k": toggleLink,
    "Mod-s": saveCommand,
    "Enter": commands.chainCommands(tableEnter, listCmds.splitListItem(schema.nodes.list_item),
                                    commands.newlineInCode, commands.createParagraphNear,
                                    commands.liftEmptyBlock, commands.splitBlock),
    "Tab": commands.chainCommands(tableTab(1), listCmds.sinkListItem(schema.nodes.list_item)),
    "Shift-Tab": commands.chainCommands(tableTab(-1), listCmds.liftListItem(schema.nodes.list_item)),
    "Mod-Enter": commands.exitCode,
    "Escape": function () { hideSlash(); hideToolbar(); return false; },
  };

  // Typed Markdown shortcuts (spec §5).
  function headingRule(level) {
    return inputrules.textblockTypeInputRule(new RegExp("^(#{" + level + "})\\s$"), schema.nodes.heading, { level: level });
  }
  var rules = [
    inputrules.wrappingInputRule(/^\s*>\s$/, schema.nodes.blockquote),
    inputrules.wrappingInputRule(/^(\d+)\.\s$/, schema.nodes.ordered_list,
      function (m) { return { order: +m[1] }; },
      function (m, node) { return node.childCount + node.attrs.order === +m[1]; }),
    inputrules.wrappingInputRule(/^\s*([-+*])\s$/, schema.nodes.bullet_list,
      function (m) { return { bullet: m[1] }; }),
    inputrules.wrappingInputRule(/^\s*[-*]\s\[( |x)\]\s$/, schema.nodes.bullet_list),
    inputrules.textblockTypeInputRule(/^```(\w*)\s$/, schema.nodes.code_block,
      function (m) { return { params: m[1] || "" }; }),
    headingRule(1), headingRule(2), headingRule(3), headingRule(4),
    markRule(/\*\*([^*]+)\*\*$/, schema.marks.strong),
    markRule(/(?:^|[^*])\*([^*\s][^*]*)\*$/, schema.marks.em),
    markRule(/`([^`]+)`$/, schema.marks.code),
    new inputrules.InputRule(/^\/$/, function (st, match, start, end) {
      showSlash(start, end);
      return null;
    }),
  ];
  function markRule(regexp, mark) {
    return new inputrules.InputRule(regexp, function (st, match, start, end) {
      var text = match[1];
      var lead = match[0].indexOf(text) - 1;   // the opening delimiter's offset
      if (lead < 0) { lead = 0; }
      return st.tr.replaceWith(start + lead, end, schema.text(text, [mark.create()]))
        .removeStoredMark(mark);
    });
  }

  // ---------------------------------------------------------------------
  // Floating toolbar on a text selection (spec §5).
  var toolbar = document.createElement("div");
  toolbar.className = "pm-float-toolbar";
  toolbar.hidden = true;
  var toolbarItems = [
    { label: "B", title: pmString("Bold"), cls: "pm-tb-bold", run: function () { return commands.toggleMark(schema.marks.strong); }, active: function (st) { return markActive(st, schema.marks.strong); } },
    { label: "I", title: pmString("Italic"), cls: "pm-tb-italic", run: function () { return commands.toggleMark(schema.marks.em); }, active: function (st) { return markActive(st, schema.marks.em); } },
    { label: "<>", title: pmString("Code"), cls: "pm-tb-code", run: function () { return commands.toggleMark(schema.marks.code); }, active: function (st) { return markActive(st, schema.marks.code); } },
    { label: "🔗", title: pmString("Link"), cls: "pm-tb-link", run: function () { return toggleLink; }, active: function (st) { return markActive(st, schema.marks.link); } },
    { label: "H1", title: pmString("Heading 1"), run: function () { return commands.setBlockType(schema.nodes.heading, { level: 1 }); } },
    { label: "H2", title: pmString("Heading 2"), run: function () { return commands.setBlockType(schema.nodes.heading, { level: 2 }); } },
    { label: "H3", title: pmString("Heading 3"), run: function () { return commands.setBlockType(schema.nodes.heading, { level: 3 }); } },
    { label: "¶", title: pmString("Paragraph"), run: function () { return commands.setBlockType(schema.nodes.paragraph); } },
  ];
  toolbarItems.forEach(function (item) {
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = item.label;
    b.title = item.title;
    if (item.cls) { b.className = item.cls; }
    b.addEventListener("mousedown", function (e) { e.preventDefault(); });
    b.addEventListener("click", function (e) {
      e.preventDefault();
      item.run()(editorView.state, editorView.dispatch, editorView);
      editorView.focus();
      updateToolbar();
    });
    item.button = b;
    toolbar.append(b);
  });
  document.body.append(toolbar);
  function hideToolbar() { toolbar.hidden = true; }
  function updateToolbar() {
    var st = editorView.state, sel = st.selection;
    if (sel.empty || !(sel instanceof state.TextSelection) || tables.isInTable(st) && sel.from === sel.to) {
      hideToolbar(); return;
    }
    var start = editorView.coordsAtPos(sel.from), end = editorView.coordsAtPos(sel.to);
    toolbar.hidden = false;
    toolbarItems.forEach(function (item) {
      if (item.active) { item.button.classList.toggle("is-active", item.active(st)); }
    });
    var left = Math.max(8, Math.min(start.left, end.left) + window.scrollX);
    var top = start.top + window.scrollY - toolbar.offsetHeight - 8;
    if (top < window.scrollY + 4) { top = end.bottom + window.scrollY + 8; }
    toolbar.style.left = left + "px";
    toolbar.style.top = top + "px";
  }

  // ---------------------------------------------------------------------
  // "/" insert menu on an empty line (spec §5).
  var slash = document.createElement("div");
  slash.className = "pm-slash-menu";
  slash.hidden = true;
  var slashRange = null;
  var slashIndex = 0;
  var slashItems = [
    { title: pmString("Heading 1"), run: function (tr) { return tr.setBlockType(tr.selection.from, tr.selection.from, schema.nodes.heading, { level: 1 }); } },
    { title: pmString("Heading 2"), run: function (tr) { return tr.setBlockType(tr.selection.from, tr.selection.from, schema.nodes.heading, { level: 2 }); } },
    { title: pmString("Heading 3"), run: function (tr) { return tr.setBlockType(tr.selection.from, tr.selection.from, schema.nodes.heading, { level: 3 }); } },
    { title: pmString("Bullet list"), insert: function () { return schema.nodes.bullet_list.create(null, [schema.nodes.list_item.create(null, [schema.nodes.paragraph.create()])]); } },
    { title: pmString("Numbered list"), insert: function () { return schema.nodes.ordered_list.create(null, [schema.nodes.list_item.create(null, [schema.nodes.paragraph.create()])]); } },
    { title: pmString("Task list"), insert: function () { return schema.nodes.bullet_list.create(null, [schema.nodes.list_item.create({ checked: false }, [schema.nodes.paragraph.create()])]); } },
    { title: pmString("Quote"), insert: function () { return schema.nodes.blockquote.create(null, [schema.nodes.paragraph.create()]); } },
    { title: pmString("Code block"), insert: function () { return schema.nodes.code_block.create(); } },
    { title: pmString("Table"), insert: function () { return makeTable(3, 2); } },
    { title: pmString("Divider"), insert: function () { return schema.nodes.horizontal_rule.create(); } },
  ];
  function makeTable(cols, rows) {
    var rowNodes = [];
    for (var r = 0; r < rows; r++) {
      var cells = [];
      for (var c = 0; c < cols; c++) {
        cells.push((r === 0 ? schema.nodes.table_header : schema.nodes.table_cell).create());
      }
      rowNodes.push(schema.nodes.table_row.create(null, cells));
    }
    return schema.nodes.table.create(null, rowNodes);
  }
  slashItems.forEach(function (item, i) {
    var row = document.createElement("div");
    row.className = "pm-slash-item";
    row.textContent = item.title;
    row.addEventListener("mousedown", function (e) { e.preventDefault(); });
    row.addEventListener("click", function () { slashIndex = i; runSlash(); });
    item.row = row;
    slash.append(row);
  });
  document.body.append(slash);
  function showSlash(start, end) {
    slashRange = { from: start, to: end };
    slashIndex = 0;
    renderSlash();
    var coords = editorView.coordsAtPos(end);
    slash.hidden = false;
    slash.style.left = (coords.left + window.scrollX) + "px";
    slash.style.top = (coords.bottom + window.scrollY + 6) + "px";
  }
  function hideSlash() { slash.hidden = true; slashRange = null; }
  function renderSlash() {
    slashItems.forEach(function (item, i) { item.row.classList.toggle("is-active", i === slashIndex); });
  }
  function runSlash() {
    if (!slashRange) { return; }
    var item = slashItems[slashIndex];
    var st = editorView.state;
    var tr = st.tr.delete(slashRange.from, slashRange.to + 1);
    if (item.insert) {
      var $pos = tr.doc.resolve(slashRange.from);
      var node = item.insert();
      // Replace the empty paragraph the slash lived in.
      var paraStart = $pos.before($pos.depth), paraEnd = $pos.after($pos.depth);
      tr = tr.replaceWith(paraStart, paraEnd, node);
      var inside = tr.doc.resolve(Math.min(paraStart + 1, tr.doc.content.size));
      var sel = state.Selection.near(inside, 1);
      tr = tr.setSelection(sel);
    } else {
      tr = item.run(tr);
    }
    hideSlash();
    editorView.dispatch(tr.scrollIntoView());
    editorView.focus();
  }
  function slashKey(event) {
    if (slash.hidden) { return false; }
    if (event.key === "ArrowDown") { slashIndex = (slashIndex + 1) % slashItems.length; renderSlash(); return true; }
    if (event.key === "ArrowUp") { slashIndex = (slashIndex + slashItems.length - 1) % slashItems.length; renderSlash(); return true; }
    if (event.key === "Enter") { runSlash(); return true; }
    if (event.key === "Escape") { hideSlash(); return true; }
    if (event.key === "Backspace") { hideSlash(); return false; }
    return false;
  }

  // ---------------------------------------------------------------------
  // Mount.
  host.innerHTML = "";
  host.classList.add("pm-rich-editing");
  var editorView = new view.EditorView(host, {
    state: state.EditorState.create({
      doc: doc,
      plugins: [
        inputrules.inputRules({ rules: rules }),
        PM.keymap.keymap(keys),
        PM.keymap.keymap(commands.baseKeymap),
        PM.history.history(),
        tables.tableEditing(),
      ],
    }),
    handleKeyDown: function (v, event) { return slashKey(event); },
    handleClickOn: function (v, p, node, nodePos, event) {
      // Task checkbox toggles without moving the caret into the text.
      if (event.target && event.target.classList && event.target.classList.contains("task-list-item-checkbox")) {
        var li = node.type.name === "list_item" ? node : null;
        var liPos = nodePos;
        if (!li) {
          var $p = v.state.doc.resolve(p);
          for (var d = $p.depth; d > 0; d--) {
            if ($p.node(d).type.name === "list_item") { li = $p.node(d); liPos = $p.before(d); break; }
          }
        }
        if (li) {
          v.dispatch(v.state.tr.setNodeMarkup(liPos, null, { checked: !li.attrs.checked }));
          return true;
        }
      }
      return false;
    },
    dispatchTransaction: function (tr) {
      var newState = editorView.state.apply(tr);
      editorView.updateState(newState);
      if (tr.docChanged) {
        ranges = ranges.map(function (r) {
          return { from: tr.mapping.map(r.from, -1), to: tr.mapping.map(r.to, 1) };
        });
        if (slashRange) { hideSlash(); }
        if (spec.autosave) { requestSave(false); }
      }
      updateToolbar();
    },
  });
  editorView.focus();

  // The bridge: Swift defers file reloads while this is true, and asks
  // for the text before flipping edit mode off.
  window.__pmRichEditorText = function () { return assemble(editorView.state.doc); };
  // The round-trip harness (scripts/editor-check.sh) drives edits through
  // this; nothing in the app reads it.
  window.__pmRichEditorView = editorView;
  window.__pmRichEditorFlush = function () { requestSave(true); };
  var previousCommit = window.__pmCommitNow;
  window.__pmCommitNow = function () { requestSave(true); if (previousCommit) { previousCommit(); } };
  window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge
    && window.webkit.messageHandlers.bridge.postMessage({ type: "editingState", active: true });
  window.addEventListener("scroll", function () { if (!toolbar.hidden) { updateToolbar(); } }, { passive: true });
  } catch (error) { fail(error); }
})();
