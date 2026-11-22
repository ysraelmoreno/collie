// Quadro UI: talks only to the contract API (relative URLs, so it works inside the Collie panel).
// Every piece of card text goes in through textContent / createTextNode: card text is data, never markup.
(function () {
  "use strict";

  var BY = "painel";
  var SVG_NS = "http://www.w3.org/2000/svg";

  // Card types and priorities of the contract (onda 12). A card without them reads as impl / medium.
  var TYPES = [
    { id: "impl", name: "Impl" }, { id: "bug", name: "Bug" }, { id: "refactor", name: "Refactor" },
    { id: "spike", name: "Spike" }, { id: "test", name: "Test" }, { id: "docs", name: "Docs" },
    { id: "chore", name: "Chore" }
  ];
  var PRIORITIES = [{ id: "high", name: "Alta" }, { id: "medium", name: "Média" }, { id: "low", name: "Baixa" }];
  var DEFAULT_TYPE = "impl";
  var DEFAULT_PRIORITY = "medium";

  // 16x16 glyph per type (same drawing as the design prototype), built as SVG elements, never as markup.
  var LINE = { stroke: "currentColor", "stroke-linecap": "round", fill: "none" };
  function attrs(base, more) {
    var o = {}, k;
    for (k in base) o[k] = base[k];
    for (k in more) o[k] = more[k];
    return o;
  }
  var GLYPHS = {
    impl: [["path", attrs(LINE, { d: "M8 2.5v11M2.5 8h11", "stroke-width": "2" })]],
    bug: [
      ["ellipse", { cx: "8", cy: "9.5", rx: "3.6", ry: "4.4", fill: "currentColor" }],
      ["path", attrs(LINE, { d: "M5.5 6l-2-2M10.5 6l2-2M4.4 9.5H2M11.6 9.5H14M5.4 12.6l-2 1.8M10.6 12.6l2 1.8M6.5 4.6a1.6 1.6 0 013 0", "stroke-width": "1.4" })]
    ],
    refactor: [
      ["path", attrs(LINE, { d: "M3 6.5A5 5 0 0112.4 5M13 9.5A5 5 0 013.6 11", "stroke-width": "1.6" })],
      ["path", attrs(LINE, { d: "M12.8 2.4v3h-3M3.2 13.6v-3h3", "stroke-width": "1.6", "stroke-linejoin": "round" })]
    ],
    spike: [["path", { d: "M9 1.8L3.6 9h3.6l-.8 5.2L12.4 7H8.8z", fill: "currentColor" }]],
    test: [["path", { d: "M6 2h4M7 2v4.2L3.4 12.4A1.4 1.4 0 004.6 14.5h6.8a1.4 1.4 0 001.2-2.1L9 6.2V2", stroke: "currentColor", "stroke-width": "1.5", "stroke-linejoin": "round", fill: "none" }]],
    docs: [
      ["path", { d: "M4 2h5.5L12.5 5v9H4z", stroke: "currentColor", "stroke-width": "1.5", "stroke-linejoin": "round", fill: "none" }],
      ["path", attrs(LINE, { d: "M6 8h4.5M6 10.6h4.5", "stroke-width": "1.4" })]
    ],
    chore: [
      ["circle", { cx: "8", cy: "8", r: "2.2", stroke: "currentColor", "stroke-width": "1.5", fill: "none" }],
      ["path", attrs(LINE, { d: "M8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.6 3.6l1.4 1.4M11 11l1.4 1.4M12.4 3.6L11 5M5 11l-1.4 1.4", "stroke-width": "1.4" })]
    ]
  };
  var state = {
    board: null,          // last document from api/board or api/stream
    showArchived: false,
    label: "",
    types: {},            // type id -> true for the pressed type filters (none pressed = all)
    priorities: {},       // idem for priorities
    newType: {},          // column id -> type picked for its next card
    newPriority: {},      // column id -> priority picked for its next card
    panelType: DEFAULT_TYPE,
    panelPriority: DEFAULT_PRIORITY,
    query: "",
    matches: null,        // Set of ids from api/cards?q=, or null when no search
    openId: "",
    dragging: null,       // {id} while an HTML5 drag is in flight
    pending: false,       // a redraw waits for the drag to end
    drafts: {},           // column id -> text typed in its "new card" field
    panelDirty: false     // the user edited the panel fields since it was filled
  };

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }

  function known(list, id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
    return null;
  }
  function cardType(card) { return known(TYPES, card.type) ? card.type : DEFAULT_TYPE; }
  function cardPriority(card) { return known(PRIORITIES, card.priority) ? card.priority : DEFAULT_PRIORITY; }
  function priorityLabel(id) { return "Prioridade " + known(PRIORITIES, id).name.toLowerCase(); }

  function glyph(type) {
    var svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("class", "glyph");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    (GLYPHS[type] || GLYPHS[DEFAULT_TYPE]).forEach(function (part) {
      var n = document.createElementNS(SVG_NS, part[0]);
      for (var k in part[1]) n.setAttribute(k, part[1][k]);
      svg.appendChild(n);
    });
    return svg;
  }

  // glyph + label + color: the type never shows as color alone
  function typeChip(type) {
    var chip = el("span", "chip type-" + type);
    chip.appendChild(glyph(type));
    chip.appendChild(document.createTextNode(known(TYPES, type).name));
    return chip;
  }

  // three bars: high 3, medium 2, low 1. Named (role img) on cards, decorative inside a labelled button.
  function priorityMark(priority, named) {
    var mark = el("span", "prio " + priority);
    for (var i = 0; i < 3; i++) mark.appendChild(el("i"));
    if (named) {
      mark.setAttribute("role", "img");
      mark.setAttribute("aria-label", priorityLabel(priority));
      mark.title = priorityLabel(priority);
    } else {
      mark.setAttribute("aria-hidden", "true");
    }
    return mark;
  }

  function showError(msg) {
    var e = $("error");
    if (!msg) { e.hidden = true; e.textContent = ""; return; }
    e.textContent = msg;
    e.hidden = false;
  }

  function request(path, body) {
    var opts = body === undefined ? {} : {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    };
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        if (!r.ok) throw new Error((data && data.error) || ("erro " + r.status));
        return data;
      });
    });
  }

  function post(path, body) {
    body.by = BY;
    return request(path, body).then(function (data) { showError(""); return data; }, function (err) {
      showError(err.message);
      throw err;
    });
  }

  function loadBoard() {
    return request(state.showArchived ? "api/board?archived=1" : "api/board").then(function (doc) {
      state.board = doc;
      showError("");
      scheduleRender();
    }, function (err) { showError(err.message); });
  }

  function runSearch() {
    var q = state.query.trim();
    if (!q) { state.matches = null; scheduleRender(); return; }
    request("api/cards?q=" + encodeURIComponent(q)).then(function (data) {
      if (state.query.trim() !== q) return;
      state.matches = new Set((data.cards || []).map(function (c) { return c.id; }));
      scheduleRender();
    }, function (err) { showError(err.message); });
  }

  function findCard(id) {
    var cards = (state.board && state.board.cards) || [];
    for (var i = 0; i < cards.length; i++) if (cards[i].id === id) return cards[i];
    return null;
  }

  function columnName(id) {
    var cols = (state.board && state.board.columns) || [];
    for (var i = 0; i < cols.length; i++) if (cols[i].id === id) return cols[i].name;
    return id;
  }

  function anyOn(set) { return Object.keys(set).length > 0; }

  // skip: "type" or "priority" leaves that filter out (used for the counts on the filter buttons)
  function visible(card, skip) {
    if (Boolean(card.archived) !== state.showArchived) return false;
    if (state.label && (card.labels || []).indexOf(state.label) < 0) return false;
    if (state.matches && !state.matches.has(card.id)) return false;
    if (skip !== "type" && anyOn(state.types) && !state.types[cardType(card)]) return false;
    if (skip !== "priority" && anyOn(state.priorities) && !state.priorities[cardPriority(card)]) return false;
    return true;
  }

  // ---- redraw (keeps focus and drafts; waits for a drag to end) ----

  function scheduleRender() {
    if (state.dragging) { state.pending = true; return; }
    render();
  }

  function focusKey(node) {
    while (node && node !== document.body) {
      if (node.dataset && node.dataset.key) return node.dataset.key;
      node = node.parentNode;
    }
    return "";
  }

  function render() {
    state.pending = false;
    var board = $("board");
    var active = document.activeElement;
    var key = board.contains(active) ? focusKey(active) : "";
    var sel = null;
    if (key && active && typeof active.selectionStart === "number") sel = [active.selectionStart, active.selectionEnd];

    renderLabels();
    renderFilters();
    var cols = (state.board && state.board.columns) || [];
    var cards = (state.board && state.board.cards) || [];
    var frag = document.createDocumentFragment();
    cols.forEach(function (col, ci) {
      frag.appendChild(renderColumn(col, ci, cols, cards.filter(function (c) { return c.column === col.id && visible(c); })));
    });
    while (board.firstChild) board.removeChild(board.firstChild);
    board.appendChild(frag);

    if (key) {
      var target = board.querySelector('[data-key="' + cssEscape(key) + '"]');
      if (target) {
        target.focus();
        if (sel && typeof target.setSelectionRange === "function") {
          try { target.setSelectionRange(sel[0], sel[1]); } catch (e) { /* not a text field */ }
        }
      }
    }
    renderPanel();
  }

  function cssEscape(s) {
    return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  function renderLabels() {
    var select = $("label-filter");
    var seen = {};
    ((state.board && state.board.cards) || []).forEach(function (c) {
      (c.labels || []).forEach(function (l) { seen[l] = true; });
    });
    var labels = Object.keys(seen).sort();
    if (state.label && !seen[state.label]) labels.push(state.label);
    var current = Array.prototype.slice.call(select.options, 1).map(function (o) { return o.value; });
    if (current.join("\n") === labels.join("\n")) return;
    while (select.options.length > 1) select.remove(1);
    labels.forEach(function (l) {
      var o = el("option", null, l);
      o.value = l;
      select.appendChild(o);
    });
    select.value = state.label;
  }

  // ---- type and priority filters (buttons built once; render only updates counts and state) ----

  function buildFilters() {
    TYPES.forEach(function (t) {
      var b = el("button", "tf type-" + t.id);
      b.type = "button";
      b.dataset.filter = t.id;
      b.appendChild(glyph(t.id));
      b.appendChild(document.createTextNode(t.name));
      b.appendChild(el("span", "n", "0"));
      b.addEventListener("click", function () { toggleFilter(state.types, t.id); });
      $("type-filter").appendChild(b);
    });
    PRIORITIES.forEach(function (p) {
      var b = el("button", "pf");
      b.type = "button";
      b.dataset.filter = p.id;
      b.appendChild(priorityMark(p.id, false));
      b.appendChild(document.createTextNode(p.name));
      b.appendChild(el("span", "n", "0"));
      b.addEventListener("click", function () { toggleFilter(state.priorities, p.id); });
      $("priority-filter").appendChild(b);
    });
  }

  function toggleFilter(set, id) {
    if (set[id]) delete set[id];
    else set[id] = true;
    scheduleRender();
  }

  function renderFilters() {
    var cards = (state.board && state.board.cards) || [];
    function update(groupId, list, set, skip, valueOf, what) {
      var counts = {};
      cards.forEach(function (c) { if (visible(c, skip)) counts[valueOf(c)] = (counts[valueOf(c)] || 0) + 1; });
      Array.prototype.forEach.call($(groupId).querySelectorAll("button"), function (b) {
        var item = known(list, b.dataset.filter);
        var n = counts[item.id] || 0;
        b.lastChild.textContent = String(n);
        b.setAttribute("aria-pressed", String(Boolean(set[item.id])));
        b.setAttribute("aria-label", what + " " + item.name + ", " + n + (n === 1 ? " cartão" : " cartões"));
      });
    }
    update("type-filter", TYPES, state.types, "type", cardType, "Tipo");
    update("priority-filter", PRIORITIES, state.priorities, "priority", cardPriority, "Prioridade");
  }

  function picker(list, value, label, key, onChange) {
    var s = el("select");
    s.setAttribute("aria-label", label);
    s.dataset.key = key;
    list.forEach(function (item) {
      var o = el("option", null, item.name);
      o.value = item.id;
      s.appendChild(o);
    });
    s.value = value;
    s.addEventListener("change", function () { onChange(s.value); });
    return s;
  }

  function renderColumn(col, ci, cols, cards) {
    var section = el("section", "column");
    if (col.id === "done") section.classList.add("done");
    section.dataset.column = col.id;
    var headId = "col-" + col.id;
    section.setAttribute("aria-labelledby", headId);

    var h = el("h2");
    h.id = headId;
    h.appendChild(document.createTextNode(col.name));
    var count = el("span", "count", String(cards.length));
    count.setAttribute("aria-label", cards.length + (cards.length === 1 ? " cartão" : " cartões"));
    h.appendChild(count);
    section.appendChild(h);

    if (!state.showArchived) {
      var box = el("div", "new-card");
      var input = el("input", "new-title");
      input.type = "text";
      input.maxLength = 200;
      input.placeholder = "Novo cartão (Enter)";
      input.setAttribute("aria-label", "Novo cartão em " + col.name);
      input.dataset.key = "new:" + col.id;
      input.value = state.drafts[col.id] || "";
      input.addEventListener("input", function () { state.drafts[col.id] = input.value; });
      input.addEventListener("keydown", function (ev) {
        if (ev.key !== "Enter") return;
        ev.preventDefault();
        var title = input.value.trim();
        if (!title) return;
        post("api/card/create", {
          title: title, column: col.id,
          type: state.newType[col.id] || DEFAULT_TYPE,
          priority: state.newPriority[col.id] || DEFAULT_PRIORITY
        }).then(function () {
          state.drafts[col.id] = "";
          input.value = "";
          return loadBoard();
        }, function () { /* error shown */ });
      });
      box.appendChild(input);
      box.appendChild(picker(TYPES, state.newType[col.id] || DEFAULT_TYPE, "Tipo do novo cartão em " + col.name,
        "newtype:" + col.id, function (v) { state.newType[col.id] = v; }));
      box.appendChild(picker(PRIORITIES, state.newPriority[col.id] || DEFAULT_PRIORITY,
        "Prioridade do novo cartão em " + col.name, "newprio:" + col.id, function (v) { state.newPriority[col.id] = v; }));
      section.appendChild(box);
    }

    var list = el("ol", "cards");
    list.setAttribute("aria-label", "Cartões em " + col.name);
    cards.forEach(function (card, i) { list.appendChild(renderCard(card, ci, cols)); });
    section.appendChild(list);

    section.addEventListener("dragover", function (ev) {
      if (!state.dragging) return;
      ev.preventDefault();
      if (ev.dataTransfer) ev.dataTransfer.dropEffect = "move";
      section.classList.add("drop-target");
      markDropBefore(list, ev.clientY);
    });
    section.addEventListener("dragleave", function (ev) {
      if (!section.contains(ev.relatedTarget)) { section.classList.remove("drop-target"); clearDropMarks(list); }
    });
    section.addEventListener("drop", function (ev) {
      if (!state.dragging) return;
      ev.preventDefault();
      var id = state.dragging.id;
      var index = dropIndex(list, ev.clientY, id);
      section.classList.remove("drop-target");
      clearDropMarks(list);
      endDrag();
      move(id, col.id, index);
    });
    return section;
  }

  // index among the column's cards (not counting the dragged one) where the pointer is
  function dropIndex(list, y, draggedId) {
    var items = Array.prototype.filter.call(list.children, function (li) { return li.dataset.id !== draggedId; });
    for (var i = 0; i < items.length; i++) {
      var r = items[i].getBoundingClientRect();
      if (y < r.top + r.height / 2) return i;
    }
    return items.length;
  }

  function clearDropMarks(list) {
    Array.prototype.forEach.call(list.children, function (li) { li.classList.remove("drop-before"); });
  }

  function markDropBefore(list, y) {
    clearDropMarks(list);
    var id = state.dragging && state.dragging.id;
    var items = Array.prototype.filter.call(list.children, function (li) { return li.dataset.id !== id; });
    var i = dropIndex(list, y, id);
    if (i < items.length) items[i].classList.add("drop-before");
  }

  function endDrag() {
    state.dragging = null;
    if (state.pending) render();
  }

  function renderCard(card, ci, cols) {
    var type = cardType(card);
    var priority = cardPriority(card);
    var li = el("li", "card type-" + type);
    li.dataset.id = card.id;
    li.draggable = !state.showArchived;

    var head = el("div", "head");
    head.appendChild(typeChip(type));
    head.appendChild(el("span", "cid", String(card.id || "").slice(0, 8)));
    li.appendChild(head);

    var open = el("button", "open", card.title);
    open.type = "button";
    open.dataset.key = "open:" + card.id;
    open.setAttribute("aria-label", "Abrir cartão " + card.title + " (" + known(TYPES, type).name + ", " +
      priorityLabel(priority).toLowerCase() + ")");
    open.addEventListener("click", function () { openPanel(card.id); });
    li.appendChild(open);

    if ((card.labels || []).length) {
      var labels = el("div", "labels");
      card.labels.forEach(function (l) { labels.appendChild(el("span", "label", l)); });
      li.appendChild(labels);
    }
    var foot = el("div", "foot");
    foot.appendChild(priorityMark(priority, true));
    foot.appendChild(el("span", "assignee", card.assignee ? "Responsável: " + card.assignee : ""));

    var moves = el("div", "moves");
    if (state.showArchived) {
      var restore = el("button", null, "Restaurar");
      restore.type = "button";
      restore.dataset.key = "restore:" + card.id;
      restore.setAttribute("aria-label", "Restaurar cartão " + card.title);
      restore.addEventListener("click", function () {
        post("api/card/restore", { id: card.id }).then(loadBoard, function () {});
      });
      moves.appendChild(restore);
    } else {
      if (ci > 0) moves.appendChild(moveButton(card, cols[ci - 1], "←", "anterior", "prev"));
      if (ci < cols.length - 1) moves.appendChild(moveButton(card, cols[ci + 1], "→", "seguinte", "next"));
    }
    foot.appendChild(moves);
    li.appendChild(foot);

    li.addEventListener("dragstart", function (ev) {
      state.dragging = { id: card.id };
      li.classList.add("dragging");
      if (ev.dataTransfer) {
        ev.dataTransfer.effectAllowed = "move";
        ev.dataTransfer.setData("text/plain", card.id);
      }
    });
    li.addEventListener("dragend", function () {
      li.classList.remove("dragging");
      if (state.dragging) endDrag();
    });
    return li;
  }

  function moveButton(card, toCol, glyph, which, tag) {
    var b = el("button", null, glyph);
    b.type = "button";
    b.dataset.key = tag + ":" + card.id;
    b.setAttribute("aria-label", "Mover " + card.title + " para a coluna " + which + " (" + toCol.name + ")");
    b.addEventListener("click", function () {
      move(card.id, toCol.id).then(function () {
        // keep keyboard users on the card they moved
        var again = document.querySelector('[data-key="' + cssEscape(tag + ":" + card.id) + '"]') ||
          document.querySelector('[data-key="' + cssEscape("open:" + card.id) + '"]');
        if (again) again.focus();
      });
    });
    return b;
  }

  function move(id, column, index) {
    var body = { id: id, column: column };
    if (typeof index === "number") body.index = index;
    return post("api/card/move", body).then(loadBoard, function () { return loadBoard(); });
  }

  // ---- side panel ----

  function openPanel(id) {
    state.openId = id;
    state.panelDirty = false;
    $("panel").hidden = false;
    fillPanel(true);
    $("panel-title").focus();
    publishContext();
  }

  function closePanel() {
    var id = state.openId;
    state.openId = "";
    $("panel").hidden = true;
    publishContext();
    var back = document.querySelector('[data-key="' + cssEscape("open:" + id) + '"]');
    if (back) back.focus();
  }

  function renderPanel() {
    if (!state.openId) return;
    fillPanel(!state.panelDirty);
  }

  function fillPanel(fields) {
    var card = findCard(state.openId);
    if (!card) {
      $("panel-meta").textContent = state.showArchived ? "Cartão não encontrado." : "Cartão arquivado ou removido.";
      return;
    }
    $("panel-heading").textContent = card.title;
    $("panel-meta").textContent = columnName(card.column) + " · criado por " + (card.createdBy || "?") +
      (card.archived ? " · arquivado" : "");
    if (fields) {
      $("panel-title").value = card.title || "";
      $("panel-body").value = card.body || "";
      $("panel-labels").value = (card.labels || []).join(", ");
      $("panel-assignee").value = card.assignee || "";
      state.panelType = cardType(card);
      state.panelPriority = cardPriority(card);
    }
    syncRadios();
    var archive = $("panel-archive");
    archive.textContent = card.archived ? "Restaurar" : "Arquivar";
    archive.setAttribute("aria-label", card.archived ? "Restaurar cartão" : "Arquivar cartão");

    var list = $("panel-comments");
    while (list.firstChild) list.removeChild(list.firstChild);
    (card.comments || []).forEach(function (c) {
      var li = el("li");
      li.appendChild(el("span", "by", (c.by || "?") + " · " + (c.at || "")));
      li.appendChild(document.createTextNode(c.text));
      list.appendChild(li);
    });
    if (!(card.comments || []).length) list.appendChild(el("li", null, "Sem comentários."));
    publishContext();
  }

  function publishContext() {
    var c = window.collie;
    if (!c || typeof c.context !== "function") return;
    var card = state.openId ? findCard(state.openId) : null;
    var value = card ? { id: card.id, title: card.title, column: card.column } : {};
    var key = JSON.stringify(value);
    if (key === publishContext.last) return;
    publishContext.last = key;
    try {
      var p = c.context(value);
      if (p && typeof p.catch === "function") p.catch(function () { /* the panel may refuse; the board works the same */ });
    } catch (e) { /* idem */ }
  }

  function saveCard() {
    var labels = $("panel-labels").value.split(",").map(function (s) { return s.trim(); }).filter(Boolean);
    post("api/card/update", {
      id: state.openId,
      title: $("panel-title").value.trim(),
      body: $("panel-body").value,
      labels: labels,
      assignee: $("panel-assignee").value.trim(),
      type: state.panelType,
      priority: state.panelPriority
    }).then(function () { state.panelDirty = false; return loadBoard(); }, function () {});
  }

  // radiogroups of the panel (type: 7, priority: 3); one tab stop each, arrows move the choice
  function buildRadios(groupId, list, field, makeContent) {
    var group = $(groupId);
    list.forEach(function (item) {
      var b = el("button");
      b.type = "button";
      b.setAttribute("role", "radio");
      b.setAttribute("aria-label", item.name);
      b.dataset.value = item.id;
      makeContent(b, item);
      b.addEventListener("click", function () { pick(field, item.id); });
      b.addEventListener("keydown", function (ev) {
        var step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[ev.key];
        if (!step) return;
        ev.preventDefault();
        var i = list.indexOf(item);
        var next = list[(i + step + list.length) % list.length];
        pick(field, next.id);
        group.querySelector('[data-value="' + next.id + '"]').focus();
      });
      group.appendChild(b);
    });
  }

  function pick(field, value) {
    if (state[field] === value) return;
    state[field] = value;
    state.panelDirty = true;
    syncRadios();
  }

  function syncRadios() {
    [["panel-type", state.panelType], ["panel-priority", state.panelPriority]].forEach(function (pair) {
      Array.prototype.forEach.call($(pair[0]).querySelectorAll("button"), function (b) {
        var on = b.dataset.value === pair[1];
        b.setAttribute("aria-checked", String(on));
        b.tabIndex = on ? 0 : -1;
      });
    });
  }

  function addComment() {
    var box = $("panel-comment");
    var text = box.value.trim();
    if (!text) return;
    post("api/card/comment", { id: state.openId, text: text }).then(function () {
      box.value = "";
      return loadBoard();
    }, function () {});
  }

  function toggleArchive() {
    var card = findCard(state.openId);
    if (!card) return;
    post(card.archived ? "api/card/restore" : "api/card/archive", { id: card.id }).then(loadBoard, function () {});
  }

  // ---- live updates ----

  function setStatus(text, offline) {
    var s = $("status");
    s.textContent = text;
    s.classList.toggle("offline", Boolean(offline));
  }

  function connect() {
    if (typeof window.EventSource !== "function") { setStatus("sem ao vivo"); return; }
    var es = new EventSource("api/stream");
    es.addEventListener("open", function () { setStatus("ao vivo"); });
    es.addEventListener("error", function () {
      setStatus(es.readyState === 2 ? "desconectado" : "reconectando…", true);
    });
    es.addEventListener("document", function (ev) {
      setStatus("ao vivo");
      if (state.showArchived) { loadBoard(); return; }   // the stream carries the plain board
      var doc;
      try { doc = JSON.parse(ev.data); } catch (e) { return; }
      state.board = doc;
      if (state.query.trim()) runSearch();
      scheduleRender();
    });
  }

  // ---- wiring ----

  function init() {
    var searchTimer = 0;
    buildFilters();
    buildRadios("panel-type", TYPES, "panelType", function (b, t) {
      b.classList.add("type-" + t.id);
      b.appendChild(glyph(t.id));
      b.appendChild(document.createTextNode(t.name));
    });
    buildRadios("panel-priority", PRIORITIES, "panelPriority", function (b, p) {
      b.appendChild(priorityMark(p.id, false));
      b.appendChild(document.createTextNode(p.name));
    });
    syncRadios();
    $("search").addEventListener("input", function () {
      state.query = $("search").value;
      clearTimeout(searchTimer);
      searchTimer = setTimeout(runSearch, 200);
    });
    $("label-filter").addEventListener("change", function () {
      state.label = $("label-filter").value;
      scheduleRender();
    });
    $("toggle-archived").addEventListener("click", function () {
      state.showArchived = !state.showArchived;
      var b = $("toggle-archived");
      b.setAttribute("aria-pressed", String(state.showArchived));
      b.setAttribute("aria-label", state.showArchived ? "Voltar ao quadro" : "Mostrar arquivados");
      $("archived-banner").hidden = !state.showArchived;
      loadBoard();
    });
    $("panel-close").addEventListener("click", closePanel);
    $("panel-save").addEventListener("click", saveCard);
    $("panel-archive").addEventListener("click", toggleArchive);
    $("panel-comment-add").addEventListener("click", addComment);
    ["panel-title", "panel-body", "panel-labels", "panel-assignee"].forEach(function (id) {
      $(id).addEventListener("input", function () { state.panelDirty = true; });
    });
    $("panel-title").addEventListener("keydown", function (ev) {
      if (ev.key === "Enter") { ev.preventDefault(); saveCard(); }
    });
    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape" && state.openId) closePanel();
    });
    loadBoard();
    connect();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
