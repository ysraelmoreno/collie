import Foundation
import CollieCore
import CollieProtocol
import CollieDaemonKit

L10n.set(Lang.forCLI(env: ProcessInfo.processInfo.environment, setting: LanguagePreference.saved(root: Paths().root),
                     preferred: Locale.preferredLanguages))
let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "hook" {
    await HookCommands.run(Array(argv.dropFirst()))
    exit(0)
}
if argv.first == "mcp" { await MCPServer.run(); exit(0) }
exit(await CLI.run(argv))
