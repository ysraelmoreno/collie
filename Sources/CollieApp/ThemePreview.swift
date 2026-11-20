import SwiftUI
import CollieTheme

/// A small canvas (rail, terminal node with an approval, memory card) drawn only from the palette it is given, so it
/// can show a theme that is not the one applied. Reads no app-wide color.
struct ThemePreview: View {
    let palette: Palette

    private func c(_ r: RGB) -> Color { Color(nsColor: r.nsColor) }

    var body: some View {
        HStack(spacing: 0) {
            rail
            ZStack(alignment: .topLeading) {
                grid
                VStack(spacing: 8) { terminalNode; memoryNode }.padding(9)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(c(palette.background))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c(palette.border), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var rail: some View {
        VStack(spacing: 7) {
            Circle().fill(c(palette.accent)).frame(width: 15, height: 15)
            RoundedRectangle(cornerRadius: 5).fill(c(palette.border)).frame(width: 15, height: 15)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(c(palette.accent), lineWidth: 1.5))
            RoundedRectangle(cornerRadius: 5).fill(c(palette.border)).frame(width: 15, height: 15)
            RoundedRectangle(cornerRadius: 5).fill(c(palette.border)).frame(width: 15, height: 15)
            Spacer(minLength: 0)
        }
        .padding(.top, 9)
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .background(c(palette.sidebar))
        .overlay(alignment: .trailing) { c(palette.border).frame(width: 1) }
    }

    private var grid: some View {
        let dot = c(palette.grid)
        return Canvas { ctx, size in
            var y: CGFloat = 7
            while y < size.height {
                var x: CGFloat = 7
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(dot))
                    x += 14
                }
                y += 14
            }
        }
    }

    private func line(_ text: String, _ color: RGB) -> some View {
        Text(text).font(.collieMono(10)).foregroundStyle(c(color)).lineLimit(1)
    }

    private var terminalNode: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(c(palette.accent)).frame(width: 7, height: 7)
                Text("dev · claude").font(.collieUI(10.5)).foregroundStyle(c(palette.textSecondary))
                Spacer(minLength: 0)
                Text("1").font(.collieUI(10, .semibold)).foregroundStyle(c(palette.attention))
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(c(palette.attentionTint)))
                    .overlay(Capsule().strokeBorder(c(palette.attention), lineWidth: 1))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(alignment: .bottom) { c(palette.border).frame(height: 1) }
            VStack(alignment: .leading, spacing: 1) {
                line("$ collie summon dev", palette.text)
                line("● lendo CollieTheme", palette.accent)
                line("  3 arquivos, 412 linhas", palette.muted)
                line("→ guia: design-1", palette.secondary)
                line("✗ teste falhou (2)", palette.danger)
                line("! aguardando aprovação", palette.attention)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 3)
            HStack(spacing: 6) {
                Text("Permitir").font(.collieUI(10.5, .semibold)).foregroundStyle(c(palette.onAccent))
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(c(palette.accent)))
                Text("Negar").font(.collieUI(10.5)).foregroundStyle(c(palette.text))
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c(palette.border), lineWidth: 1))
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c(palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c(palette.border), lineWidth: 1))
    }

    private var memoryNode: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Memória").font(.collieUI(10.5)).foregroundStyle(c(palette.textSecondary))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { c(palette.borderSoft).frame(height: 1) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Tema é um arquivo").font(.collieUI(10.5, .semibold)).foregroundStyle(c(palette.text))
                Text("decisão · há 2 dias").font(.collieUI(10.5)).foregroundStyle(c(palette.muted))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c(palette.raised))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c(palette.borderSoft), lineWidth: 1))
    }
}
