# Network interceptor — Android device setup (spike)

Manual scripts behind "Resultado do spike" in `docs/pages/network-interceptor-viabilidade/`. Backend decided:
**mitmdump as a collied subprocess + JSON addon**. `netsetup.sh` is the reference for `DeviceSetup` in Swift.
Emulators only (`emulator-*`), rootable image (`google_apis` / AOSP). Nothing here is part of the Collie build.

| File | What |
|---|---|
| `mitm.sh` | mitmdump on `127.0.0.1:${PORT:-8899}`, confdir `.mitm/` (CA + key generated there, git-ignored), `http2=false` |
| `flows.py` | addon: one JSON line per flow (`method,url,status,http,alpn,sni`), plus `tls_failed` lines |
| `netsetup.sh attach\|detach\|status <serial> [port] [ca.pem]` | host side: adb root, CA, proxy, reverse; idempotent |
| `netsetup-device.sh inject <hash>\|eject\|status` | device side, run as root from `/data/local/tmp/collie-ca/` |
| `probe/Probe.java` | long-lived `HttpsURLConnection` loop for `app_process` (built with javac + d8) |
| `proxy/` | own SwiftPM package: `spike-hash` (`subject_hash_old`), `spike-nio-size` (NIO size record) |

```sh
./mitm.sh &                         # generates .mitm/mitmproxy-ca-cert.pem on first run
./netsetup.sh attach emulator-5560  # safe to repeat: repairs what is missing
./netsetup.sh status emulator-5560
./netsetup.sh detach emulator-5560  # safe to repeat, and works straight after a reboot
```

## attach — steps, commands, expected output

Order matters: `adb root` restarts adbd, which drops every `adb reverse`, so root comes first and the reverse last.

| # | Step | Command | Expected | Failure → |
|---|---|---|---|---|
| 1 | Guard | serial starts with `emulator-`; `adb -s S get-state` | `device` | refuse |
| 2 | Root | `adb -s S root`, `wait-for-device`, `shell id -u` | `restarting adbd as root` or `adbd is already running as root`; then `0` | `adbd cannot run as root in production builds` (Play Store image) → "image not rootable" |
| 3 | SDK | `shell getprop ro.build.version.sdk` | e.g. `37` (≥34: APEX path) | — |
| 4 | Hash | `openssl x509 -in ca.pem -noout -subject_hash_old` (Swift: MD5 of subject DER, see `proxy/Sources/spike-hash`) | `c8750f0d` for the mitm CA | — |
| 5 | Stage | `shell mkdir -p /data/local/tmp/collie-ca`; push `netsetup-device.sh`; cert-only PEM → `.../<hash>.0` | — | — |
| 6a | System store | device: copy live CAs (APEX on 14+, else `/system/etc/security/cacerts`) + ours; `mount -t tmpfs -o mode=755 collie-ca /system/etc/security/cacerts`; copy back; `chown root:root`, `chmod 644`, `chcon u:object_r:system_file:s0` | `system: mounted 146 CAs` (145 stock + ours) · re-run: `system: present` | `error: tmpfs mount failed` |
| 6b | APEX (14+) | for every process named `*zygote*` and its children: `nsenter --mount=/proc/<pid>/ns/mnt -- mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts`, skipped where `/proc/self/mounts` already has `collie-ca /apex/...` | `apex: 56 bound, 0 already, 0 gone` · re-run: `apex: 0 bound, 58 already, 0 gone` | ≤13: `apex: none (Android ≤13)` |
| 6c | User store (Chrome) | if `/data/misc/user/0/cacerts-added/<hash>.0` is missing: copy, `chown system:system`, `chmod 644`, `chcon u:object_r:misc_user_data_file:s0`; marker `user-added` | `user: added` · re-run: `user: present` · installed by the user before: `user: preexisting (left alone)` | — |
| 7 | Proxy | `shell settings get global http_proxy` → saved to `.../prev-proxy` unless it is already ours; `settings put global http_proxy 127.0.0.1:P` | `proxy: 127.0.0.1:8899 (was null)` | — |
| 8 | Reverse | `adb -s S reverse tcp:P tcp:P`; check `reverse --list` | `reverse: tcp:8899` | `adb reverse did not stick` |
| 9 | Host | `nc -z 127.0.0.1 P` | `host: mitmdump listening on 127.0.0.1:8899` | warning only |

Measured on API 37 (host GPU, 4 cores): attach ~4 s.

## detach — steps

| # | Step | Expected |
|---|---|---|
| 1 | `adb root` (after a reboot adbd is not root) | `root: ...` |
| 2 | Proxy: only if the current value is ours, put back `prev-proxy` (`null`/missing → `:0`; `settings delete` only applies after a reboot) | `proxy: restored :0` · not ours: `proxy: left <value>` |
| 3 | `adb reverse --remove tcp:P` | `reverse: removed` · `reverse: absent` |
| 4 | Device `eject` (only if staged or a `collie-ca` mount exists): unbind APEX in every namespace that has our layer, `umount` the system tmpfs, remove the user-store file only when `user-added` says we added it, `rm -rf` staging | `apex: 38 unbound` `system: unmounted` `user: removed` `ejected` · nothing there: `ca: absent` |

## status / failure modes (seen on API 37)

| Event | What survives | `status` shows | Fix |
|---|---|---|---|
| `adb reconnect`, `adb root`/`unroot` | everything but the reverse | `ORPHAN: http_proxy points at 127.0.0.1:8899 but there is no reverse` | `attach` again (repairs only the reverse) |
| reboot | `http_proxy` (device has **no network**), user-store CA, staging dir; tmpfs, APEX binds and root are gone | `root: no` + `ORPHAN` + `ca: staged` | `attach` (full redo) or `detach` (cleans user store too) |
| new app after attach | inherits zygote's bind | `apex: N/N namespaces` grows | — |

For DeviceSetup: run `status` logic in the device poll; ORPHAN with a live attach → re-run step 8; ORPHAN without one
(daemon restarted) → detach.
