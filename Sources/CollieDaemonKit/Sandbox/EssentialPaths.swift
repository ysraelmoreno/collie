import Foundation
import CollieCore

/// What tools need under the user's home inside a sandboxed terminal (Task 1's list, narrowed per R5). Entries are
/// home-relative: a plain entry is that path and everything below it; a trailing `*` matches any name with that prefix
/// (and below). Outside the home, reads stay open (`/usr`, `/opt/homebrew`, `/Applications/Xcode.app`, …): accepted,
/// the rules there are about writes. A missing tool's entry costs nothing.
enum EssentialPaths {
    /// Read-only (writes come only from `homeWrites`).
    static let homeReads = [
        // shells
        ".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zcompdump*", ".oh-my-zsh", ".p10k.zsh", ".config/zsh",
        ".bashrc", ".bash_profile", ".profile", ".inputrc", ".config/starship.toml",
        ".CFUserTextEncoding", "Library/Preferences/.GlobalPreferences.plist", "Library/Preferences/com.apple.dt.*",
        // git (ssh: only known_hosts/config/*.pub, see `SandboxProfile`)
        ".gitconfig", ".gitignore_global", ".config/git",
        // node, python, ruby, rust, go, bun, deno
        ".nvm", ".npm", ".npmrc", ".yarnrc", ".yarn", ".pnpm-store", ".bun", ".deno", ".volta", ".fnm",
        ".pyenv", ".cache", ".rbenv", ".gem", ".cargo", ".rustup", "go", ".local/bin", ".local/share/pnpm",
        // swift / xcode
        ".swiftpm", ".swiftly", "Library/org.swift.swiftpm", "Library/Developer",
        "Library/Caches/org.swift.swiftpm", "Library/Caches/com.apple.dt.*", "Library/Caches/CocoaPods",
        "Library/Caches/Homebrew", "Library/Caches/claude-cli-nodejs", "Library/Caches/node-gyp", "Library/Caches/pip",
        "Library/Caches/pnpm", "Library/Caches/Yarn", "Library/Caches/ms-playwright", "Library/Caches/bun",
        "Library/Caches/typescript", "Library/Caches/go-build", "Library/Caches/deno", "Library/Caches/com.apple.python",
        "Library/Caches/org.carthage.CarthageKit",
        // agents: binaries, state and (read-only) config
        ".local/share/claude", ".local/state/claude", ".claude",
        ".codex", ".cursor", ".config/cursor",
        // R12: Claude reads its login from the Keychain (the Security framework opens the keychain file in-process)
        "Library/Keychains",
    ]

    /// Writable. Never config another unsandboxed program executes from (rc files, `~/.claude/settings.json`, hooks,
    /// `~/.codex/config.toml`, SwiftPM `configuration/` mirrors and registries, Xcode `UserData`/`Templates`/`Toolchains`).
    /// ponytail: shared caches stay writable (an agent could poison a cache another build reads): accepted, documented.
    static let homeWrites = [
        ".npm", ".cache", ".yarn", ".pnpm-store", ".bun/install/cache", ".cargo/registry", ".cargo/git", "go/pkg",
        ".gem/ruby", ".swiftpm/cache", ".swiftpm/security", "Library/org.swift.swiftpm/cache",
        "Library/org.swift.swiftpm/security",
        "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Library/Developer/Xcode/Products",
        "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/CoreSimulator", "Library/Developer/XCTestDevices",
        "Library/Caches/org.swift.swiftpm", "Library/Caches/com.apple.dt.*", "Library/Caches/CocoaPods",
        "Library/Caches/Homebrew", "Library/Caches/claude-cli-nodejs", "Library/Caches/node-gyp", "Library/Caches/pip",
        "Library/Caches/pnpm", "Library/Caches/Yarn", "Library/Caches/ms-playwright", "Library/Caches/bun",
        "Library/Caches/typescript", "Library/Caches/go-build", "Library/Caches/deno", "Library/Caches/com.apple.python",
        "Library/Caches/org.carthage.CarthageKit",
        // R12 (user decision): the keychain files, so tokens refresh (any agent can read keychain items: accepted)
        "Library/Keychains",
        // R13 (user decision): ~/.claude.json (+ its atomic-write temp and backup); an agent can plant a global MCP server: accepted
        ".claude.json*",
        // agent state (sessions, history, todos); their config stays read-only. A trailing `/`: the dir's children only,
        // never the dir itself (no rename, unlink or symlink swap, R18). Claude's shell-snapshots and session-env stay
        // read-only: other (unsandboxed) Claude sessions source them (R18)
        ".claude/history.jsonl", ".claude/.credentials.json*", ".codex/history.jsonl", ".codex/auth.json", ".codex/version.json",
    ] + agentStateDirs.values.flatMap { $0 }.map { $0 + "/" }

    /// Each agent's state dirs, writable to their children (R18); the daemon makes the terminal's own agent's ones
    /// (with its home dir) before launch (R19).
    static let agentStateDirs: [String: [String]] = [
        ".claude": [".claude/projects", ".claude/todos", ".claude/statsig", ".claude/ide", ".claude/debug",
                    ".claude/file-history", ".claude/plans", ".claude/paste-cache", ".claude/logs", ".claude/telemetry",
                    ".local/state/claude"],
        ".codex": [".codex/sessions", ".codex/archived_sessions", ".codex/log", ".codex/logs", ".codex/tmp"],
        ".cursor": [".cursor/chats", ".cursor/projects"],
    ]

    /// R19: the home dirs the daemon makes for a terminal: only its agent's (none for a shell). A missing one is made
    /// a real directory, never through a symlink (I1); any other missing dir stays missing (a tool creating it hits a denial).
    static func agentHome(_ preset: Preset, command: String?) -> [String] {
        let first = commandAgent(command ?? "")?.name
        let home: String? = switch preset {
        case .claude: ".claude"
        case .codex: ".codex"
        case .custom: ["claude": ".claude", "codex": ".codex", "cursor-agent": ".cursor"][first ?? ""]
        case .shell: nil
        }
        return home.map { [$0] + (agentStateDirs[$0] ?? []) } ?? []
    }

    /// B3/M4: the program a command runs: the executable's basename past a leading `env [VAR=val…]`, and where that
    /// word ends in `command` (a flag goes in right after it).
    static func commandAgent(_ command: String) -> (name: String, end: String.Index)? {
        var rest = command[...]
        func word() -> Substring? {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { return nil }
            let w = rest.prefix { !$0.isWhitespace }
            rest = rest[w.endIndex...]
            return w
        }
        func base(_ w: Substring) -> String { String(w.split(separator: "/").last ?? w) }
        guard var w = word() else { return nil }
        if base(w) == "env" { repeat { guard let n = word() else { return nil }; w = n } while w.contains("=") }
        return (base(w), w.endIndex)
    }

    /// R32: never writable, rendered after the project and every grant, so no project root (the home itself included)
    /// and no click reopens them: config another unsandboxed program executes from (shell rc, git and package-manager
    /// config), preferences, launchd agents, `~/Applications` (`collie open` launches apps from there).
    static let neverWritable = [
        ".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".zcompdump*", ".oh-my-zsh", ".p10k.zsh", ".config/zsh",
        ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile", ".inputrc", ".config/fish", ".config/starship.toml",
        ".gitconfig", ".gitignore_global", ".config/git", ".npmrc", ".yarnrc", ".yarnrc.yml",
        "Library/Preferences", "Library/LaunchAgents", "Applications",
    ]
    /// R34: the global agent config (`~/.claude.json` aside, R13): closed after the project, the home as project too, but a
    /// write grant (the user's click) re-opens it (user decision). Their state is re-opened after (`agentStateWrites`).
    static let agentConfig = [".claude", ".codex", ".cursor", ".config/cursor"]
    /// What `agentConfig` closes that the agents write: their state (R18: dirs' children only) and history files.
    static var agentStateWrites: [String] {
        homeWrites.filter { e in [".claude/", ".codex/", ".cursor/"].contains { e.hasPrefix($0) } }
    }

    /// Closed even when a grant covers them.
    static let secrets = [
        ".ssh", ".aws", ".config/gh", ".netrc", ".gem/credentials", ".cargo/credentials", ".cargo/credentials.toml", ".docker/config.json", ".gnupg", ".kube", ".config/gcloud", ".azure",
        "Library/Application Support/Google/Chrome", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Microsoft Edge", "Library/Application Support/Arc", "Library/Application Support/Firefox",
        "Library/Safari", "Library/Cookies",
    ]

    /// Never granted (R27), on top of `secrets`: the user's mail, messages, app containers and keychain files. Not
    /// read-denied (Claude reads its Keychain login, R12): only refused as grants (`SandboxGrantStore.refusal`).
    static let neverGranted = ["Library/LaunchAgents", "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Cookies",
                               "Library/Safari", "Library/Containers", "Library/Group Containers"]
    /// Too wide to grant as a whole (R27), like the home itself.
    static let tooWide = ["Library", "Library/Application Support"]

    /// The per-user cache dir (`DARWIN_USER_CACHE_DIR`) holds every app's caches: only the build tools' names are writable.
    static let userCacheWrites = ["clang", "org.llvm.clang*", "org.swift.*", "swift*", "com.apple.DeveloperTools",
                                  "com.apple.dt.*", "com.apple.CoreSimulator.*", "com.apple.metal*", "com.apple.xcrun*", "node*",
                                  "mds"]   // the Security framework's lock (Claude's Keychain login)
}
