# Android device helper

`helper/`: the accessibility service the daemon talks to (spec: `docs/superpowers/specs/2026-11-22-device-helper-design.md`).
Build: `scripts/build-device-helper.sh` writes the committed `Resources/collie-helper.apk` (needs the Android SDK and a JDK).
`fixture/`: a test app with screens whose accessibility tree is poor (for the OCR fallback corpus).
`helper-probe.py`: forwards `localabstract:collie-helper` and measures `dump`; a manual check on an emulator.

Protocol (one JSON per line, `id` echoed): `hello`, `dump` → `{nodes:[{p,text,desc,id,cls,b,clk,sel,chk,en,foc,scr,pw}], root}`,
`tap {x,y}`, `swipe {x1,y1,x2,y2,ms}`, `click {path}`, `text {value}`, `scroll {path,dir}`, `global {action}`, `subscribe`
(pushes `{ev:"window"|"content", t}`, debounced 100 ms). Only uid 2000 (shell) and 0 (root) may connect; password text is masked.

Measured on an emulator (API 37): `dump` 1 to 10 ms warm, `click` by action 2 ms, `tap` ~80 ms (the 50 ms stroke plus completion),
`global` 2 ms.

Operational notes for the daemon (H2):
- After `install` the service restarts; enable it (`settings put secure enabled_accessibility_services`, appending, plus
  `accessibility_enabled 1`) and confirm with a `dump` that returns `root: true` and nodes before trusting it. Right after
  a fresh install and enable the first `dump` can come back with no nodes.
- v2 (2026-11-22): the socket name is process-wide, so a service toggled off and on used to leave the OLD instance answering
  with `root:false` (0 nodes) forever. The owner is now closed on unbind and replaced on connect (`onServiceConnected`).
- v3 (2026-11-22): each instance closes only its own socket and connections (Android can deliver the old instance's `onUnbind` after the
  new one's `onServiceConnected`, which used to close the NEW socket: `Connection refused`); `dump` falls back to the application windows
  when the active window has no root. OPEN: after toggling the service off and on by `settings put secure` the helper answers blind
  (`getWindows()` empty, 0 nodes) on every other toggle (the answering instance is the previous one, disconnected from the system);
  `setServiceInfo` did not wake it. A manual toggle or `install -r` heals it; the daemon's retry (H7) does not rebind with a pause.
- A path from `dump` goes stale when the screen changes: `click`/`scroll` answer `node gone`; re-read and retry.
