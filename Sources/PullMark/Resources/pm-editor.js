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
  // Callouts (spec §8): a quote whose first line is [!NOTE] & co. keeps
  // that as `kind`; the DOM matches the renderer's markdown-alert box.
  var CALLOUT_KINDS = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"];
  nodes = nodes.update("blockquote", Object.assign({}, nodes.get("blockquote"), {
    attrs: { kind: { default: null } },
    parseDOM: [
      { tag: "div.markdown-alert", contentElement: ".pm-alert-body",
        getAttrs: function (dom) { return { kind: dom.getAttribute("data-kind") }; } },
      { tag: "blockquote" },
    ],
    toDOM: function (node) {
      if (!node.attrs.kind) { return ["blockquote", 0]; }
      var kind = node.attrs.kind;
      return ["div", { class: "markdown-alert markdown-alert-" + kind.toLowerCase(), "data-kind": kind },
        ["p", { class: "markdown-alert-title", contenteditable: "false" }, calloutTitle(kind)],
        ["div", { class: "pm-alert-body" }, 0]];
    },
  }));
  function calloutTitle(kind) {
    return pmString({ NOTE: "Note", TIP: "Tip", IMPORTANT: "Important", WARNING: "Warning", CAUTION: "Caution" }[kind] || kind);
  }
  // Relative image paths display through the same local scheme the
  // renderer uses; the Markdown keeps the relative path.
  var ABSOLUTE_URL = /^([a-z][a-z0-9+.\-]*:|\/\/|#)/i;
  function displaySrc(src) {
    if (!payload.localResources || !src || ABSOLUTE_URL.test(src)) { return src; }
    return "pullmark-local:///" + src.replace(/^\//, "").split("/").map(function (seg) {
      return encodeURIComponent(decodeURIComponent(seg)); }).join("/");
  }
  var imageSpec = nodes.get("image");
  nodes = nodes.update("image", Object.assign({}, imageSpec, {
    parseDOM: [{ tag: "img[src]", getAttrs: function (dom) {
      return { src: dom.getAttribute("data-src") || dom.getAttribute("src"), title: dom.getAttribute("title"),
               alt: dom.getAttribute("alt") }; } }],
    toDOM: function (node) {
      return ["img", { src: displaySrc(node.attrs.src), "data-src": node.attrs.src,
                       alt: node.attrs.alt || "", title: node.attrs.title || null }];
    },
  }));
  nodes = nodes.addToEnd("footnote_ref", {
    inline: true, group: "inline", atom: true, selectable: true,
    attrs: { label: { default: "1" } },
    parseDOM: [{ tag: "sup.pm-footnote-ref", getAttrs: function (dom) { return { label: dom.getAttribute("data-label") || "1" }; } }],
    toDOM: function (node) { return ["sup", { class: "pm-footnote-ref", "data-label": node.attrs.label }, "[" + node.attrs.label + "]"]; },
  });
  nodes = nodes.addToEnd("footnote_def", {
    content: "inline*", group: "block", defining: true,
    attrs: { label: { default: "1" } },
    parseDOM: [{ tag: "div.pm-footnote-def", contentElement: "p",
                 getAttrs: function (dom) { return { label: dom.getAttribute("data-label") || "1" }; } }],
    toDOM: function (node) {
      return ["div", { class: "pm-footnote-def", "data-label": node.attrs.label },
        ["span", { class: "pm-footnote-label", contenteditable: "false" }, "[" + node.attrs.label + "]:"], ["p", 0]];
    },
  });
  nodes = nodes.update("list_item", Object.assign({}, nodes.get("list_item"), {
    attrs: { checked: { default: null } },
    toDOM: function (node) {
      if (node.attrs.checked === null) { return ["li", 0]; }
      return ["li", { class: "task-list-item", "data-checked": node.attrs.checked ? "true" : "false" },
        ["input", { type: "checkbox", class: "task-list-item-checkbox", contenteditable: "false",
                    checked: node.attrs.checked ? "checked" : null }], ["div", { class: "pm-task-body" }, 0]];
    },
  }));
  // A source line break inside a paragraph. Kept as a node (not a "\n"
  // in the text, which the DOM would re-read as a space) so an edited
  // paragraph keeps the author's hard wrapping — the diff stays one line.
  nodes = nodes.addToEnd("soft_break", {
    inline: true, group: "inline", selectable: false,
    parseDOM: [{ tag: "span.pm-soft" }],
    toDOM: function () { return ["span", { class: "pm-soft" }, " "]; },
  });
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
  // Margin notes (spec §6) ride on the block they follow as a `notes`
  // attribute — deleting the block deletes its notes, undo restores
  // both, and a moved block takes its notes along. Each entry:
  // { author, attrs, body, before, source } — `source` is the untouched
  // comment text (re-emitted verbatim), null once the note is edited.
  var NOTE_BEARING = ["paragraph", "heading", "blockquote", "horizontal_rule", "code_block",
                      "ordered_list", "bullet_list", "list_item", "raw_block", "table", "footnote_def"];
  NOTE_BEARING.forEach(function (name) {
    var current = nodes.get(name);
    nodes = nodes.update(name, Object.assign({}, current, {
      attrs: Object.assign({}, current.attrs || {}, { notes: { default: [] } }),
    }));
  });
  var schema = new model.Schema({ nodes: nodes, marks: base.marks });
  function bearsNotes(node) { return !!(node && node.type.spec.attrs && node.type.spec.attrs.notes); }
  function withNotes(node, notes) {
    return node.type.create(Object.assign({}, node.attrs, { notes: notes }), node.content, node.marks);
  }

  // ---------------------------------------------------------------------
  // Parser: markdown-it with tables and html on; block tokens map to the
  // schema above. Task boxes are recognized after parsing.
  var md = PM.MarkdownIt("commonmark", { html: true }).enable("table");
  // [^label] — a footnote reference (markdown-it core has no footnotes).
  md.inline.ruler.before("link", "pm_footnote_ref", function (st, silent) {
    var src = st.src, pos = st.pos;
    if (src.charCodeAt(pos) !== 0x5B || src.charCodeAt(pos + 1) !== 0x5E) { return false; }
    var end = src.indexOf("]", pos + 2);
    if (end < 0 || end === pos + 2) { return false; }
    var label = src.slice(pos + 2, end);
    if (/[\s\[\]]/.test(label)) { return false; }
    if (!silent) {
      var token = st.push("footnote_ref", "", 0);
      token.meta = { label: label };
    }
    st.pos = end + 1;
    return true;
  });
  var tokens = Object.assign({}, markdown.defaultMarkdownParser.tokens, {
    bullet_list: { block: "bullet_list", getAttrs: function (tok, toks, i) {
      return { tight: listIsTight(toks, i), bullet: tok.markup || "-" }; } },
    ordered_list: { block: "ordered_list", getAttrs: function (tok, toks, i) {
      return { order: +tok.attrGet("start") || 1, tight: listIsTight(toks, i) }; } },
    html_block: { block: "raw_block", noCloseToken: true, getAttrs: function () { return { kind: "html" }; } },
    softbreak: { node: "soft_break" },
    footnote_ref: { node: "footnote_ref", getAttrs: function (tok) { return { label: tok.meta.label }; } },
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
    var trimmed = text.trim();
    if (trimmed.length > 4 && trimmed.slice(0, 2) === "$$" && trimmed.slice(-2) === "$$") {
      return [schema.nodes.raw_block.create({ kind: "math" }, schema.text(text))];
    }
    var doc;
    try { doc = parser.parse(text); } catch (e) { doc = null; }
    if (!doc || doc.childCount === 0) {
      // Whatever markdown-it dropped stays as raw source rather than vanishing.
      return [schema.nodes.raw_block.create({ kind: "html" }, text ? schema.text(text) : null)];
    }
    var out = [];
    doc.content.forEach(function (n) {
      footnoteDefs(calloutize(taskify(n))).forEach(function (piece) { out.push(piece); });
    });
    return out;
  }
  // "> [!NOTE]" as the quote's first line → a callout of that kind.
  function calloutize(node) {
    if (node.type.name !== "blockquote" || !node.firstChild || node.firstChild.type.name !== "paragraph") { return node; }
    var para = node.firstChild;
    var first = para.firstChild;
    if (!first || !first.isText) { return node; }
    var m = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i.exec(first.text);
    if (!m) { return node; }
    var kind = m[1].toUpperCase();
    var rest = [];
    para.content.forEach(function (c, _, idx) { if (idx > 0) { rest.push(c); } });
    if (rest.length && rest[0].type.name === "soft_break") { rest.shift(); }
    var children = [];
    if (rest.length) { children.push(para.type.create(para.attrs, model.Fragment.from(rest))); }
    node.content.forEach(function (c, _, idx) { if (idx > 0) { children.push(c); } });
    if (!children.length) { children.push(schema.nodes.paragraph.create()); }
    return node.type.create(Object.assign({}, node.attrs, { kind: kind }), model.Fragment.from(children));
  }
  // "[^label]: text" lines → footnote definition blocks. Consecutive
  // definitions arrive as one paragraph with soft breaks between them,
  // so the paragraph splits wherever a line starts with a reference.
  function footnoteDefs(node) {
    if (node.type.name !== "paragraph" || !node.firstChild || node.firstChild.type.name !== "footnote_ref") { return [node]; }
    var second = node.maybeChild(1);
    if (!second || !second.isText || !/^:\s/.test(second.text)) { return [node]; }
    var lines = [[]];
    node.content.forEach(function (c) {
      if (c.type.name === "soft_break") { lines.push([]); } else { lines[lines.length - 1].push(c); }
    });
    var defs = [];
    var current = null;
    function startsDefinition(line) {
      return line.length >= 2 && line[0].type.name === "footnote_ref" && line[1].isText && /^:\s/.test(line[1].text);
    }
    lines.forEach(function (line) {
      if (startsDefinition(line)) {
        var content = [];
        var rest = line[1].text.replace(/^:\s+/, "");
        if (rest) { content.push(schema.text(rest, line[1].marks)); }
        content = content.concat(line.slice(2));
        current = { label: line[0].attrs.label, content: content };
        defs.push(current);
      } else if (current) {
        current.content.push(schema.nodes.soft_break.create());
        current.content = current.content.concat(line);
      }
    });
    return defs.map(function (def, i) {
      return schema.nodes.footnote_def.create({ label: def.label, notes: i === 0 ? node.attrs.notes : [] },
                                              model.Fragment.from(def.content));
    });
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

  // The note grammar (Core/MarginNotes.swift is the authority):
  //   <!-- note @author: body -->   or   <!-- note @author (attrs):\nbody\n-->
  var NOTE_OPEN = /^\s*<!--\s*note\s+@/;
  function unescapeNote(body) { return body.replace(/--\\>/g, "-->"); }
  function escapeNote(body) { return body.replace(/-->/g, "--\\>"); }
  function parseNote(text) {
    var lines = text.split("\n");
    if (!NOTE_OPEN.test(lines[0])) { return null; }
    var first = lines[0];
    var at = first.indexOf("@");
    var colon = first.indexOf(":", at);
    if (at < 0 || colon < 0) { return null; }
    var header = first.slice(at + 1, colon).trim();
    var rest = first.slice(colon + 1);
    var m = /^(.*?)\s*\(([^)]*)\)$/.exec(header);
    var author = (m ? m[1] : header).trim();
    var attrs = m ? m[2] : null;
    if (!author) { return null; }
    var close = rest.indexOf("-->");
    if (close >= 0) {
      return { author: author, attrs: attrs, body: unescapeNote(rest.slice(0, close).trim()),
               before: false, source: text };
    }
    var indent = /^ */.exec(first)[0].length;
    function dedent(line) {
      var strip = indent;
      while (strip > 0 && line.charAt(0) === " ") { line = line.slice(1); strip--; }
      return line;
    }
    var body = [];
    if (rest.trim()) { body.push(rest); }
    var closed = false;
    for (var j = 1; j < lines.length; j++) {
      var c = lines[j].indexOf("-->");
      if (c >= 0) {
        var head = dedent(lines[j].slice(0, c));
        if (head.trim()) { body.push(head); }
        closed = true;
        break;
      }
      body.push(dedent(lines[j]));
    }
    if (!closed) { return null; }
    while (body.length && !body[0].trim()) { body.shift(); }
    while (body.length && !body[body.length - 1].trim()) { body.pop(); }
    return { author: author, attrs: attrs, body: unescapeNote(body.join("\n")), before: false, source: text };
  }
  function noteText(note) {
    if (note.source != null) { return note.source; }
    var escaped = escapeNote(note.body);
    var attrs = note.attrs ? " (" + note.attrs + ")" : "";
    if (escaped.indexOf("\n") < 0) { return "<!-- note @" + note.author + attrs + ": " + escaped + " -->"; }
    return "<!-- note @" + note.author + attrs + ":\n" + escaped + "\n-->";
  }
  function noteFromRaw(node) {
    if (node.type.name !== "raw_block" || node.attrs.kind !== "html") { return null; }
    return parseNote(node.textContent);
  }
  // Folds note comments among `siblings` into the preceding sibling's
  // notes (recursing into lists and quotes). Notes with nothing before
  // them come back as `orphans` for the caller to place.
  function absorbNotes(siblings) {
    var out = [];
    var orphans = [];
    siblings.forEach(function (n) {
      var note = noteFromRaw(n);
      if (note) {
        var prev = out.length ? out[out.length - 1] : null;
        if (prev && bearsNotes(prev)) { out[out.length - 1] = withNotes(prev, prev.attrs.notes.concat([note])); }
        else { orphans.push(note); }
        return;
      }
      if (n.type.name === "list_item" || n.type.name === "blockquote"
          || n.type.name === "bullet_list" || n.type.name === "ordered_list") {
        var kids = [];
        n.forEach(function (c) { kids.push(c); });
        var inner = absorbNotes(kids);
        // A note with nothing before it inside a container attaches to the
        // container's first child (before it) or stays raw.
        if (inner.orphans.length) {
          var firstKid = inner.nodes[0];
          if (firstKid && bearsNotes(firstKid)) {
            inner.nodes[0] = withNotes(firstKid, inner.orphans.map(function (o) {
              return Object.assign({}, o, { before: true }); }).concat(firstKid.attrs.notes));
          } else {
            inner.orphans.forEach(function (o) {
              inner.nodes.unshift(schema.nodes.raw_block.create({ kind: "html" }, schema.text(o.source))); });
          }
        }
        n = n.copy(model.Fragment.from(inner.nodes));
      }
      out.push(n);
    });
    return { nodes: out, orphans: orphans };
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
    soft_break: function (st) {
      st.write("\n");
    },
    blockquote: function (st, node) {
      st.wrapBlock("> ", null, node, function () {
        if (node.attrs.kind) { st.write("[!" + node.attrs.kind + "]"); st.ensureNewLine(); }
        st.renderContent(node);
      });
    },
    footnote_ref: function (st, node) {
      st.write("[^" + node.attrs.label + "]");
    },
    footnote_def: function (st, node, parent, index) {
      var previous = index > 0 ? parent.child(index - 1) : null;
      if (previous && previous.type === node.type) { st.flushClose(1); }
      st.write("[^" + node.attrs.label + "]: ");
      st.renderInline(node);
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
  // Every note-bearing block writes its notes: `before` ones ahead of it,
  // the rest after — packed tight inside a list item (a blank line would
  // flip the list loose), blank-line separated elsewhere.
  function writeNote(st, note, tight) {
    if (tight) { st.flushClose(1); }
    st.text(noteText(note), false);
  }
  NOTE_BEARING.forEach(function (name) {
    var inner = serializerNodes[name];
    if (!inner) { return; }
    serializerNodes[name] = function (st, node, parent, index) {
      var notes = node.attrs.notes || [];
      notes.forEach(function (note) {
        if (note.before) { writeNote(st, note, false); st.closeBlock(node); }
      });
      inner(st, node, parent, index);
      var after = notes.filter(function (note) { return !note.before; });
      if (!after.length) { return; }
      // Inside a list item — the item itself or a block within it — notes
      // pack tight; a blank line would flip the list loose.
      var tight = name === "list_item" || (parent && parent.type.name === "list_item");
      after.forEach(function (note) {
        writeNote(st, note, tight);
        if (tight) { st.ensureNewLine(); } else { st.closeBlock(node); }
      });
    };
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
  var blocks = (spec.blocks || []).map(function (b) { return { text: b.text, start: b.start, end: b.end }; });
  var gaps = spec.gaps || { leading: "", between: [], trailing: "" };
  gaps = { leading: gaps.leading, between: gaps.between.slice(), trailing: gaps.trailing };
  var parsedBlocks = blocks.map(function (b, i) {
    return absorbNotes(parseBlock(b.text, i === 0 && spec.frontMatterLines > 0));
  });
  // A block that is nothing but notes joins the block before it (or,
  // at the top of the file, the one after — a file-level note) so the
  // pair is one range: untouched together, written back together.
  function mergeBlocks(keep, drop, notes, before) {
    var target = parsedBlocks[keep].nodes;
    var which = before ? 0 : target.length - 1;
    var mapped = notes.map(function (n) { return Object.assign({}, n, { before: before }); });
    target[which] = withNotes(target[which], before ? mapped.concat(target[which].attrs.notes)
                                                    : target[which].attrs.notes.concat(mapped));
    var lo = Math.min(keep, drop), hi = Math.max(keep, drop);
    blocks[lo] = { text: blocks[lo].text + gaps.between[lo] + blocks[hi].text,
                   start: blocks[lo].start, end: blocks[hi].end };
    blocks.splice(hi, 1);
    parsedBlocks.splice(hi, 1);
    gaps.between.splice(lo, 1);
  }
  for (var bi = 0; bi < parsedBlocks.length; bi++) {
    var pb = parsedBlocks[bi];
    if (!pb.orphans.length) { continue; }
    if (pb.nodes.length && bearsNotes(pb.nodes[0])) {
      pb.nodes[0] = withNotes(pb.nodes[0], pb.orphans.map(function (o) {
        return Object.assign({}, o, { before: true }); }).concat(pb.nodes[0].attrs.notes));
      pb.orphans = [];
      continue;
    }
    if (pb.nodes.length) {
      pb.orphans.forEach(function (o) {
        pb.nodes.unshift(schema.nodes.raw_block.create({ kind: "html" }, schema.text(o.source))); });
      pb.orphans = [];
      continue;
    }
    var prevNodes = bi > 0 ? parsedBlocks[bi - 1].nodes : [];
    var nextNodes = bi + 1 < parsedBlocks.length ? parsedBlocks[bi + 1].nodes : [];
    if (prevNodes.length && bearsNotes(prevNodes[prevNodes.length - 1])) {
      var notes = pb.orphans;
      pb.orphans = [];
      mergeBlocks(bi - 1, bi, notes, false);
      bi--;
    } else if (nextNodes.length && bearsNotes(nextNodes[0])) {
      var ahead = pb.orphans;
      pb.orphans = [];
      parsedBlocks[bi] = parsedBlocks[bi + 1];
      parsedBlocks.splice(bi + 1, 1);
      var joined = blocks[bi].text + gaps.between[bi] + blocks[bi + 1].text;
      blocks[bi] = { text: joined, start: blocks[bi].start, end: blocks[bi + 1].end };
      blocks.splice(bi + 1, 1);
      gaps.between.splice(bi, 1);
      var head = parsedBlocks[bi].nodes[0];
      parsedBlocks[bi].nodes[0] = withNotes(head, ahead.map(function (o) {
        return Object.assign({}, o, { before: true }); }).concat(head.attrs.notes));
      bi--;
    } else {
      // Nothing to hang them on: the notes stay as raw comment blocks.
      pb.orphans.forEach(function (o) {
        pb.nodes.push(schema.nodes.raw_block.create({ kind: "html" }, schema.text(o.source))); });
      pb.orphans = [];
    }
  }
  var originals = [];   // Fragment per block
  var ranges = [];      // {from, to} per block, mapped through transactions
  var allNodes = [];
  var pos = 0;
  parsedBlocks.forEach(function (pb) {
    var from = pos;
    pb.nodes.forEach(function (n) { allNodes.push(n); pos += n.nodeSize; });
    ranges.push({ from: from, to: pos });
    originals.push(model.Fragment.from(pb.nodes));
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
  // A small inline prompt (the page has no window.prompt): one field,
  // Return confirms, Escape cancels.
  var prompt = document.createElement("div");
  prompt.className = "pm-prompt pm-slash-menu";
  prompt.hidden = true;
  var promptLabel = document.createElement("div");
  promptLabel.className = "pm-prompt-label";
  var promptInput = document.createElement("input");
  promptInput.type = "text";
  promptInput.className = "pm-prompt-input";
  prompt.append(promptLabel, promptInput);
  document.body.append(prompt);
  var promptDone = null;
  function askText(label, initial, coords, done) {
    promptLabel.textContent = label;
    promptInput.value = initial || "";
    promptDone = done;
    prompt.hidden = false;
    prompt.style.left = (coords.left + window.scrollX) + "px";
    prompt.style.top = (coords.bottom + window.scrollY + 6) + "px";
    setTimeout(function () { promptInput.focus(); promptInput.select(); }, 0);
  }
  function closePrompt(accept) {
    if (prompt.hidden) { return; }
    prompt.hidden = true;
    var done = promptDone;
    promptDone = null;
    if (accept && done) { done(promptInput.value.trim()); }
    editorView.focus();
  }
  promptInput.addEventListener("keydown", function (event) {
    if (event.key === "Enter") { event.preventDefault(); closePrompt(true); }
    if (event.key === "Escape") { event.preventDefault(); closePrompt(false); }
  });
  promptInput.addEventListener("blur", function () { setTimeout(function () { closePrompt(false); }, 0); });
  function toggleLink(st, dispatch, v) {
    var link = schema.marks.link;
    if (markActive(st, link)) { return commands.toggleMark(link)(st, dispatch); }
    if (st.selection.empty) { return false; }
    var from = st.selection.from, to = st.selection.to;
    askText(pmString("Link address"), "https://", (v || editorView).coordsAtPos(from), function (href) {
      if (!href || href === "https://") { return; }
      var ev = v || editorView;
      ev.dispatch(ev.state.tr.addMark(from, to, link.create({ href: href })));
    });
    return true;
  }

  // ---------------------------------------------------------------------
  // Tables (spec §7): commands behind the table bar and the context menu,
  // spreadsheet paste, sort by column, per-column alignment.
  function columnAlign(align) {
    return function (st, dispatch) {
      if (!tables.isInTable(st)) { return false; }
      var rect = tables.selectedRect(st);
      var tr = st.tr;
      for (var col = rect.left; col < rect.right; col++) {
        for (var row = 0; row < rect.map.height; row++) {
          var cellPos = rect.map.map[row * rect.map.width + col];
          if (row > 0 && cellPos === rect.map.map[(row - 1) * rect.map.width + col]) { continue; }
          var cell = rect.table.nodeAt(cellPos);
          tr.setNodeMarkup(rect.tableStart + cellPos, null, Object.assign({}, cell.attrs, { align: align }));
        }
      }
      if (dispatch) { dispatch(tr); }
      return true;
    };
  }
  function tableRows(table) {
    var rows = [];
    table.forEach(function (row) { rows.push(row); });
    return rows;
  }
  function sortByColumn(descending) {
    return function (st, dispatch) {
      if (!tables.isInTable(st)) { return false; }
      var rect = tables.selectedRect(st);
      var table = rect.table;
      var col = rect.left;
      var rows = tableRows(table);
      var header = rows.length && rows[0].firstChild && rows[0].firstChild.type.name === "table_header" ? rows.shift() : null;
      function key(row) { var cell = row.maybeChild(col); return cell ? cell.textContent.trim() : ""; }
      var numeric = /^[-+]?(\d[\d,]*)?(\.\d+)?$/;
      rows.sort(function (a, b) {
        var ka = key(a), kb = key(b);
        var c;
        if (ka !== "" && kb !== "" && numeric.test(ka) && numeric.test(kb)) {
          c = parseFloat(ka.replace(/,/g, "")) - parseFloat(kb.replace(/,/g, ""));
        } else {
          c = ka.localeCompare(kb, undefined, { numeric: true, sensitivity: "base" });
        }
        return descending ? -c : c;
      });
      var rebuilt = table.type.create(table.attrs, (header ? [header] : []).concat(rows));
      if (dispatch) {
        var tr = st.tr.replaceWith(rect.tableStart - 1, rect.tableStart - 1 + table.nodeSize, rebuilt);
        var map = tables.TableMap.get(rebuilt);
        var cellPos = rect.tableStart + map.map[(header ? 1 : 0) * map.width + col];
        tr.setSelection(state.TextSelection.near(tr.doc.resolve(cellPos + 1)));
        dispatch(tr);
      }
      return true;
    };
  }
  function parseTSV(text) {
    var lines = text.replace(/\r/g, "").split("\n");
    while (lines.length && !lines[lines.length - 1].trim()) { lines.pop(); }
    if (!lines.length) { return null; }
    var rows = lines.map(function (line) { return line.split("\t"); });
    if (!rows.some(function (r) { return r.length > 1; })) { return null; }
    return rows;
  }
  function cellNode(type, text) {
    return type.create(null, [schema.nodes.paragraph.create(null, text ? schema.text(text) : null)]);
  }
  function tableFromRows(rows) {
    var width = rows.reduce(function (w, r) { return Math.max(w, r.length); }, 0);
    var rowNodes = rows.map(function (r, i) {
      var cells = [];
      for (var c = 0; c < width; c++) {
        cells.push(cellNode(i === 0 ? schema.nodes.table_header : schema.nodes.table_cell, r[c] || ""));
      }
      return schema.nodes.table_row.create(null, cells);
    });
    if (rowNodes.length === 1) {
      var blanks = [];
      for (var c2 = 0; c2 < width; c2++) { blanks.push(cellNode(schema.nodes.table_cell, "")); }
      rowNodes.push(schema.nodes.table_row.create(null, blanks));
    }
    return schema.nodes.table.create(null, rowNodes);
  }
  // Tab-separated cells (a spreadsheet selection) fill the table from
  // the current cell, growing it as needed; outside a table they become one.
  function pasteRows(v, rows) {
    var st = v.state;
    if (!tables.isInTable(st)) {
      v.dispatch(st.tr.replaceSelectionWith(tableFromRows(rows)).scrollIntoView());
      return true;
    }
    var rect = tables.selectedRect(st);
    var table = rect.table;
    var grid = tableRows(table).map(function (row) { var cells = []; row.forEach(function (c) { cells.push(c); }); return cells; });
    var pasteWidth = rows.reduce(function (w, r) { return Math.max(w, r.length); }, 0);
    var width = Math.max(rect.map.width, rect.left + pasteWidth);
    var height = Math.max(grid.length, rect.top + rows.length);
    for (var r = 0; r < height; r++) {
      grid[r] = grid[r] || [];
      for (var c = grid[r].length; c < width; c++) {
        grid[r].push(cellNode(r === 0 ? schema.nodes.table_header : schema.nodes.table_cell, ""));
      }
    }
    rows.forEach(function (row, ri) {
      row.forEach(function (text, ci) {
        var old = grid[rect.top + ri][rect.left + ci];
        grid[rect.top + ri][rect.left + ci] = old.type.create(old.attrs,
          [schema.nodes.paragraph.create(null, text ? schema.text(text) : null)]);
      });
    });
    var rebuilt = table.type.create(table.attrs, grid.map(function (cells) { return schema.nodes.table_row.create(null, cells); }));
    var tr = st.tr.replaceWith(rect.tableStart - 1, rect.tableStart - 1 + table.nodeSize, rebuilt);
    var map = tables.TableMap.get(rebuilt);
    var cellPos = rect.tableStart + map.map[rect.top * map.width + rect.left];
    tr.setSelection(state.TextSelection.near(tr.doc.resolve(cellPos + 1)));
    v.dispatch(tr.scrollIntoView());
    return true;
  }
  // Table chrome (spec §7), the way Notion, Craft, and Pages do it: a
  // handle above the caret's column and one beside its row, each
  // opening a menu of words; "+" pills on the table's right and bottom
  // edges append a column or a row. No icon bar to decode.
  var columnActions = [
    { key: "col-left", title: pmString("Add column left"), run: function () { return tables.addColumnBefore; } },
    { key: "col-right", title: pmString("Add column right"), run: function () { return tables.addColumnAfter; } },
    { key: "del-col", title: pmString("Delete column"), danger: true, run: function () { return tables.deleteColumn; } },
    { separator: true },
    { key: "align-left", title: pmString("Align left"), run: function () { return columnAlign("left"); } },
    { key: "align-center", title: pmString("Align center"), run: function () { return columnAlign("center"); } },
    { key: "align-right", title: pmString("Align right"), run: function () { return columnAlign("right"); } },
    { separator: true },
    { key: "sort-asc", title: pmString("Sort ascending"), run: function () { return sortByColumn(false); } },
    { key: "sort-desc", title: pmString("Sort descending"), run: function () { return sortByColumn(true); } },
  ];
  var rowActions = [
    { key: "row-above", title: pmString("Add row above"), run: function () { return tables.addRowBefore; } },
    { key: "row-below", title: pmString("Add row below"), run: function () { return tables.addRowAfter; } },
    { key: "del-row", title: pmString("Delete row"), danger: true, run: function () { return tables.deleteRow; } },
  ];
  var tableActions = columnActions.concat([{ separator: true }], rowActions);
  function appendColumn(st, dispatch) {
    if (!tables.isInTable(st)) { return false; }
    var rect = tables.selectedRect(st);
    if (dispatch) { dispatch(tables.addColumn(st.tr, rect, rect.map.width)); }
    return true;
  }
  function appendRow(st, dispatch) {
    if (!tables.isInTable(st)) { return false; }
    var rect = tables.selectedRect(st);
    if (dispatch) { dispatch(tables.addRow(st.tr, rect, rect.map.height)); }
    return true;
  }
  var tableChrome = document.createElement("div");
  tableChrome.className = "pm-table-chrome";
  tableChrome.hidden = true;
  function chromeButton(cls, label, title, onClick) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = cls;
    b.textContent = label;
    b.title = title;
    b.setAttribute("aria-label", title);
    b.addEventListener("mousedown", function (e) { e.preventDefault(); });
    b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); onClick(e); });
    tableChrome.append(b);
    return b;
  }
  var colHandle = chromeButton("pm-table-handle pm-table-handle-col", "", pmString("Column"), function () {
    var r = colHandle.getBoundingClientRect();
    showContextMenu(columnActions, r.left, r.bottom + 4);
  });
  var rowHandle = chromeButton("pm-table-handle pm-table-handle-row", "", pmString("Row"), function () {
    var r = rowHandle.getBoundingClientRect();
    showContextMenu(rowActions, r.right + 4, r.top);
  });
  var addColButton = chromeButton("pm-table-add pm-table-add-col", "+", pmString("Add column"), function () {
    appendColumn(editorView.state, editorView.dispatch);
    editorView.focus();
  });
  var addRowButton = chromeButton("pm-table-add pm-table-add-row", "+", pmString("Add row"), function () {
    appendRow(editorView.state, editorView.dispatch);
    editorView.focus();
  });
  document.body.append(tableChrome);
  function currentCellElement(st) {
    if (!tables.isInTable(st)) { return null; }
    var $cell = tables.cellAround(st.selection.$from);
    if (!$cell) { return null; }
    var dom = editorView.nodeDOM($cell.pos);
    return dom && dom.nodeType === 1 ? dom : null;
  }
  function tableElementAt(st) {
    if (!tables.isInTable(st)) { return null; }
    var rect = tables.selectedRect(st);
    var dom = editorView.nodeDOM(rect.tableStart - 1);
    return dom && dom.nodeType === 1 ? dom : null;
  }
  function updateTableBar() {
    var st = editorView.state;
    var tableEl = tableElementAt(st);
    var cellEl = currentCellElement(st);
    if (!tableEl || !cellEl || st.selection instanceof state.NodeSelection) { tableChrome.hidden = true; return; }
    var t = tableEl.getBoundingClientRect(), c = cellEl.getBoundingClientRect();
    var sx = window.scrollX, sy = window.scrollY;
    tableChrome.hidden = false;
    colHandle.style.left = (c.left + sx) + "px";
    colHandle.style.width = Math.max(18, c.width) + "px";
    colHandle.style.top = (t.top + sy - 9) + "px";
    rowHandle.style.top = (c.top + sy) + "px";
    rowHandle.style.height = Math.max(18, c.height) + "px";
    rowHandle.style.left = (t.left + sx - 9) + "px";
    addColButton.style.left = (t.right + sx + 4) + "px";
    addColButton.style.top = (t.top + sy) + "px";
    addColButton.style.height = t.height + "px";
    addRowButton.style.left = (t.left + sx) + "px";
    addRowButton.style.top = (t.bottom + sy + 4) + "px";
    addRowButton.style.width = t.width + "px";
  }
  window.addEventListener("resize", function () { if (!tableChrome.hidden) { updateTableBar(); } });
  // The escape hatch: any block can be edited as raw Markdown (a
  // "markdown" raw island, written back verbatim) and rendered again.
  function topBlockAt(st) {
    var $from = st.selection.$from;
    if ($from.depth < 1) { return null; }
    return { node: $from.node(1), pos: $from.before(1) };
  }
  // The island shows the block's own source when the block is still as
  // it was loaded (the author's formatting, not a re-serialization).
  function originalSource(node, pos) {
    for (var i = 0; i < ranges.length; i++) {
      if (pos === ranges[i].from && pos + node.nodeSize === ranges[i].to
          && model.Fragment.from([node]).eq(originals[i])) {
        return blocks[i].text;
      }
    }
    return null;
  }
  function editAsMarkdown(st, dispatch) {
    var block = topBlockAt(st);
    if (!block || (block.node.type.name === "raw_block")) { return false; }
    var text = originalSource(block.node, block.pos);
    var notes = block.node.attrs.notes || [];
    if (text === null) {
      text = serializeFragment(model.Fragment.from([withNotes(block.node, [])]));
    } else if (notes.length) {
      // The source carries the notes' comments too; the island keeps the
      // notes as cards instead, so strip them from the text.
      var stripped = text;
      notes.forEach(function (note) {
        var comment = noteText(note);
        var at = stripped.indexOf(comment);
        if (at >= 0) { stripped = stripped.slice(0, at) + stripped.slice(at + comment.length); }
      });
      text = stripped.replace(/\n{3,}/g, "\n\n").replace(/^\n+|\n+$/g, "");
    }
    if (dispatch) {
      var raw = schema.nodes.raw_block.create({ kind: "markdown", notes: notes },
                                              text ? schema.text(text) : null);
      var tr = st.tr.replaceWith(block.pos, block.pos + block.node.nodeSize, raw);
      dispatch(tr.setSelection(state.TextSelection.create(tr.doc, block.pos + 1)).scrollIntoView());
    }
    return true;
  }
  function renderMarkdown(st, dispatch) {
    var block = topBlockAt(st);
    if (!block || block.node.type.name !== "raw_block" || block.node.attrs.kind !== "markdown") { return false; }
    if (dispatch) {
      var parsed = absorbNotes(parseBlock(block.node.textContent, false)).nodes;
      if (!parsed.length) { parsed = [schema.nodes.paragraph.create()]; }
      if (block.node.attrs.notes && block.node.attrs.notes.length && bearsNotes(parsed[parsed.length - 1])) {
        var last = parsed[parsed.length - 1];
        parsed[parsed.length - 1] = withNotes(last, last.attrs.notes.concat(block.node.attrs.notes));
      }
      var tr = st.tr.replaceWith(block.pos, block.pos + block.node.nodeSize, parsed);
      dispatch(tr.setSelection(state.Selection.near(tr.doc.resolve(block.pos + 1))).scrollIntoView());
    }
    return true;
  }
  var blockActions = [
    { key: "quote", title: pmString("Quote"), run: function () { return toggleQuote; },
      available: function (st) { return !!blockOf(st) && !tables.isInTable(st); } },
    { key: "bullets", title: pmString("Bullet list"), run: function () { return toggleList("bullet_list", null); },
      available: function (st) { return !!blockOf(st) && !tables.isInTable(st); } },
    { key: "numbers", title: pmString("Numbered list"), run: function () { return toggleList("ordered_list", null); },
      available: function (st) { return !!blockOf(st) && !tables.isInTable(st); } },
    { key: "tasks", title: pmString("Task list"), run: function () { return toggleList("bullet_list", false); },
      available: function (st) { return !!blockOf(st) && !tables.isInTable(st); } },
    { separator: true, available: function (st) { return !!blockOf(st) && !tables.isInTable(st); } },
    { key: "edit-markdown", title: pmString("Edit as Markdown"), run: function () { return editAsMarkdown; },
      available: function (st) { var b = topBlockAt(st); return !!b && b.node.type.name !== "raw_block"; } },
    { key: "render-markdown", title: pmString("Render Markdown"), run: function () { return renderMarkdown; },
      available: function (st) { var b = topBlockAt(st); return !!b && b.node.type.name === "raw_block" && b.node.attrs.kind === "markdown"; } },
  ];
  function contextItems(st) {
    var items = tables.isInTable(st) ? tableActions.slice() : [];
    blockActions.forEach(function (item) { if (item.available(st)) { items.push(item); } });
    return items;
  }
  // Right-click inside a table: the same actions as a menu at the pointer.
  var contextMenu = document.createElement("div");
  contextMenu.className = "pm-context-menu pm-slash-menu";
  contextMenu.hidden = true;
  document.body.append(contextMenu);
  function showContextMenu(items, x, y) {
    contextMenu.innerHTML = "";
    items.forEach(function (item) {
      if (item.separator) {
        var hr = document.createElement("div");
        hr.className = "pm-menu-separator";
        contextMenu.append(hr);
        return;
      }
      var row = document.createElement("div");
      row.className = "pm-slash-item" + (item.danger ? " pm-menu-danger" : "");
      row.textContent = item.title;
      row.addEventListener("mousedown", function (e) { e.preventDefault(); });
      row.addEventListener("click", function () {
        hideContextMenu();
        item.run()(editorView.state, editorView.dispatch, editorView);
        editorView.focus();
      });
      contextMenu.append(row);
    });
    contextMenu.hidden = false;
    contextMenu.style.left = (x + window.scrollX) + "px";
    contextMenu.style.top = (y + window.scrollY) + "px";
    var overflow = x + contextMenu.offsetWidth - window.innerWidth + 12;
    if (overflow > 0) { contextMenu.style.left = (x + window.scrollX - overflow) + "px"; }
  }
  function hideContextMenu() { contextMenu.hidden = true; }
  document.addEventListener("mousedown", function (e) {
    if (!contextMenu.hidden && !contextMenu.contains(e.target)) { hideContextMenu(); }
  }, true);
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
  function requestSave(immediate, force) {
    if (pendingSave) { clearTimeout(pendingSave); pendingSave = null; }
    if (immediate) { postSave(force); return; }
    pendingSave = setTimeout(postSave, 600);
  }
  var lastSaved = null;
  // `force` skips the unchanged-text shortcut: ⌘S always asks, because
  // the app can refuse a save (the file changed on disk) and a posted
  // text is not necessarily a saved one. The app ignores text that
  // matches the file, so a forced post of saved text is free.
  function postSave(force) {
    pendingSave = null;
    var text = assemble(editorView.state.doc);
    if (!force && text === lastSaved) { return; }
    lastSaved = text;
    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge
      && window.webkit.messageHandlers.bridge.postMessage({ type: "richEditorSave", text: text });
  }
  function saveCommand() { requestSave(true, true); return true; }

  // Enter inside a task item makes another task item; elsewhere a plain
  // item (splitListItem copies no attributes on its own).
  function splitItem(st, dispatch) {
    var $from = st.selection.$from;
    for (var d = $from.depth; d > 0; d--) {
      var node = $from.node(d);
      if (node.type.name === "list_item") {
        var attrs = node.attrs.checked !== null ? { checked: false } : null;
        return listCmds.splitListItem(schema.nodes.list_item, attrs || undefined)(st, dispatch);
      }
    }
    return false;
  }
  // Enter at the end of a footnote definition starts a paragraph after it.
  function leaveFootnote(st, dispatch) {
    var $from = st.selection.$from;
    if ($from.parent.type.name !== "footnote_def" || !st.selection.empty) { return false; }
    if ($from.parentOffset < $from.parent.content.size) { return false; }
    if (dispatch) {
      var after = $from.after();
      var tr = st.tr.insert(after, schema.nodes.paragraph.create());
      dispatch(tr.setSelection(state.TextSelection.create(tr.doc, after + 1)).scrollIntoView());
    }
    return true;
  }
  var keys = {
    "Mod-z": PM.history.undo,
    "Shift-Mod-z": PM.history.redo,
    "Mod-y": PM.history.redo,
    "Mod-b": commands.toggleMark(schema.marks.strong),
    "Mod-i": commands.toggleMark(schema.marks.em),
    "Mod-`": commands.toggleMark(schema.marks.code),
    "Mod-k": toggleLink,
    "Mod-s": saveCommand,
    "Shift-Mod-m": commands.chainCommands(renderMarkdown, editAsMarkdown),
    "Enter": commands.chainCommands(tableEnter, splitItem, leaveFootnote,
                                    commands.newlineInCode, commands.createParagraphNear,
                                    commands.liftEmptyBlock, commands.splitBlock),
    "Tab": commands.chainCommands(tableTab(1), listCmds.sinkListItem(schema.nodes.list_item)),
    "Shift-Tab": commands.chainCommands(tableTab(-1), listCmds.liftListItem(schema.nodes.list_item)),
    "Mod-Enter": commands.exitCode,
    "Shift-Enter": commands.chainCommands(commands.exitCode, function (st, dispatch) {
      if (dispatch) { dispatch(st.tr.replaceSelectionWith(schema.nodes.hard_break.create()).scrollIntoView()); }
      return true;
    }),
    "Escape": function () { hideSlash(); hideToolbar(); hideContextMenu(); closePrompt(false); return false; },
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
    // "- [ ] " / "- [x] ": the wrapper rule creates the list, then the new
    // item gets its task box — wrappingInputRule's attrs reach only the
    // list node, which is why a typed task used to come out as a bullet.
    new inputrules.InputRule(/^\s*[-*]\s\[( |x)\]\s$/, function (st, match, start, end) {
      var checked = match[1] === "x";
      var tr = st.tr.delete(start, end);
      var $pos = tr.doc.resolve(start);
      var range = $pos.blockRange();
      if (!range) { return null; }
      var wrapping = range && PM.transform.findWrapping(range, schema.nodes.bullet_list, { bullet: "-" });
      if (!wrapping) { return null; }
      tr.wrap(range, wrapping);
      var $item = tr.doc.resolve(start);
      for (var d = $item.depth; d > 0; d--) {
        if ($item.node(d).type.name === "list_item") { tr.setNodeMarkup($item.before(d), null, { checked: checked }); break; }
      }
      return tr;
    }),
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
  // Monochrome inline icons for toolbar buttons that have no glyph of
  // their own — an emoji sat colored among the text labels.
  var ICON_ATTRS = 'viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"';
  var ICON_LINK = '<svg ' + ICON_ATTRS + '><path d="M6.5 9.5a3 3 0 0 0 4.24 0l2-2a3 3 0 0 0-4.24-4.24l-1 1"/><path d="M9.5 6.5a3 3 0 0 0-4.24 0l-2 2a3 3 0 0 0 4.24 4.24l1-1"/></svg>';
  var ICON_QUOTE = '<svg ' + ICON_ATTRS + '><path d="M3 3.5v9"/><path d="M6.5 5h6.5M6.5 8h6.5M6.5 11h4.5"/></svg>';
  var ICON_BULLETS = '<svg ' + ICON_ATTRS + '><circle cx="3.5" cy="4" r="0.9" fill="currentColor" stroke="none"/><circle cx="3.5" cy="8" r="0.9" fill="currentColor" stroke="none"/><circle cx="3.5" cy="12" r="0.9" fill="currentColor" stroke="none"/><path d="M6.5 4h6.5M6.5 8h6.5M6.5 12h6.5"/></svg>';
  var ICON_NUMBERS = '<svg ' + ICON_ATTRS + '><path d="M6.5 4h6.5M6.5 8h6.5M6.5 12h6.5"/><path d="M2.6 3l1.1-.6V6M2.4 9.4c.2-.5 1.5-.8 1.9 0 .3.6-.4 1-1.9 2.6h2.2" stroke-width="1.1"/></svg>';
  var ICON_TASKS = '<svg ' + ICON_ATTRS + '><rect x="2" y="2.5" width="4.5" height="4.5" rx="1"/><path d="M3 4.9l.9.9 1.6-1.8"/><rect x="2" y="9" width="4.5" height="4.5" rx="1"/><path d="M9 4.75h4.5M9 11.25h4.5"/></svg>';

  // Where the selection sits, in block terms.
  function blockOf(st) {
    var $from = st.selection.$from;
    return $from.depth ? $from.parent : null;
  }
  function wrapperOf(st, typeName) {
    var $from = st.selection.$from;
    for (var d = $from.depth; d > 0; d--) {
      var n = $from.node(d);
      if (n.type.name === typeName && !(typeName === "blockquote" && n.attrs.kind)) { return { node: n, depth: d }; }
    }
    return null;
  }
  function listItemOf(st) {
    var $from = st.selection.$from;
    for (var d = $from.depth; d > 0; d--) {
      if ($from.node(d).type.name === "list_item" && d > 0) {
        return { item: $from.node(d), depth: d, list: $from.node(d - 1) };
      }
    }
    return null;
  }
  // Quote: wrap the selected blocks, or lift them out of the quote they
  // are in (callouts keep their kind and are left alone).
  function toggleQuote(st, dispatch, v) {
    if (wrapperOf(st, "blockquote")) { return commands.lift(st, dispatch, v); }
    return commands.wrapIn(schema.nodes.blockquote)(st, dispatch, v);
  }
  // Lists: `checked === null` is a plain item, false/true a task box. The
  // same list type with the same task-ness toggles OFF (lift); anything
  // else converts in place, wrapping a paragraph first when needed.
  function toggleList(listType, checked) {
    return function (st, dispatch, v) {
      var li = listItemOf(st);
      if (li && li.list.type.name === listType && (li.item.attrs.checked === null) === (checked === null)) {
        return listCmds.liftListItem(schema.nodes.list_item)(st, dispatch, v);
      }
      if (li) {
        if (!dispatch) { return true; }
        var tr = st.tr;
        var listPos = st.selection.$from.before(li.depth - 1);
        if (li.list.type.name !== listType) {
          tr.setNodeMarkup(listPos, schema.nodes[listType], listType === "ordered_list" ? { order: 1 } : { bullet: "-" });
        }
        var itemPos = st.selection.$from.before(li.depth);
        tr.setNodeMarkup(itemPos, null, Object.assign({}, li.item.attrs, { checked: checked }));
        dispatch(tr.scrollIntoView());
        return true;
      }
      var wrap = listCmds.wrapInList(schema.nodes[listType], listType === "ordered_list" ? { order: 1 } : { bullet: "-" });
      if (checked === null) { return wrap(st, dispatch, v); }
      return wrap(st, dispatch && function (tr) {
        // The fresh items become task boxes.
        var $from = tr.selection.$from;
        for (var d = $from.depth; d > 0; d--) {
          if ($from.node(d).type.name === "list_item") {
            tr.setNodeMarkup($from.before(d), null, { checked: false });
            break;
          }
        }
        dispatch(tr);
      }, v);
    };
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
    { icon: ICON_LINK, title: pmString("Link"), cls: "pm-tb-link", run: function () { return toggleLink; }, active: function (st) { return markActive(st, schema.marks.link); } },
    { label: "H1", title: pmString("Heading 1"), run: function () { return commands.setBlockType(schema.nodes.heading, { level: 1 }); } },
    { label: "H2", title: pmString("Heading 2"), run: function () { return commands.setBlockType(schema.nodes.heading, { level: 2 }); } },
    { label: "H3", title: pmString("Heading 3"), run: function () { return commands.setBlockType(schema.nodes.heading, { level: 3 }); } },
    { label: "¶", title: pmString("Paragraph"), run: function () { return commands.setBlockType(schema.nodes.paragraph); }, active: function (st) { var b = blockOf(st); return !!b && b.type.name === "paragraph" && !wrapperOf(st, "blockquote") && !listItemOf(st); } },
    // Block wrappers the typed shortcuts can create but nothing could
    // restore once removed (Josh, 2026-09-22): the same four the "/"
    // menu inserts, as toggles on whatever is selected.
    { separator: true },
    { icon: ICON_QUOTE, title: pmString("Quote"), run: function () { return toggleQuote; }, active: function (st) { return !!wrapperOf(st, "blockquote"); } },
    { icon: ICON_BULLETS, title: pmString("Bullet list"), run: function () { return toggleList("bullet_list", null); }, active: function (st) { var li = listItemOf(st); return !!li && li.list.type.name === "bullet_list" && li.item.attrs.checked === null; } },
    { icon: ICON_NUMBERS, title: pmString("Numbered list"), run: function () { return toggleList("ordered_list", null); }, active: function (st) { var li = listItemOf(st); return !!li && li.list.type.name === "ordered_list"; } },
    { icon: ICON_TASKS, title: pmString("Task list"), run: function () { return toggleList("bullet_list", false); }, active: function (st) { var li = listItemOf(st); return !!li && li.item.attrs.checked !== null; } },
  ];
  toolbarItems.forEach(function (item) {
    if (item.separator) {
      var gap = document.createElement("span");
      gap.className = "pm-tb-separator";
      toolbar.append(gap);
      return;
    }
    var b = document.createElement("button");
    b.type = "button";
    if (item.icon) { b.innerHTML = item.icon; } else { b.textContent = item.label; }
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
  // A selected image gets its own strip: alt text and title, written on change.
  var imageForm = document.createElement("div");
  imageForm.className = "pm-image-form pm-float-toolbar";
  imageForm.hidden = true;
  function imageField(labelText, attr) {
    var wrap = document.createElement("label");
    wrap.className = "pm-image-field";
    var span = document.createElement("span");
    span.textContent = labelText;
    var input = document.createElement("input");
    input.type = "text";
    input.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === "Escape") { event.preventDefault(); editorView.focus(); }
    });
    input.addEventListener("change", function () {
      var sel = editorView.state.selection;
      if (!(sel instanceof state.NodeSelection) || sel.node.type.name !== "image") { return; }
      var attrs = Object.assign({}, sel.node.attrs);
      attrs[attr] = input.value || (attr === "alt" ? "" : null);
      editorView.dispatch(editorView.state.tr.setNodeMarkup(sel.from, null, attrs));
    });
    wrap.append(span, input);
    imageForm.append(wrap);
    return input;
  }
  var imageAlt = imageField(pmString("Alt text"), "alt");
  var imageTitle = imageField(pmString("Title"), "title");
  document.body.append(imageForm);
  function updateImageForm(sel) {
    if (!(sel instanceof state.NodeSelection) || sel.node.type.name !== "image") { imageForm.hidden = true; return; }
    if (document.activeElement !== imageAlt && document.activeElement !== imageTitle) {
      imageAlt.value = sel.node.attrs.alt || "";
      imageTitle.value = sel.node.attrs.title || "";
    }
    var dom = editorView.nodeDOM(sel.from);
    if (!dom || !dom.getBoundingClientRect) { imageForm.hidden = true; return; }
    var r = dom.getBoundingClientRect();
    imageForm.hidden = false;
    imageForm.style.left = Math.max(8, r.left + window.scrollX) + "px";
    imageForm.style.top = (r.bottom + window.scrollY + 6) + "px";
  }
  function hideToolbar() { toolbar.hidden = true; }
  function updateToolbar() {
    var st = editorView.state, sel = st.selection;
    updateImageForm(sel);
    updateTableBar();
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
    { title: pmString("Callout"), insert: function () { return schema.nodes.blockquote.create({ kind: "NOTE" }, [schema.nodes.paragraph.create()]); } },
    { title: pmString("Footnote"), run: insertFootnote },
    { title: pmString("Image"), run: insertImage },
    { title: pmString("Divider"), insert: function () { return schema.nodes.horizontal_rule.create(); } },
  ];
  function nextFootnoteLabel(doc) {
    var max = 0;
    doc.descendants(function (node) {
      if (node.type.name === "footnote_ref" || node.type.name === "footnote_def") {
        var n = parseInt(node.attrs.label, 10);
        if (!isNaN(n)) { max = Math.max(max, n); }
      }
      return true;
    });
    return String(max + 1);
  }
  // A reference at the caret plus its definition at the end of the
  // document, with the caret moved into the definition.
  function insertFootnote(tr) {
    var label = nextFootnoteLabel(tr.doc);
    var $pos = tr.doc.resolve(tr.selection.from);
    // The slash lived in an empty paragraph: keep the paragraph, put the reference in it.
    tr = tr.insert(tr.selection.from, schema.nodes.footnote_ref.create({ label: label }));
    var def = schema.nodes.footnote_def.create({ label: label });
    var end = tr.doc.content.size;
    tr = tr.insert(end, def);
    tr = tr.setSelection(state.TextSelection.create(tr.doc, end + 1));
    return tr;
  }
  function insertImage(tr) {
    var at = tr.selection.from;
    setTimeout(function () {
      askText(pmString("Image address"), "", editorView.coordsAtPos(Math.min(at, editorView.state.doc.content.size)), function (src) {
        if (!src) { return; }
        var alt = src.split("/").pop().replace(/\.[a-z0-9]+$/i, "").replace(/[-_]+/g, " ");
        editorView.dispatch(editorView.state.tr.replaceSelectionWith(schema.nodes.image.create({ src: src, alt: alt })).scrollIntoView());
      });
    }, 0);
    return tr;
  }
  // Clicking a callout's title opens its type picker.
  function calloutMenuAt(titleEl) {
    var box = titleEl.parentNode;
    var pos;
    try { pos = editorView.posAtDOM(box, 0); } catch (e) { return; }
    var $p = editorView.state.doc.resolve(pos);
    var quotePos = null;
    for (var d = $p.depth; d >= 0; d--) {
      if ($p.node(d).type.name === "blockquote") { quotePos = d === 0 ? 0 : $p.before(d); break; }
    }
    if (quotePos === null) { return; }
    var r = titleEl.getBoundingClientRect();
    var items = CALLOUT_KINDS.map(function (kind) {
      return { title: calloutTitle(kind), run: function () { return function (st, dispatch) {
        var node = st.doc.nodeAt(quotePos);
        if (dispatch) { dispatch(st.tr.setNodeMarkup(quotePos, null, Object.assign({}, node.attrs, { kind: kind }))); }
        return true; }; } };
    });
    items.push({ title: pmString("Plain quote"), run: function () { return function (st, dispatch) {
      var node = st.doc.nodeAt(quotePos);
      if (dispatch) { dispatch(st.tr.setNodeMarkup(quotePos, null, Object.assign({}, node.attrs, { kind: null }))); }
      return true; }; } });
    showContextMenu(items, r.left, r.bottom + 4);
  }
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
  // Raw islands (spec §4): fenced code stays monospace with a language
  // label (CSS reads data-params); a Mermaid fence also carries a
  // preview that re-renders once the caret leaves the block.
  var islands = [];
  function CodeIsland(node, v, getPos) {
    var self = this;
    this.node = node;
    this.getPos = getPos;
    this.view = v;
    this.dom = document.createElement("div");
    this.dom.className = "pm-island";
    var pre = document.createElement("pre");
    if (node.attrs.params) { pre.setAttribute("data-params", node.attrs.params); }
    this.code = document.createElement("code");
    pre.append(this.code);
    this.dom.append(pre);
    this.contentDOM = this.code;
    this.preview = null;
    this.rendered = null;
    if (/^mermaid\b/.test(node.attrs.params || "")) {
      this.dom.classList.add("pm-island-mermaid");
      this.preview = document.createElement("div");
      this.preview.className = "pm-island-preview mermaid-host";
      this.preview.contentEditable = "false";
      this.dom.append(this.preview);
    }
    islands.push(this);
    this.refresh(v.state, true);
  }
  CodeIsland.prototype.update = function (node) {
    if (node.type !== this.node.type) { return false; }
    this.node = node;
    return true;
  };
  CodeIsland.prototype.refresh = function (st, initial) {
    if (!this.preview) { return; }
    var pos = this.getPos();
    if (pos == null) { return; }
    var sel = st.selection;
    var inside = sel.from >= pos && sel.to <= pos + this.node.nodeSize;
    this.dom.classList.toggle("is-editing", inside);
    var text = this.node.textContent;
    if ((inside && !initial) || text === this.rendered) { return; }
    this.rendered = text;
    var target = this.preview;
    if (!window.mermaid || !window.mermaid.render) { target.textContent = ""; return; }
    var id = "pm-island-" + Math.random().toString(36).slice(2);
    try {
      var result = window.mermaid.render(id, text);
      if (result && typeof result.then === "function") {
        result.then(function (r) { target.innerHTML = r.svg; target.classList.remove("is-broken"); })
              .catch(function () { target.classList.add("is-broken"); });
      } else if (result && result.svg) { target.innerHTML = result.svg; }
    } catch (e) { target.classList.add("is-broken"); }
  };
  // The preview lives outside contentDOM; its mutations are ours, not
  // the document's (ProseMirror would otherwise re-read the node and
  // rebuild this view on every render — an endless loop).
  CodeIsland.prototype.ignoreMutation = function (mutation) {
    if (mutation.type === "selection") { return false; }
    return !this.contentDOM.contains(mutation.target);
  };
  CodeIsland.prototype.destroy = function () {
    var i = islands.indexOf(this);
    if (i >= 0) { islands.splice(i, 1); }
  };
  function refreshIslands(st) {
    islands.forEach(function (island) { island.refresh(st, false); });
  }

  // ---------------------------------------------------------------------
  // Margin notes while editing (spec §6): cards render as widget
  // decorations after the block that carries them (inside a list item,
  // at the item's end); the composer is a widget too. Add, edit, and
  // delete are ordinary transactions on the owner's `notes` attribute.
  var notesEnabled = spec.notesVisible !== false;
  var noteAuthoring = !!spec.noteAuthoring && notesEnabled;
  var notesKey = new state.PluginKey("pmNotes");
  var noteIntroPending = false;
  var noteIntroStash = null;
  var baseSetIntro = window.__pmSetNoteIntroPending;
  window.__pmSetNoteIntroPending = function (pending) {
    noteIntroPending = !!pending;
    if (!noteIntroPending) { noteIntroStash = null; }
    if (baseSetIntro) { baseSetIntro(pending); }
  };
  var baseIntroResolved = window.__pmNoteIntroResolved;
  window.__pmNoteIntroResolved = function (proceed) {
    var stash = noteIntroStash;
    noteIntroStash = null;
    if (proceed) { noteIntroPending = false; if (stash) { stash(); } }
    if (baseIntroResolved) { baseIntroResolved(proceed); }
  };
  function post(message) {
    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge
      && window.webkit.messageHandlers.bridge.postMessage(message);
  }
  function noteIntroGate(action) {
    if (!noteIntroPending) { action(); return; }
    noteIntroStash = action;
    post({ type: "noteIntroRequested" });
  }
  // Where a note's owner sits relative to its widget position.
  function ownerAt(doc, widgetPos, kind) {
    var $p = doc.resolve(widgetPos);
    if (kind === "before") { return $p.nodeAfter ? { node: $p.nodeAfter, pos: widgetPos } : null; }
    if (kind === "inner") { return $p.depth ? { node: $p.parent, pos: $p.before($p.depth) } : null; }
    return $p.nodeBefore ? { node: $p.nodeBefore, pos: widgetPos - $p.nodeBefore.nodeSize } : null;
  }
  function widgetPosFor(node, pos, kind) {
    if (kind === "before") { return pos; }
    if (kind === "inner") { return pos + node.nodeSize - 1; }
    return pos + node.nodeSize;
  }
  function kindFor(node, note) {
    if (note && note.before) { return "before"; }
    return node.type.name === "list_item" ? "inner" : "after";
  }
  function isFileLevel(owner, note) {
    return !!note.before || (owner.type.name === "raw_block" && owner.attrs.kind === "frontmatter");
  }
  function updateNotes(v, ownerPos, kind, mutate) {
    var st = v.state;
    var owner = st.doc.nodeAt(ownerPos);
    if (!owner || !bearsNotes(owner)) { return; }
    var notes = mutate(owner.attrs.notes.slice());
    var tr = st.tr.setNodeMarkup(ownerPos, null, Object.assign({}, owner.attrs, { notes: notes }));
    tr.setMeta(notesKey, { composer: null });
    v.dispatch(tr);
    v.focus();
  }
  function noteCard(v, getPos, kind, index) {
    var card = document.createElement("div");
    card.className = "pm-note pm-annotation";
    var head = document.createElement("div");
    head.className = "pm-note-head";
    var author = document.createElement("span");
    author.className = "pm-note-author";
    head.append(author);
    var scope = document.createElement("span");
    scope.className = "pm-note-scope";
    scope.textContent = pmString("whole document");
    var body = document.createElement("div");
    body.className = "pm-note-body";
    card.append(head, body);
    function current() {
      var owner = ownerAt(v.state.doc, getPos(), kind);
      return owner && owner.node.attrs.notes[index] ? owner : null;
    }
    function render() {
      var owner = current();
      if (!owner) { return; }
      var note = owner.node.attrs.notes[index];
      author.textContent = "@" + note.author;
      body.innerHTML = md.render(note.body || "");
      var fileLevel = isFileLevel(owner.node, note);
      card.classList.toggle("pm-note-file", fileLevel);
      if (fileLevel && !scope.parentNode) { author.after(scope); }
      if (!fileLevel && scope.parentNode) { scope.remove(); }
    }
    if (noteAuthoring) {
      var actions = document.createElement("div");
      actions.className = "pm-note-actions";
      var edit = document.createElement("button");
      edit.type = "button";
      edit.textContent = pmString("edit-action");
      edit.addEventListener("click", function () {
        noteIntroGate(function () {
          var owner = current();
          if (!owner) { return; }
          openComposer(owner.pos, kind, { index: index, seed: owner.node.attrs.notes[index].body });
        });
      });
      var del = document.createElement("button");
      del.type = "button";
      del.textContent = pmString("Delete");
      del.addEventListener("click", function () {
        noteIntroGate(function () {
          var owner = current();
          if (!owner) { return; }
          updateNotes(v, owner.pos, kind, function (notes) { notes.splice(index, 1); return notes; });
        });
      });
      actions.append(edit, del);
      head.append(actions);
    }
    render();
    card.pmRefresh = render;
    return card;
  }
  // The composer (mirrors app.js's noteComposerOpen): a textarea with
  // Cancel and one primary action; ⌘↩ submits, Esc cancels.
  function composerWidget(v, getPos, composer) {
    var root = document.createElement("div");
    root.className = "pm-composer pm-note-composer pm-annotation";
    var ta = document.createElement("textarea");
    ta.className = "pm-composer-text";
    ta.placeholder = composer.fileLevel ? pmString("Leave a note about the whole document")
                                        : pmString("Leave a margin note");
    ta.rows = 3;
    ta.value = composer.seed || "";
    var actions = document.createElement("div");
    actions.className = "pm-composer-actions";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.textContent = pmString("Cancel");
    var primary = document.createElement("button");
    primary.type = "button";
    primary.className = "pm-composer-primary";
    primary.textContent = composer.index >= 0 ? pmString("Save") : pmString("Add Note");
    primary.title = "⌘↩";
    actions.append(cancel, primary);
    root.append(ta, actions);
    function grow() {
      ta.style.height = "auto";
      ta.style.height = Math.max(72, ta.scrollHeight) + "px";
    }
    function updateState() { primary.disabled = ta.value.trim() === ""; }
    function submit() {
      var text = ta.value.trim();
      if (text === "") { return; }
      var owner = ownerAt(v.state.doc, getPos(), composer.kind);
      if (!owner) { closeComposer(); return; }
      updateNotes(v, owner.pos, composer.kind, function (notes) {
        if (composer.index >= 0 && notes[composer.index]) {
          notes[composer.index] = Object.assign({}, notes[composer.index], { body: text, source: null });
        } else {
          var note = { author: spec.noteAuthor || "", attrs: null, body: text,
                       before: composer.kind === "before", source: null };
          if (composer.kind === "before") { notes.unshift(note); } else { notes.push(note); }
        }
        return notes;
      });
    }
    cancel.addEventListener("click", closeComposer);
    primary.addEventListener("click", submit);
    ta.addEventListener("input", function () { grow(); updateState(); });
    ta.addEventListener("keydown", function (event) {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closeComposer(); return; }
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) { event.preventDefault(); submit(); }
    });
    setTimeout(function () {
      grow(); updateState();
      root.scrollIntoView({ block: "nearest", inline: "nearest" });
      ta.focus();
      ta.setSelectionRange(ta.value.length, ta.value.length);
    }, 0);
    return root;
  }
  function openComposer(ownerPos, kind, opts) {
    var owner = editorView.state.doc.nodeAt(ownerPos);
    if (!owner) { return; }
    var composer = { ownerPos: ownerPos, kind: kind, index: opts && opts.index >= 0 ? opts.index : -1,
                     seed: (opts && opts.seed) || "",
                     fileLevel: kind === "before" || (owner.type.name === "raw_block" && owner.attrs.kind === "frontmatter") };
    editorView.dispatch(editorView.state.tr.setMeta(notesKey, { composer: composer }));
    post({ type: "editingState", active: true });
  }
  function closeComposer() {
    if (!notesKey.getState(editorView.state).composer) { return; }
    editorView.dispatch(editorView.state.tr.setMeta(notesKey, { composer: null }));
    editorView.focus();
  }
  function buildNoteDecorations(doc, composer) {
    if (!notesEnabled) { return view.DecorationSet.empty; }
    var decos = [];
    var seenComposer = false;
    doc.descendants(function (node, pos) {
      if (bearsNotes(node)) {
        var editing = composer && composer.ownerPos === pos ? composer : null;
        node.attrs.notes.forEach(function (note, index) {
          var kind = kindFor(node, note);
          var at = widgetPosFor(node, pos, kind);
          if (editing && editing.index === index) {
            seenComposer = true;
            decos.push(view.Decoration.widget(at, function (v, getPos) { return composerWidget(v, getPos, editing); },
              { side: kind === "before" ? -1 : 1, key: "composer", ignoreSelection: true,
                stopEvent: function () { return true; } }));
            return;
          }
          decos.push(view.Decoration.widget(at, function (v, getPos) { return noteCard(v, getPos, kind, index); },
            { side: kind === "before" ? -1 : 1, key: "note:" + kind + ":" + index + ":" + note.author + ":" + note.body,
              ignoreSelection: true, stopEvent: function () { return true; } }));
        });
        if (editing && editing.index < 0 && !seenComposer) {
          seenComposer = true;
          var ckind = editing.kind;
          decos.push(view.Decoration.widget(widgetPosFor(node, pos, ckind),
            function (v, getPos) { return composerWidget(v, getPos, editing); },
            { side: ckind === "before" ? -1 : 1, key: "composer", ignoreSelection: true,
              stopEvent: function () { return true; } }));
        }
      }
      return node.type.name === "bullet_list" || node.type.name === "ordered_list"
        || node.type.name === "list_item" || node.type.name === "blockquote";
    });
    return view.DecorationSet.create(doc, decos);
  }
  var notesPlugin = new state.Plugin({
    key: notesKey,
    state: {
      init: function (config, st) { return { composer: null, decos: buildNoteDecorations(st.doc, null) }; },
      apply: function (tr, prev, oldState, newState) {
        var meta = tr.getMeta(notesKey);
        var composer = meta && "composer" in meta ? meta.composer : prev.composer;
        if (composer && tr.docChanged && !(meta && "composer" in meta)) {
          composer = Object.assign({}, composer, { ownerPos: tr.mapping.map(composer.ownerPos, -1) });
        }
        if (!tr.docChanged && !meta) { return prev; }
        return { composer: composer, decos: buildNoteDecorations(newState.doc, composer) };
      },
    },
    props: {
      decorations: function (st) { return notesKey.getState(st).decos; },
    },
  });

  // The hover affordance: one bubble in the right-hand rail that follows
  // the block (or list item) under the pointer, as reading mode does.
  var affordance = null;
  function setupNoteAffordance() {
    if (!noteAuthoring) { return; }
    document.documentElement.classList.add("pm-commenting-on");
    var layer = document.createElement("div");
    layer.className = "pm-affordance-layer pm-annotation";
    host.append(layer);
    var tools = document.createElement("div");
    tools.className = "pm-result-tools";
    tools.style.display = "none";
    var bubble = document.createElement("button");
    bubble.type = "button";
    bubble.className = "pm-comment-btn";
    bubble.title = pmString("Add a margin note");
    bubble.setAttribute("aria-label", bubble.title);
    bubble.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M1 2.75C1 1.784 1.784 1 2.75 1h10.5c.966 0 1.75.784 1.75 1.75v7.5A1.75 1.75 0 0 1 13.25 12H9.06l-2.573 2.573A1.458 1.458 0 0 1 4 13.543V12H2.75A1.75 1.75 0 0 1 1 10.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h4.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z"/></svg>';
    tools.append(bubble);
    layer.append(tools);
    var target = null;   // { el, pos, kind }
    var hideTimer = null;
    function hideNow() {
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      tools.style.display = "none";
      if (target) { target.el.classList.remove("pm-hover-target"); }
      target = null;
    }
    function position() {
      if (!target) { return; }
      var cRect = host.getBoundingClientRect();
      var rect = target.el.getBoundingClientRect();
      var tw = tools.getBoundingClientRect().width || 28;
      tools.style.left = Math.round(Math.min(cRect.width - tw - 6, window.innerWidth - cRect.left - tw - 18)) + "px";
      tools.style.top = Math.round(Math.min(Math.max(rect.top + 2, 10), rect.bottom - 34) - cRect.top) + "px";
    }
    function unitUnder(el) {
      var root = editorView.dom;
      if (!el || !root.contains(el) || el === root) { return null; }
      var item = null;
      for (var e = el; e && e !== root; e = e.parentElement) {
        if (e.tagName === "LI" && !item) { item = e; }
        if (e.classList && (e.classList.contains("pm-note") || e.classList.contains("pm-note-composer"))) { return null; }
      }
      var unit = item;
      if (!unit) {
        unit = el;
        while (unit.parentElement && unit.parentElement !== root) { unit = unit.parentElement; }
      }
      var inside;
      try { inside = editorView.posAtDOM(unit, 0); } catch (e) { return null; }
      var $p = editorView.state.doc.resolve(inside);
      if (item) {
        for (var d = $p.depth; d > 0; d--) {
          if ($p.node(d).type.name === "list_item") { return { el: unit, pos: $p.before(d), kind: "inner" }; }
        }
        return null;
      }
      if ($p.depth < 1) { return null; }
      var owner = $p.node(1);
      return bearsNotes(owner) ? { el: unit, pos: $p.before(1), kind: "after" } : null;
    }
    host.addEventListener("mousemove", function (event) {
      var unit = unitUnder(event.target);
      if (!unit) { return; }
      if (target && target.el === unit.el) { target.pos = unit.pos; return; }
      if (target) { target.el.classList.remove("pm-hover-target"); }
      if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
      target = unit;
      unit.el.classList.add("pm-hover-target");
      tools.style.display = "flex";
      position();
    });
    host.addEventListener("mouseleave", function () {
      if (hideTimer) { clearTimeout(hideTimer); }
      hideTimer = setTimeout(hideNow, 120);
    });
    tools.addEventListener("mouseenter", function () { if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; } });
    bubble.addEventListener("mousedown", function (event) { event.preventDefault(); });
    bubble.addEventListener("click", function (event) {
      event.stopPropagation();
      if (!target) { return; }
      var t = target;
      noteIntroGate(function () {
        var selected = String(window.getSelection() || "").trim();
        var seed = "";
        if (selected && t.el.contains(window.getSelection().anchorNode)) {
          seed = selected.split("\n").map(function (line) { return "> " + line; }).join("\n") + "\n\n";
        }
        hideNow();
        openComposer(t.pos, t.kind, { seed: seed });
      });
    });
    window.addEventListener("scroll", function () { if (target) { position(); } }, { passive: true });
    affordance = { hide: hideNow };
  }

  // Menu-driven entry (Add Margin Note / File Margin Note).
  var baseOpenComposer = window.__pmOpenNoteComposer;
  window.__pmOpenNoteComposer = function (fileLevel) {
    if (!noteAuthoring) { if (baseOpenComposer) { baseOpenComposer(fileLevel); } return; }
    var d = editorView.state.doc;
    if (fileLevel) {
      var first = d.firstChild;
      if (!first) { return; }
      if (first.type.name === "raw_block" && first.attrs.kind === "frontmatter") { openComposer(0, "after", {}); }
      else if (bearsNotes(first)) { openComposer(0, "before", {}); }
      return;
    }
    var chosen = null;
    d.forEach(function (node, offset) {
      if (chosen !== null || !bearsNotes(node)) { return; }
      var dom = editorView.nodeDOM(offset);
      if (dom && dom.getBoundingClientRect && dom.getBoundingClientRect().bottom > 80) { chosen = offset; }
    });
    if (chosen === null && d.childCount && bearsNotes(d.firstChild)) { chosen = 0; }
    if (chosen !== null) { openComposer(chosen, "after", {}); }
  };

  // ---------------------------------------------------------------------
  // Images on paste and drop (spec §9): the bytes go to Swift, which
  // writes the file into the Location's images folder and answers with
  // the relative path; the image node lands where the paste happened.
  var pendingImages = {};
  function imageFiles(dt) {
    var out = [];
    var list = dt.files || [];
    for (var i = 0; i < list.length; i++) {
      if (/^image\//.test(list[i].type)) { out.push(list[i]); }
    }
    return out;
  }
  function sendImages(files, at) {
    files.forEach(function (file) {
      var token = "img-" + Math.random().toString(36).slice(2);
      pendingImages[token] = at;
      var reader = new FileReader();
      reader.onload = function () {
        var data = String(reader.result || "");
        var comma = data.indexOf(",");
        post({ type: "richEditorImage", token: token, name: file.name || "", mime: file.type || "",
               data: comma >= 0 ? data.slice(comma + 1) : data });
      };
      reader.readAsDataURL(file);
    });
  }
  window.__pmRichEditorImageSaved = function (token, relativePath, alt) {
    var at = pendingImages[token];
    delete pendingImages[token];
    if (!relativePath) { return; }
    var st = editorView.state;
    if (typeof at !== "number" || at > st.doc.content.size) { at = st.selection.from; }
    var node = schema.nodes.image.create({ src: relativePath, alt: alt || "" });
    var tr = st.tr.insert(at, node);
    editorView.dispatch(tr.scrollIntoView());
    editorView.focus();
  };

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
        notesPlugin,
      ],
    }),
    nodeViews: {
      code_block: function (node, v, getPos) { return new CodeIsland(node, v, getPos); },
    },
    // Pasted text is Markdown: a copied heading pastes as a heading.
    clipboardTextParser: function (text) {
      var nodes = parseBlock(text, false);
      return new model.Slice(model.Fragment.from(nodes), 0, 0);
    },
    handlePaste: function (v, event) {
      var files = event.clipboardData ? imageFiles(event.clipboardData) : [];
      if (files.length) {
        event.preventDefault();
        sendImages(files, v.state.selection.from);
        return true;
      }
      var text = event.clipboardData ? event.clipboardData.getData("text/plain") : "";
      var rows = text ? parseTSV(text) : null;
      if (!rows) { return false; }
      event.preventDefault();
      return pasteRows(v, rows);
    },
    handleDrop: function (v, event) {
      var dt = event.dataTransfer;
      if (!dt) { return false; }
      var hit = v.posAtCoords({ left: event.clientX, top: event.clientY });
      var at = hit ? hit.pos : v.state.selection.from;
      // Finder gives file URLs: a file already inside the Location is
      // linked in place, never copied (Swift decides).
      var uris = (dt.getData("text/uri-list") || "").split(/\r?\n/).filter(function (u) { return /^file:/i.test(u); });
      if (uris.length) {
        event.preventDefault();
        uris.forEach(function (uri) {
          var token = "img-" + Math.random().toString(36).slice(2);
          pendingImages[token] = at;
          post({ type: "richEditorLinkFile", token: token, url: uri });
        });
        return true;
      }
      var files = imageFiles(dt);
      if (!files.length) { return false; }
      event.preventDefault();
      sendImages(files, at);
      return true;
    },
    handleDOMEvents: {
      contextmenu: function (v, event) {
        // The pointer's block becomes the caret's block first, so the
        // menu acts where the user clicked.
        var hit = v.posAtCoords({ left: event.clientX, top: event.clientY });
        if (hit) { v.dispatch(v.state.tr.setSelection(state.Selection.near(v.state.doc.resolve(hit.pos)))); }
        var items = contextItems(v.state);
        if (!items.length) { return false; }
        event.preventDefault();
        showContextMenu(items, event.clientX, event.clientY);
        return true;
      },
      mousedown: function (v, event) {
        var title = event.target && event.target.closest && event.target.closest(".markdown-alert-title");
        if (title && v.dom.contains(title)) {
          event.preventDefault();
          calloutMenuAt(title);
          return true;
        }
        return false;
      },
    },
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
      refreshIslands(newState);
    },
  });
  editorView.focus();
  setupNoteAffordance();

  // The bridge: Swift defers file reloads while this is true, and asks
  // for the text before flipping edit mode off.
  window.__pmRichEditorText = function () { return assemble(editorView.state.doc); };
  // The round-trip harness (scripts/editor-check.sh) drives edits through
  // this; nothing in the app reads it.
  window.__pmRichEditorView = editorView;
  window.__pmRichEditorOpenNoteComposer = function (index) {
    var d = editorView.state.doc;
    var pos = null, i = 0;
    d.forEach(function (node, offset) { if (pos === null && bearsNotes(node)) { if (i === index) { pos = offset; } i++; } });
    if (pos !== null) { openComposer(pos, "after", {}); }
    return pos !== null;
  };
  window.__pmRichEditorEditAsMarkdown = function () { return editAsMarkdown(editorView.state, editorView.dispatch); };
  window.__pmRichEditorRenderMarkdown = function () { return renderMarkdown(editorView.state, editorView.dispatch); };
  window.__pmRichEditorPasteText = function (text) {
    var rows = parseTSV(text);
    return rows ? pasteRows(editorView, rows) : false;
  };
  window.__pmRichEditorFlush = function () { requestSave(true); };
  // Block toggles for the harness (scripts/editor-check): the same
  // commands the floating toolbar and the context menu run.
  window.__pmRichEditorBlockToggles = { quote: toggleQuote, list: toggleList };
  var previousCommit = window.__pmCommitNow;
  window.__pmCommitNow = function () { requestSave(true); if (previousCommit) { previousCommit(); } };
  window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge
    && window.webkit.messageHandlers.bridge.postMessage({ type: "editingState", active: true });
  window.addEventListener("scroll", function () { if (!toolbar.hidden) { updateToolbar(); } }, { passive: true });
  } catch (error) { fail(error); }
})();
