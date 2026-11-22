# Android device helper

`helper/`: the accessibility service the daemon talks to (spec: `docs/superpowers/specs/2026-11-22-device-helper-design.md`).
Build: `scripts/build-device-helper.sh` writes the committed `Resources/collie-helper.apk` (needs the Android SDK and a JDK).
## Assinatura

`helper.jks` (senha `android`) é uma chave DEBUG pública, commitada: sem `COLLIE_HELPER_KEYSTORE` o build usa ela e avisa em
stderr. Para distribuir, use uma chave privada fora do repositório:

1. `scripts/build-device-helper.sh --genkey ~/.collie/collie-helper.p12` (RSA 4096, 36500 dias, permissão 0600; recusa
   caminho dentro do repo e não sobrescreve um existente). A senha vem de `COLLIE_HELPER_STOREPASS` ou é digitada no keytool.
2. Guarde a senha no Keychain: `security add-generic-password -s collie-helper-keystore -a "$USER" -w` (pede a senha).
3. `COLLIE_HELPER_KEYSTORE=~/.collie/collie-helper.p12 scripts/build-device-helper.sh --release` (alias em
   `COLLIE_HELPER_KEY_ALIAS`, padrão `collie-helper`; senha de `COLLIE_HELPER_STOREPASS` ou do Keychain). `--release` recusa a
   chave debug. A senha nunca vai por argumento nem para o log.

Atenção: trocar a chave quebra o `install -r` em aparelhos que já têm o helper assinado com a debug
(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`); é preciso desinstalar antes. A K1b trata isso no daemon.
Teste sem SDK: `scripts/test-build-device-helper.sh`.

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
  when the active window has no root.
- Blindness after toggling the service (investigated 2026-11-22, emulator API 37): toggling by `settings put secure` and probing once,
  late (3 s), alternates healthy/blind (`getWindows()` empty, the answering instance is the previous one). A client that queries
  EARLY (every 250-300 ms from the moment of enabling) always finds the service healthy in 270-660 ms; from verified blind states the
  daemon-style rebind (delete + put, no pause), `am force-stop com.collie.helper` + enable, and `install -r` + enable all healed 12/12
  when polling started at once. An in-process warm-up (`getWindows()` at 0, 150, 400, 900 ms) did NOT help, `setServiceInfo` neither.
  So: poll `dump` right after enabling instead of waiting first; escalate rebind, then force-stop, then install -r, then fall back.
- A path from `dump` goes stale when the screen changes: `click`/`scroll` answer `node gone`; re-read and retry.

## Regressão da cegueira

`stress-toggle.sh <serial> [rodadas=6]` reproduz a cegueira descrita acima: em cada rodada desliga e liga o serviço por
`settings put secure enabled_accessibility_services` (acrescenta e tira só o helper; a lista original e `accessibility_enabled`
voltam ao sair, também em erro ou Ctrl-C) e mede os nós do `dump` com `helper-probe.py` num `adb forward` de porta livre:

- A) sonda tardia, 3 s depois de ligar: **esperado alternar** saudável/cega (é o defeito do Android, não do helper);
- B) sondagem a cada 300 ms desde o instante de ligar: **esperado sempre saudável, em < 1 s** (270-660 ms no emulador API 37).

Rodar com o helper instalado e o aparelho na tela inicial: `Helpers/android-device/stress-toggle.sh emulator-5554 6`. Uma
linha por rodada e o resumo (`A cega em N/6 rodadas · B mediana X ms`). B cega ou acima de 1 s é regressão: o daemon
depende dela. Sem adb ou sem aparelho sai com 2. Teste sem aparelho (adb falso): `scripts/test-stress-toggle.sh`.

Measured 2026-11-22 with `stress-toggle.sh emulator-5554 6` (emulator API 37, helper v3, installed daemon): A (one late probe, 3 s after enabling) blind
in 6 of 6 rounds; B (probing every 300 ms from the moment of enabling) healthy in 14 to 26 ms in all 6. The first version of the script compared the
short service name (`.HelperService`) with the long one Android stores, so it never took the helper out of the list and always read "healthy": a script
check that cannot reach the device (the loop's) cannot catch that; run it by hand after changing it.
