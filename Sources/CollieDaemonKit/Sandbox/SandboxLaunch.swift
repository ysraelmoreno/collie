import Foundation

/// The files a sandboxed terminal starts with, under `<root>/sandbox/`: `<id>.sb` (its profile, 0600) and `<id>/`
/// (readable inside the sandbox): `bin/` tool shims (R3, R4), `zsh/` startup files, `files/` (`handOver`), `state/` (the only
/// writable part: shell history).
enum SandboxLaunch {
    static func dir(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("sandbox").appendingPathComponent(id.uuidString) }
    static func profileFile(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("sandbox").appendingPathComponent("\(id.uuidString).sb") }
    /// Files the daemon made for the terminal (`handOver`): readable inside its sandbox (under `dir`), not writable.
    static func filesDir(_ id: UUID, root: URL) -> URL { dir(id, root: root).appendingPathComponent("files") }
    static let filesKept = 100

    /// The dirs output-file commands write to (R5): screenshots (design, browser, device: `screens/`), external plug-ins'
    /// files (`plugins-out/<id>/`, written by the app's host), design exports, and
    /// an html export's artifact folder (R4). Never `admin.token`, `sandbox/` or anything else under the root.
    /// ponytail: a new output command must add its dir here.
    static func isOutput(_ realPath: String, root: URL) -> Bool {
        let r = SignedAppCheck.realPath(root) + "/"
        guard realPath.hasPrefix(r) else { return false }
        let rel = realPath.dropFirst(r.count).split(separator: "/")
        guard !rel.contains(where: { $0.hasPrefix(".") }) else { return false }
        if rel.count == 2, rel[0] == "screens" { return true }
        if rel.count == 3, rel[0] == "plugins-out" { return true }   // the router first checks it is the calling plug-in's (vetPluginOutput)
        if rel.count >= 4, rel[0] == "design", rel[1] == "exports" { return true }
        return rel.count >= 3 && rel[0] == "artifacts"   // a file in an artifact's folder, not artifacts.json
    }

    /// `src` cloned into the terminal's `files/` (0700, made if missing) under its own name (`-2`, `-3`… on a collision),
    /// the dir pruned to the newest `filesKept`; returns the clone. `src` must be a regular file, not a symlink, whose
    /// resolved path is an output (`isOutput`): it is opened once (O_NOFOLLOW) and cloned from that descriptor.
    static func handOver(_ src: URL, terminal: UUID, root: URL) throws -> URL {
        let refused = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: src.path])
        let fd = open(src.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refused }
        defer { close(fd) }
        var st = stat(), buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, fcntl(fd, F_GETPATH, &buf) == 0,
              isOutput(String(cString: buf), root: root) else { throw refused }
        let fm = FileManager.default, dir = filesDir(terminal, root: root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stem = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
        var out = dir.appendingPathComponent(src.lastPathComponent), n = 1
        while true {   // EEXIST: the name is taken, try the next suffix (never overwrites)
            if fclonefileat(fd, AT_FDCWD, out.path, 0) == 0 { break }
            if errno == ENOTSUP || errno == EXDEV {   // another volume: a plain copy
                let o = open(out.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if o >= 0 {
                    defer { close(o) }
                    guard fcopyfile(fd, o, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { try? fm.removeItem(at: out); throw refused }
                    break
                }
            }
            guard errno == EEXIST, n < 10_000 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: out.path]) }
            n += 1
            out = dir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)   // a clone keeps the source's: prune by hand-over time
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = all.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (u, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(filesKept) where u.lastPathComponent != out.lastPathComponent {
            try? fm.removeItem(at: u)
        }
        return out
    }

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
        for x in [sandboxDir, d, d.appendingPathComponent("bin"), d.appendingPathComponent("zsh"), d.appendingPathComponent("state"), filesDir(input.terminal, root: root)] {
            try fm.createDirectory(at: x, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func write(_ text: String, _ to: URL, _ mode: Int) throws {
            try? fm.removeItem(at: to)
            guard fm.createFile(atPath: to.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path])
            }
        }
        makeHomeDirs(EssentialPaths.agentHome(input.agent, command: input.command), in: input.home)
        let bin = d.appendingPathComponent("bin")
        let shim = toolShim(shims: bin.path)
        for t in toolShims { try write(shim, bin.appendingPathComponent(t), 0o755) }
        try write(openShim(collie: collie.path), bin.appendingPathComponent("open"), 0o755)
        for (name, text) in zshFiles { try write(text, d.appendingPathComponent("zsh").appendingPathComponent(name), 0o644) }
        let profile = profileFile(input.terminal, root: root)
        try write(SandboxProfile.render(input), profile, 0o600)
        return profile
    }

    /// Each missing `rels` component under `home` made a real dir (0700), one `mkdir` at a time: `mkdir` never follows a
    /// symlink, and a component that exists but isn't a directory (a planted link) stops that path.
    static func makeHomeDirs(_ rels: [String], in home: URL) {
        let base = SignedAppCheck.realPath(home)
        for rel in rels {
            var p = base, st = stat()
            for c in rel.split(separator: "/") {
                p += "/" + c
                if lstat(p, &st) == 0 { if (st.st_mode & S_IFMT) != S_IFDIR { break } else { continue } }
                guard mkdir(p, 0o700) == 0 else { break }
            }
        }
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
        (".zlogout", """
        _collie_zd=$ZDOTDIR
        ZDOTDIR=${COLLIE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zlogout ]] && source $ZDOTDIR/.zlogout
        ZDOTDIR=$_collie_zd

        """),
        (".zlogin", """
        ZDOTDIR=${COLLIE_USER_ZDOTDIR:-$HOME}
        [[ -r $ZDOTDIR/.zlogin ]] && source $ZDOTDIR/.zlogin
        ZDOTDIR=$_collie_zd
        (( $+functions[_collie_done] )) && _collie_done

        """),
    ]
}
