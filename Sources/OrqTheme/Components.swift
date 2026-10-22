import SwiftUI

public struct OrqButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, quiet, attention }
    let kind: Kind
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        configuration.label
            .font(.orqUI(13, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 14)
            .frame(height: controlSize == .large ? 40 : 32)
            .background(shape.fill(bg))
            .overlay(shape.strokeBorder(kind == .secondary ? Color.orqBorder : .clear, lineWidth: 1))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
    }
    private var fg: Color {
        switch kind {
        case .primary: .orqOnAccent
        case .secondary: .orqText
        case .quiet: .orqMuted
        case .attention: .orqBackground
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: .orqAccent
        case .attention: .orqAttention
        default: .clear
        }
    }
}

/// A text field on `sunken` with a `border` outline, `accent` while focused (a plain field draws no system ring).
public struct OrqField: ViewModifier {
    let mono: Bool
    @FocusState private var focused: Bool
    public init(mono: Bool = false) { self.mono = mono }
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        content.textFieldStyle(.plain).focused($focused)
            .font(mono ? .orqMono(13) : .orqUI(14)).foregroundStyle(Color.orqText)
            .padding(.horizontal, 12).frame(height: 36)
            .background(shape.fill(Color.orqSunken))
            .overlay(shape.strokeBorder(focused ? Color.orqAccent : .orqBorder, lineWidth: focused ? 2 : 1))
    }
}
extension View {
    public func orqField(mono: Bool = false) -> some View { modifier(OrqField(mono: mono)) }
}

public struct OrqCard: ViewModifier {
    var highlight: Color?
    public init(highlight: Color? = nil) { self.highlight = highlight }
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        content.background(shape.fill(Color.orqSurface))
            .overlay(shape.strokeBorder(highlight ?? .orqBorder, lineWidth: 1))
    }
}
extension View {
    public func orqCard(highlight: Color? = nil) -> some View { modifier(OrqCard(highlight: highlight)) }
}

public struct OrqTag: View {
    public enum Tone { case neutral, accent, attention, secondary }
    let text: String, tone: Tone
    public init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }
    public var body: some View {
        Text(text).font(.orqMono(11, .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
    private var color: Color {
        switch tone {
        case .neutral: .orqMuted
        case .accent: .orqAccent
        case .attention: .orqAttention
        case .secondary: .orqSecondary
        }
    }
}

public struct PanelHeader<Trailing: View>: View {
    let title: String, subtitle: String?, trailing: Trailing
    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.orqUI(18, .semibold)).foregroundStyle(Color.orqText)
                    if let subtitle { Text(subtitle).font(.orqMono(12)).foregroundStyle(Color.orqMuted) }
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Color.orqBorder).frame(height: 1)
        }
    }
}

public struct PanelFooter: View {
    let leading: String, trailing: String?
    public init(_ leading: String, trailing: String? = nil) { self.leading = leading; self.trailing = trailing }
    public var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.orqBorder).frame(height: 1)
            HStack {
                Text(leading); Spacer(); if let trailing { Text(trailing) }
            }
            .font(.orqMono(12)).foregroundStyle(Color.orqMuted)
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }
}

public struct ChoiceCard<Preview: View>: View {
    let title: String, subtitle: String, selected: Bool, action: () -> Void, preview: Preview
    public init(_ title: String, subtitle: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) {
        self.title = title; self.subtitle = subtitle; self.selected = selected; self.action = action; self.preview = preview()
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                if Preview.self != EmptyView.self { preview.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8)) }
                Text(title).font(.orqUI(14, .semibold)).foregroundStyle(Color.orqText)
                Text(subtitle).font(.orqMono(12)).foregroundStyle(Color.orqMuted).multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Color.orqRaised : .clear))
            .overlay(shape.strokeBorder(selected ? Color.orqAccent : .orqBorder, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)   // system focus ring is kept
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
extension PanelHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String? = nil) { self.init(title, subtitle: subtitle) { EmptyView() } }
}
