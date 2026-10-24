import Foundation

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
        ".swiftpm", ".swiftly", "Library/org.swift.swiftpm", "Library/Developer", "Library/Keychains",
        "Library/Caches/org.swift.swiftpm", "Library/Caches/com.apple.dt.*", "Library/Caches/CocoaPods",
        "Library/Caches/Homebrew", "Library/Caches/claude-cli-nodejs", "Library/Caches/node-gyp", "Library/Caches/pip",
        "Library/Caches/pnpm", "Library/Caches/Yarn", "Library/Caches/ms-playwright", "Library/Caches/bun",
        "Library/Caches/typescript", "Library/Caches/go-build", "Library/Caches/deno", "Library/Caches/com.apple.python",
        "Library/Caches/org.carthage.CarthageKit",
        // agents: binaries, state and (read-only) config
        ".local/share/claude", ".local/state/claude", ".claude", ".claude.json", ".claude.json.backup",
        ".codex", ".cursor", ".config/cursor",
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
        // agent state (sessions, history, todos, caches); their config stays read-only
        ".claude/projects", ".claude/todos", ".claude/shell-snapshots", ".claude/statsig", ".claude/session-env",
        ".claude/ide", ".claude/debug", ".claude/file-history", ".claude/plans", ".claude/paste-cache", ".claude/logs",
        ".claude/telemetry", ".claude/history.jsonl", ".local/state/claude",
        ".codex/sessions", ".codex/archived_sessions", ".codex/log", ".codex/logs", ".codex/history.jsonl",
        ".codex/auth.json", ".codex/version.json", ".codex/tmp",
        ".cursor/chats", ".cursor/projects",
    ]

    /// Parents of `homeWrites` a tool may have to create (`mkdir`): allowed only while missing at launch, so an
    /// existing one (the user's config) can't be renamed away.
    static let homeCreates = [".swiftpm", "Library/org.swift.swiftpm", "Library/Developer", "Library/Developer/Xcode",
                              ".claude", ".codex", ".cursor", ".local", ".local/state", ".bun", ".bun/install", ".cargo", "go"]

    /// Closed even when a grant covers them.
    static let secrets = [
        ".ssh", ".aws", ".config/gh", ".netrc", ".gem/credentials", ".cargo/credentials", ".cargo/credentials.toml", ".docker/config.json", ".gnupg", ".kube", ".config/gcloud", ".azure",
        "Library/Application Support/Google/Chrome", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Microsoft Edge", "Library/Application Support/Arc", "Library/Application Support/Firefox",
        "Library/Safari", "Library/Cookies",
    ]

    /// The per-user cache dir (`DARWIN_USER_CACHE_DIR`) holds every app's caches: only the build tools' names are writable.
    static let userCacheWrites = ["clang", "org.llvm.clang*", "org.swift.*", "swift*", "com.apple.DeveloperTools",
                                  "com.apple.dt.*", "com.apple.CoreSimulator.*", "com.apple.metal*", "com.apple.xcrun*", "node*"]
}
