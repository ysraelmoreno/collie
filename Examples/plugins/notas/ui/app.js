// Notas: a tiny sample plug-in for the Collie page API v1 (window.collie).
const list = document.getElementById("notes");
const empty = document.getElementById("empty");
let notes = [];

function render() {
  list.replaceChildren(...notes.map(n => {
    const li = document.createElement("li");
    li.textContent = n.text;
    return li;
  }));
  empty.hidden = notes.length > 0;
}

async function add(text) {
  const note = { id: notes.reduce((m, n) => Math.max(m, n.id), 0) + 1, text, at: new Date().toISOString() };
  notes.push(note);
  await collie.state.set({ notes });
  render();
  collie.emit("notas.changed", { count: notes.length });
  return note;
}

function base64(text) {
  let bin = "";
  for (const b of new TextEncoder().encode(text)) bin += String.fromCharCode(b);
  return btoa(bin);
}

collie.onCommand(async (name, args) => {
  switch (name) {
    case "add": return add(String(args.text));
    case "list": return notes;
    case "export": {
      if (args.format !== "md") throw new Error("format must be md");
      const md = "# Notas\n\n" + notes.map(n => `- ${n.text}`).join("\n") + "\n";
      return collie.files.output("notas.md", base64(md));
    }
  }
  throw new Error(`unknown command: ${name}`);
});

document.getElementById("add").addEventListener("submit", async e => {
  e.preventDefault();
  const input = document.getElementById("text");
  const text = input.value.trim();
  if (text) { await add(text); input.value = ""; }
});

collie.state.get().then(s => { notes = Array.isArray(s?.notes) ? s.notes : []; render(); });
