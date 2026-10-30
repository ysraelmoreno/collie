# Network interceptor — phase 0 spike

Manual scripts behind the "Resultado do spike" section of `docs/pages/network-interceptor-viabilidade/`.
Emulators only (`emulator-*`), rootable image (`google_apis`). Nothing here is part of the Collie build.

| File | What |
|---|---|
| `mitm.sh` | mitmdump on `127.0.0.1:${PORT:-8899}`, confdir `.mitm/` (CA + key generated there, git-ignored), `http2=false` |
| `flows.py` | mitmdump addon: one JSON line per flow (`method,url,status,http,alpn,sni`), plus `tls_failed` lines |
| `ca.sh <serial> inject <ca.pem> \| eject` | pushes `ca-device.sh` and runs it as root |
| `ca-device.sh` | on device: tmpfs over `/system/etc/security/cacerts`; on 14+ bind over the APEX conscrypt dir in zygote's and every app's mount namespace; `eject` unmounts only those layers |
| `proxy-on.sh` / `proxy-off.sh <serial> [port]` | `adb reverse` + `settings put global http_proxy`; saves and restores the previous value |
| `probe/Probe.java` | long-lived `HttpsURLConnection` loop for `app_process` (does a running process pick up a CA?) |
| `proxy/` | own SwiftPM package: `spike-hash` (`subject_hash_old`), `spike-nio-size` (NIO size probe) |

```sh
./mitm.sh &                                   # 1. proxy
./ca.sh emulator-5560 inject .mitm/mitmproxy-ca-cert.pem
./proxy-on.sh emulator-5560 8899
# ... test ...
./ca.sh emulator-5560 eject && ./proxy-off.sh emulator-5560 8899   # always undo
```

Chrome ignores the system store (Chrome Root Store): it needs the CA in the user store too,
`/data/misc/user/0/cacerts-added/<hash>.0` (done by hand in the spike, not by `ca.sh`).
