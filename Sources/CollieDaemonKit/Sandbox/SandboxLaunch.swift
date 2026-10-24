import Foundation

/// The files a sandboxed terminal starts with, under `<root>/sandbox/`: `<id>.sb` (its profile, 0600) and `<id>/`
/// (readable inside the sandbox): `bin/` tool shims (R3, R4), `zsh/` startup files, `state/` (the only writable part:
/// shell history).
enum SandboxLaunch {
    static func dir(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("sandbox").appendingPathComponent(id.uuidString) }
    static func profileFile(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("sandbox").appendingPathComponent("\(id.uuidString).sb") }
    static func remove(_ id: UUID, root: URL) {
        try? FileManager.default.removeItem(at: profileFile(id, root: root))
        try? FileManager.default.removeItem(at: dir(id, root: root))
    }

    /// Tools that sandbox themselves, which Seatbelt can't nest (Task 1): their own sandbox goes off, the terminal's stays.
    static let toolShims = ["swift", "swift-build", "swift-test", "swift-run", "swift-package", "xcrun", "xcodebuild"]

    /// Writes the terminal's files and profile; returns the profile's path.
    static func prepare(_ input: SandboxInput, root: URL, collie: URL) throws -> URL {
        let fm = FileManager.default, d = dir(input.terminal, root: root)
        let sandboxDir = root.appendingPathComponent("sandbox")
        for x in [sandboxDir, d, d.appendingPathComponent("bin"), d.appendingPathComponent("zsh"), d.appendingPathComponent("state")] {
            try fm.createDirectory(at: x, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func write(_ text: String, _ to: URL, _ mode: Int) throws {
            try? fm.removeItem(at: to)
            guard fm.createFile(atPath: to.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path])
            }
        }
        let bin = d.appendingPathComponent("bin")
        let shim = toolShim(shims: bin.path)
        for t in toolShims { try write(shim, bin.appendingPathComponent(t), 0o755) }
        try write(openShim(collie: collie.path), bin.appendingPathComponent("open"), 0o755)
        for (name, text) in zshFiles { try write(text, d.appendingPathComponent("zsh").appendingPathComponent(name), 0o644) }
        let profile = profileFile(input.terminal, root: root)
        try write(SandboxProfile.render(input), profile, 0o600)
        return profile
    }

    /// `env` for a sandboxed launch: the shims first on PATH, history in the terminal's own file, and for zsh the
    /// startup files that keep both after the user's own (path_helper in /etc/zprofile would move the shims back).
    /// HOME is the home the profile closes (the same one in production; a fake one in tests).
    static func environment(_ env: [String: String], id: UUID, root: URL, shell: String, home: URL) -> [String: String] {
        var e = env
        e["HOME"] = home.path
        let d = dir(id, root: root), bin = d.appendingPathComponent("bin").path
        e["PATH"] = bin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        e["COLLIE_SHIMS"] = bin
        e["HISTFILE"] = d.appendingPathComponent("state/history").path
        e["COLLIE_HISTFILE"] = e["HISTFILE"]
        e["COLLIE_USAGE_DIR"] = d.appendingPathComponent("state/usage").path   // UsageService.collectSandboxed
        if URL(fileURLWithPath: shell).lastPathComponent == "zsh" {
            if let z = env["ZDOTDIR"], !z.isEmpty { e["COLLIE_USER_ZDOTDIR"] = z }
            e["ZDOTDIR"] = d.appendingPathComponent("zsh").path
        }
        return e
    }

    /// One script for every tool name (`$0`): finds the real tool on PATH past the shims, adds the flag, execs it.
    static func toolShim(shims: String) -> String {
        """
        #!/bin/bash
        # Collie sandbox shim (generated; read-only to the terminal). Seatbelt can't nest: SwiftPM and xcodebuild run
        # with their own sandbox off here. The terminal's sandbox still applies to everything they run.
        shims=\(AgentLaunch.quote(shims))
        name=${0##*/}
        real() { local IFS=: d; for d in $PATH; do [ "$d" = "$shims" ] && continue; [ -x "$d/$1" ] && [ ! -d "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }; done; return 1; }
        has() { local w=$1 a; shift; for a in "$@"; do [ "$a" = "$w" ] && return 0; done; return 1; }
        rewrite() {   # $1 tool, then its args -> out=(args)
          local t=$1; shift; out=("$@")
          case $t in
            swift) case $1 in build|test|run|package) has --disable-sandbox "$@" || out=("$1" --disable-sandbox "${@:2}");; esac;;
            swift-build|swift-test|swift-run|swift-package) has --disable-sandbox "$@" || out=(--disable-sandbox "$@");;
            xcodebuild) has -IDEPackageSupportDisableManifestSandbox=YES "$@" ||
              out=(-IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES "$@");;
          esac
        }
        r=$(real "$name") || { echo "collie: $name not found on PATH" >&2; exit 127; }
        if [ "$name" = xcrun ]; then   # xcrun [options] <tool> args: the tool runs from the toolchain, not through PATH
          pre=()
          while [ $# -gt 0 ]; do case $1 in
            -sdk|--sdk|-toolchain|--toolchain) pre+=("$1" "$2"); shift 2;;
            -*) pre+=("$1"); shift;;
            *) break;;
          esac; done
          [ $# -gt 0 ] || exec "$r" "${pre[@]}"
          t=$1; shift; rewrite "$t" "$@"
          exec "$r" "${pre[@]}" "$t" "${out[@]}"
        fi
        rewrite "$name" "$@"
        exec "$r" "${out[@]}"

        """
    }

    /// `open` → `collie open` (R4): the daemon opens URLs and installed apps, refuses the rest.
    static func openShim(collie: String) -> String {
        """
        #!/bin/bash
        # Collie sandbox shim (generated): /usr/bin/open is closed inside the sandbox; Collie opens http(s)/mailto URLs
        # and installed apps for you (never scripts, executables or documents).
        a=()
        while [ $# -gt 0 ]; do case $1 in
          -a) a+=(--app "$2"); shift 2;;
          *) a+=("$1"); shift;;
        esac; done
        exec \(AgentLaunch.quote(collie)) open "${a[@]}"

        """
    }

    /// ZDOTDIR wrappers: each sources the user's own file (from their ZDOTDIR or HOME, which it is set to meanwhile),
    /// then `_collie_done` (last file of the startup) puts the shims first, the history in `state/`, and ZDOTDIR back.
    static let zshFiles: [(String, String)] = [
        (".zshenv", """
        # Collie: sandboxed terminal startup (generated; read-only to the terminal)
        _collie_zd=$ZDOTDIR
        ZDOTDIR=${COLLIE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
        [[ $ZDOTDIR != "$HOME" ]] && export COLLIE_USER_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=$_collie_zd
        _collie_done() {
          path=($COLLIE_SHIMS ${path:#${(b)COLLIE_SHIMS}})
          [[ -n $COLLIE_HISTFILE ]] && HISTFILE=$COLLIE_HISTFILE
          if [[ -n $COLLIE_USER_ZDOTDIR ]]; then ZDOTDIR=$COLLIE_USER_ZDOTDIR; else unset ZDOTDIR; fi
          unset _collie_zd; unfunction _collie_done
        }
        [[ -o login || -o interactive ]] || _collie_done

        """),
        (".zprofile", """
        ZDOTDIR=${COLLIE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zprofile ]] && source $ZDOTDIR/.zprofile
        ZDOTDIR=$_collie_zd

        """),
        (".zshrc", """
        ZDOTDIR=${COLLIE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zshrc ]] && source $ZDOTDIR/.zshrc
        ZDOTDIR=$_collie_zd
        (( $+functions[_collie_done] )) && _collie_done

        """),
        (".zlogin", """
        ZDOTDIR=${COLLIE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zlogin ]] && source $ZDOTDIR/.zlogin
        ZDOTDIR=$_collie_zd
        (( $+functions[_collie_done] )) && _collie_done

        """),
    ]
}
