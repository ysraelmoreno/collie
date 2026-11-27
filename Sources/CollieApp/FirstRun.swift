import SwiftUI
import CollieCore

import CollieTheme

/// First use: the current paddock (or the Pasture) has no agent → the canvas explains what an agent and a paddock are,
/// with "Novo agente" and "Usar um rebanho pronto". Gone with the first agent.
enum FirstRun {
    /// True while the daemon is reachable and no terminal lives in `current` (nil: the Pasture). Panels do not count.
    static func shows(connected: Bool, terminals: [TerminalRecord], current: UUID?) -> Bool {
        connected && !terminals.contains { $0.paddockId == current }
    }
}

/// The card in the middle of the canvas. Clicks outside it reach the canvas (right-click still opens its menu).
struct FirstRunView: View {
    let ctx: ShellContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Comece com um agente", "Start with an agent")).font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText)
                .accessibilityAddTraits(.isHeader)
            Text(tr("Um agente é uma IA trabalhando num terminal. Um cercado é uma cópia isolada do seu projeto, para agentes não pisarem um no outro.",
                    "An agent is an AI working in a terminal. A paddock is an isolated copy of your project, so agents don't step on each other."))
                .font(.collieUI(14)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(tr("＋ Novo agente", "＋ New agent"), action: ctx.newTerminal)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button(tr("Usar um rebanho pronto", "Use a ready-made herd")) { ctx.openHerds(nil) }
                    .buttonStyle(.link).font(.collieUI(13))
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 26)
        .frame(width: 460, alignment: .leading)
        .background(Color.collieSurface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.collieBorder))
        .shadow(color: .black.opacity(0.3), radius: 25, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Primeiro uso", "First use"))
    }
}
