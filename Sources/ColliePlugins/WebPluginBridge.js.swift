/// `window.collie`, page API v1, injected at document start (main frame, page world) into an external plug-in's page.
/// Everything goes through one message handler with reply (`collie`); Swift validates every call (`WebPluginPanel`).
/// `__THEME__` is replaced with the theme JSON. The page can tamper with its own copy; it only ever reaches Swift
/// through the handler, which trusts nothing it sends.
enum WebPluginBridge {
    static let handler = "collie"

    static func script(theme: String) -> String { source.replacingOccurrences(of: "__THEME__", with: theme) }

    private static let source = #"""
    (() => {
      const post = (m) => window.webkit.messageHandlers.collie.postMessage(m);
      let handler = null, theme = __THEME__;
      const applyTheme = () => {
        const set = () => { for (const [k, v] of Object.entries(theme.tokens)) document.documentElement.style.setProperty(k, v) };
        if (document.documentElement) set(); else document.addEventListener("DOMContentLoaded", set, { once: true });
      };
      const json = (v) => JSON.stringify(v === undefined ? null : v);
      const collie = Object.freeze({
        apiVersion: 1,
        onCommand(fn) {
          if (typeof fn !== "function") throw new TypeError("collie.onCommand needs a function");
          handler = fn; post({ op: "ready" });
        },
        emit(event, payload) { return post({ op: "emit", event: String(event), payload: json(payload) }) },
        state: Object.freeze({
          get: async () => JSON.parse(await post({ op: "state.get" })),
          set: (obj) => post({ op: "state.set", value: json(obj) }),
        }),
        files: Object.freeze({
          output: async (name, base64) => JSON.parse(await post({ op: "files.output", name: String(name), data: String(base64) })),
        }),
        get theme() { return theme },
      });
      Object.defineProperty(window, "collie", { value: collie, writable: false, configurable: false });
      Object.defineProperty(window, "__collieDispatch", { writable: false, configurable: false, value: async (id, name, args) => {
        let m;
        try {
          if (!handler) throw new Error("the page registered no collie.onCommand handler");
          const value = json(await handler(name, args));
          if (value.length > 1048576) throw new Error("resultado maior que 1 MiB");   // before it crosses (Swift caps the bytes again)
          m = { op: "result", id, ok: true, value };
        } catch (e) {
          m = { op: "result", id, ok: false, value: String((e && e.message) || e).slice(0, 500) };
        }
        post(m);
      } });
      Object.defineProperty(window, "__collieTheme", { writable: false, configurable: false, value: (t) => {
        theme = t; applyTheme(); window.dispatchEvent(new CustomEvent("collie-theme", { detail: t }));
      } });
      applyTheme();
    })();
    """#
}
