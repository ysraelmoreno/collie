// Quadro UI: talks only to the contract API (relative URLs, so it works inside the Collie panel).
// Every piece of card text goes in through textContent / createTextNode: card text is data, never markup.
(function () {
  "use strict";

  var BY = "painel";
  var state = {
    board: null,          // last document from api/board or api/stream
    showArchived: false,
    label: "",
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

  function visible(card) {
    if (Boolean(card.archived) !== state.showArchived) return false;
    if (state.label && (card.labels || []).indexOf(state.label) < 0) return false;
    if (state.matches && !state.matches.has(card.id)) return false;
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

  function renderColumn(col, ci, cols, cards) {
    var section = el("section", "column");
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
      var input = el("input", "new-card");
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
        post("api/card/create", { title: title, column: col.id }).then(function () {
          state.drafts[col.id] = "";
          input.value = "";
          return loadBoard();
        }, function () { /* error shown */ });
      });
      section.appendChild(input);
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
    var li = el("li", "card");
    li.dataset.id = card.id;
    li.draggable = !state.showArchived;

    var open = el("button", "open", card.title);
    open.type = "button";
    open.dataset.key = "open:" + card.id;
    open.setAttribute("aria-label", "Abrir cartão " + card.title);
    open.addEventListener("click", function () { openPanel(card.id); });
    li.appendChild(open);

    if ((card.labels || []).length) {
      var labels = el("div", "labels");
      card.labels.forEach(function (l) { labels.appendChild(el("span", "label", l)); });
      li.appendChild(labels);
    }
    if (card.assignee) li.appendChild(el("div", "assignee", "Responsável: " + card.assignee));

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
    li.appendChild(moves);

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
    }
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
      assignee: $("panel-assignee").value.trim()
    }).then(function () { state.panelDirty = false; return loadBoard(); }, function () {});
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
