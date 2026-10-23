import Foundation
import CollieProtocol
import WebKit

/// The page-side half of the Browser plug-in (written for Collie, clean-room): user scripts injected at document start.
/// `script` runs in the `collie` content world (it shares the DOM with the page, not its JS globals: page JS can't see or
/// call `window.__collie`); `consoleScript` runs in the page world and forwards `console.*` / uncaught errors to the
/// `collieConsole` message handler. Every `__collie` call returns a JSON string; failures are
/// `{"error":{"code","message"}}` with a `ProtocolError` code. Refs live in the DOM as `data-collie-ref="eN"`.
enum BrowserAutomation {
    static let consoleHandler = "collieConsole"
    @MainActor static var world: WKContentWorld { .world(name: "collie") }   // same name, same world

    static let script = #"""
    (() => {
      if (window.__collie) return;
      const INTERACTIVE = 'a,button,input,select,textarea,[role],[onclick],[contenteditable]';
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'IFRAME']);
      // roles whose text is their name: their text children are not listed again
      const LEAF = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'option',
                            'menuitem', 'tab', 'slider', 'switch', 'spinbutton']);
      const refs = new Map();   // ref -> WeakRef(element); also finds elements inside open shadow roots
      let next = 0;
      const fail = (code, message) => ({ error: { code, message } });
      const missing = ref => fail('notFound', 'ref ' + ref + ' not found (take a new snapshot)');
      const clip = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
      const shown = el => el.checkVisibility ? el.checkVisibility({ visibilityProperty: true }) : el.getClientRects().length > 0;
      const fields = [HTMLInputElement, HTMLTextAreaElement, HTMLSelectElement];
      const field = el => fields.find(c => el instanceof c);
      // the prototype's setter: frameworks that shadow `value` on the instance still see the change
      const setValue = (el, v) => Object.getOwnPropertyDescriptor(field(el).prototype, 'value').set.call(el, v);

      function role(el) {
        const r = el.getAttribute('role');
        if (r) return r.split(/\s+/)[0];
        switch (el.tagName) {
          case 'A': return 'link';
          case 'BUTTON': return 'button';
          case 'SELECT': return 'combobox';
          case 'TEXTAREA': return 'textbox';
          case 'INPUT': return ({ checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
                                  image: 'button', range: 'slider', search: 'searchbox', number: 'spinbutton' })[el.type] || 'textbox';
        }
        return el.isContentEditable ? 'textbox' : 'generic';
      }
      function name(el, r, labels) {
        const aria = el.getAttribute('aria-label');
        if (aria) return aria;
        const by = el.getAttribute('aria-labelledby');
        if (by) {
          const s = by.split(/\s+/).map(id => (document.getElementById(id) || {}).textContent || '').join(' ');
          if (s.trim()) return s;
        }
        const label = labels && labels.get(el);
        if (label) return label;
        if (el instanceof HTMLInputElement && ['button', 'submit', 'reset'].includes(el.type)) return el.value;
        const attr = el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('placeholder');
        if (attr) return attr;
        return LEAF.has(r) && !field(el) ? el.innerText || el.textContent : '';
      }
      function find(ref) {
        const w = refs.get(ref), el = w && w.deref();
        if (el && el.isConnected) return el;
        return document.querySelector('[data-collie-ref="' + CSS.escape(String(ref)) + '"]');
      }

      // `maxChars` bounds the walk; the host does the exact byte cut.
      function snapshot(maxChars) {
        const out = [], seen = new Set(), fresh = [];
        // `el.labels` scans the document on every call: one pass over the labels instead
        const labels = new Map();
        for (const l of document.querySelectorAll('label')) {
          if (l.control) labels.set(l.control, (labels.has(l.control) ? labels.get(l.control) + ' ' : '') + l.textContent);
        }
        let size = 0, truncated = false;
        const push = (depth, line) => {
          size += depth * 2 + line.length + 1;
          if (size > maxChars) { truncated = true; return; }
          out.push('  '.repeat(depth) + line);
        };
        const walk = (node, depth, quiet) => {
          for (let c = node.firstChild; c && !truncated; c = c.nextSibling) {
            if (c.nodeType === 3) {
              const t = quiet ? '' : clip(c.data, 200);
              if (t) push(depth, '- text ' + JSON.stringify(t));
              continue;
            }
            if (c.nodeType !== 1 || SKIP.has(c.tagName) || !shown(c)) continue;
            let d = depth, q = quiet;
            if (c.matches(INTERACTIVE)) {
              let ref = c.getAttribute('data-collie-ref');
              if (!ref || seen.has(ref)) { ref = 'e' + (++next); fresh.push([c, ref]); }
              seen.add(ref); refs.set(ref, new WeakRef(c));
              const r = role(c);
              let line = '- ' + r + ' ' + JSON.stringify(clip(name(c, r, labels), 80));
              if (field(c) && c.value && !['button', 'submit', 'reset'].includes(c.type)) line += ' value=' + JSON.stringify(clip(c.value, 80));
              if (c.checked) line += ' checked';
              if (c.disabled) line += ' disabled';
              push(depth, line + ' [ref=' + ref + ']');
              d = depth + 1; q = quiet || LEAF.has(r);
            } else if (/^H[1-6]$/.test(c.tagName)) {
              push(depth, '- heading ' + JSON.stringify(clip(c.innerText, 120)));
              continue;
            }
            if (c.shadowRoot) walk(c.shadowRoot, d, q);
            walk(c, d, q);
          }
        };
        if (document.body) walk(document.body, 0, false);
        // after the walk: an attribute change mid-walk would invalidate style for every later visibility check
        for (const [el, ref] of fresh) el.setAttribute('data-collie-ref', ref);
        return { output: out.join('\n'), truncated };
      }

      function text(maxChars) {
        const t = document.body ? document.body.innerText : '';
        return { output: t.slice(0, maxChars), truncated: t.length > maxChars };
      }

      function click(ref) {
        const el = find(ref);
        if (!el) return missing(ref);
        el.scrollIntoView({ block: 'center', inline: 'center' });
        const b = el.getBoundingClientRect();
        const at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                     clientX: b.left + b.width / 2, clientY: b.top + b.height / 2 };
        const ptr = Object.assign({ pointerId: 1, isPrimary: true, pointerType: 'mouse' }, at);
        el.dispatchEvent(new PointerEvent('pointerdown', ptr));
        el.dispatchEvent(new MouseEvent('mousedown', Object.assign({ buttons: 1 }, at)));
        if (el.focus) el.focus({ preventScroll: true });
        el.dispatchEvent(new PointerEvent('pointerup', ptr));
        el.dispatchEvent(new MouseEvent('mouseup', at));
        el.click();
        return { ok: true };
      }

      function fill(ref, value) {
        const el = find(ref);
        if (!el) return missing(ref);
        if (el.focus) el.focus({ preventScroll: true });
        if (field(el)) setValue(el, value);
        else if (el.isContentEditable) el.textContent = value;
        else return fail('invalidArgs', 'ref ' + ref + ' is not a text field');
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true };
      }

      function insert(el, s) {
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
          const a = el.selectionStart == null ? el.value.length : el.selectionStart;
          const b = el.selectionEnd == null ? a : el.selectionEnd;
          setValue(el, el.value.slice(0, a) + s + el.value.slice(b));
          try { el.setSelectionRange(a + s.length, a + s.length); } catch (_) {}
          el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: s }));
        } else if (el.isContentEditable) {
          document.execCommand('insertText', false, s);   // fires its own input event
        }
      }
      const focused = () => {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        return el && el !== document.body ? el : null;
      };
      const keyInit = k => ({ key: k, code: k.length === 1 ? '' : k, bubbles: true, cancelable: true, composed: true,
                              keyCode: CODES[k] || (k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0) });
      const CODES = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ' ': 32, ArrowLeft: 37, ArrowUp: 38,
                      ArrowRight: 39, ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34 };

      function type(s) {
        const el = focused();
        if (!el) return fail('invalidArgs', 'no focused element (click or fill one first)');
        for (const ch of String(s)) {
          const k = keyInit(ch);
          if (el.dispatchEvent(new KeyboardEvent('keydown', k)) && el.dispatchEvent(new KeyboardEvent('keypress', k))) insert(el, ch);
          el.dispatchEvent(new KeyboardEvent('keyup', k));
        }
        return { ok: true };
      }

      function key(k) {
        const el = focused() || document.body;
        const init = keyInit(k);
        let go = el.dispatchEvent(new KeyboardEvent('keydown', init));
        if (go && (k === 'Enter' || k.length === 1)) go = el.dispatchEvent(new KeyboardEvent('keypress', init));
        if (go) {
          if (k === 'Enter') {
            if (el instanceof HTMLInputElement && el.form) el.form.requestSubmit();
            else if (el instanceof HTMLButtonElement || el instanceof HTMLAnchorElement) el.click();
          } else if (k === 'Tab') {
            const all = Array.from(document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]'))
              .filter(e => e.tabIndex >= 0 && !e.disabled && shown(e));
            const n = all[(all.indexOf(el) + 1) % all.length];
            if (n) n.focus();
          } else if (k === 'Backspace' && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) {
            const a = el.selectionStart == null ? el.value.length : el.selectionStart;
            const b = el.selectionEnd == null ? a : el.selectionEnd;
            const from = a === b ? Math.max(a - 1, 0) : a;
            setValue(el, el.value.slice(0, from) + el.value.slice(b));
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'deleteContentBackward' }));
          } else if (k.length === 1) {
            insert(el, k);
          }
        }
        el.dispatchEvent(new KeyboardEvent('keyup', init));
        return { ok: true };
      }

      function scroll(ref, dy) {
        if (ref) {
          const el = find(ref);
          if (!el) return missing(ref);
          el.scrollIntoView({ block: 'center', inline: 'center' });
        } else {
          window.scrollBy(0, dy);
        }
        return { scrollY: Math.round(window.scrollY) };
      }

      // MutationObserver for prompt detection, polling for changes it can't see (layout, visibility).
      function wait(text, selector, ms) {
        const ok = () => selector ? !!document.querySelector(selector)
                                  : !!document.body && document.body.innerText.includes(text);
        try { if (ok()) return { found: true }; }
        catch (e) { return fail('invalidArgs', String(e && e.message || e)); }
        return new Promise(resolve => {
          let done = false;
          const finish = v => {
            if (done) return;
            done = true; mo.disconnect(); clearInterval(poll); clearTimeout(limit); resolve(v);
          };
          const check = () => { try { if (ok()) finish({ found: true }); } catch (_) {} };
          const mo = new MutationObserver(check);
          mo.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
          const poll = setInterval(check, 100);
          const limit = setTimeout(() => finish({ found: false }), ms);
        });
      }

      const api = { snapshot, text, click, fill, type, key, scroll, wait };
      Object.defineProperty(window, '__collie', { value: Object.freeze(api), configurable: false, writable: false, enumerable: false });
    })();
    """#

    /// Page world (it must wrap the page's own `console`): forwards console lines and uncaught errors to `collieConsole`.
    static let consoleScript = #"""
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.collieConsole;
      if (!handler) return;
      const fmt = a => {
        if (typeof a === 'string') return a;
        if (a instanceof Error) return a.stack ? a.message + '\n' + a.stack : String(a);
        try { const s = JSON.stringify(a); return s === undefined ? String(a) : s; } catch (_) { return String(a); }
      };
      const post = (level, args) => {
        try { handler.postMessage({ level, text: Array.from(args, fmt).join(' ').slice(0, 2000) }); } catch (_) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const orig = console[level];
        console[level] = function (...a) { post(level, a); return orig.apply(this, a); };
      }
      addEventListener('error', e => post('error', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]));
      addEventListener('unhandledrejection', e => post('error', ['Unhandled rejection: ' + fmt(e.reason)]));
    })();
    """#

    /// Page world, all frames: emulates `prefers-reduced-motion` (`reduce` | `no-preference` | `system` = off). Idempotent:
    /// run again on a page that has it, it only switches the mode. Queries naming the feature (matchMedia, CSSOM rules,
    /// `<link media>`, `<style media>`) are rewritten to an always-true / always-false media feature.
    /// ponytail: CSSOM rewrite, no public WebKit override; cross-origin sheets reported, not covered
    static func motionScript(_ mode: String) -> String {
        #"""
        (() => {
          const mode = '__MODE__';
          let m = window.__collieMotion;
          if (m) return m.set(mode);
          const RM = /\(\s*prefers-reduced-motion\s*(?::\s*(reduce|no-preference)\s*)?\)/gi;
          const orig = new WeakMap();   // node / MediaList -> its original text
          let cur = 'system', uncovered = 0;
          const rewrite = t => cur === 'system' ? t : t.replace(RM, (_, v) => ((v || 'reduce').toLowerCase() === cur) ? '(width >= 0px)' : '(width < 0px)');
          const media = (target, get, set) => {
            const text = orig.has(target) ? orig.get(target) : get();
            if (!orig.has(target)) { if (!/prefers-reduced-motion/i.test(text)) return; orig.set(target, text); }
            const next = rewrite(text); if (next !== get()) set(next);
          };
          const rules = (list) => {
            for (const r of list) {
              if (r.media) media(r, () => r.media.mediaText, v => { r.media.mediaText = v; });
              if (r.styleSheet) sheet(r.styleSheet);
              if (r.cssRules) rules(r.cssRules);
            }
          };
          const sheet = s => {
            const n = s.ownerNode;
            if (n && n.getAttribute && n.hasAttribute('media')) media(n, () => n.getAttribute('media'), v => n.setAttribute('media', v));
            let list; try { list = s.cssRules; } catch (_) { uncovered++; return; }
            rules(list);
          };
          const apply = () => { uncovered = 0; for (const s of Array.from(document.styleSheets)) sheet(s); };
          let queued = false;
          const later = () => { if (queued) return; queued = true; queueMicrotask(() => { queued = false; apply(); }); };
          const mm = window.matchMedia;
          window.matchMedia = function (q) { return mm.call(this, rewrite(String(q))); };
          document.addEventListener('DOMContentLoaded', later);
          document.addEventListener('load', later, true);
          new MutationObserver(later).observe(document, { childList: true, subtree: true });
          m = { set(v) { cur = v; apply(); }, uncovered: () => uncovered };
          Object.defineProperty(window, '__collieMotion', { value: m });
          m.set(mode);
        })();
        """#.replacingOccurrences(of: "__MODE__", with: mode)
    }

    /// Calls `window.__collie.<fn>(...args)` in the page and decodes its JSON reply; `{"error":…}` becomes a ProtocolError.
    @MainActor static func call(_ web: WKWebView, _ fn: String, _ args: [Any]) async throws(ProtocolError) -> [String: JSONValue] {
        let raw: Any?
        do {
            raw = try await web.callAsyncJavaScript(
                "if (!window.__collie) throw new Error('page not ready'); return JSON.stringify(await window.__collie[fn](...args));",
                arguments: ["fn": fn, "args": args], in: nil, contentWorld: world)
        } catch {
            throw ProtocolError(code: .unavailable, message: "browser: \(jsMessage(error))")
        }
        guard let s = raw as? String,
              case .object(let o)? = await offMain({ try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }) else {
            throw ProtocolError(code: .internal, message: "browser: bad automation reply")
        }
        if case .object(let e)? = o["error"], case .string(let c)? = e["code"], case .string(let m)? = e["message"] {
            throw ProtocolError(code: ErrorCode(rawValue: c) ?? .internal, message: m)
        }
        return o
    }

    static func jsMessage(_ error: any Error) -> String {
        let ns = error as NSError
        return ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns.localizedDescription
    }

    /// `Any` from WebKit (JS result) → JSON; what JSON can't hold is described.
    static func json(_ v: Any?) -> JSONValue {
        switch v {
        case nil, is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return n.doubleValue.isFinite ? .number(n.doubleValue) : .string(String(describing: n.doubleValue))   // NaN, ±inf
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(json))
        case let d as [String: Any]: return .object(d.mapValues(json))
        case let date as Date: return .string(ISO8601DateFormatter().string(from: date))
        case let x?: return .string(String(describing: x))
        }
    }

    /// The result with its string `key` cut so the whole encodes within `cap` bytes; marks `truncated`.
    static func bounded(_ result: [String: JSONValue], key: String, cap: Int = resultCap) -> JSONValue {
        var r = result
        guard case .string(var s)? = r[key] else { return .object(r) }
        while encodedSize(.object(r)) > cap, !s.isEmpty {
            let over = encodedSize(.object(r)) - cap
            // escaping can make a byte cost up to 6: cut at least the overflow, in UTF-8 bytes, on a character boundary
            let keep = max(s.utf8.count - max(over, 64), 0)
            s = String(s[..<s.utf8.index(s.utf8.startIndex, offsetBy: keep)])   // rounded down to a scalar boundary
            r[key] = .string(s); r["truncated"] = .bool(true)
        }
        return .object(r)
    }

    /// Below the daemon's 1 MiB reply cap, leaving room for the reply frame around the result.
    static let resultCap = (1 << 20) - 4096

    static func encodedSize(_ v: JSONValue) -> Int { (try? JSONEncoder().encode(v).count) ?? Int.max }

    /// Large-result work (JSON encode/decode, PNG) off the main actor.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// `bounded`, off the main actor.
    static func boundedOffMain(_ result: [String: JSONValue], key: String) async -> JSONValue {
        await offMain { bounded(result, key: key) }
    }
}
