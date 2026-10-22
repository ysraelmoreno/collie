import SwiftUI

public struct CollieButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, quiet, attention }
    let kind: Kind
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        configuration.label
            .font(.collieUI(13, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 14)
            .frame(height: controlSize == .large ? 40 : 32)
            .background(shape.fill(bg))
            .overlay(shape.strokeBorder(kind == .secondary ? Color.collieBorder : .clear, lineWidth: 1))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
    }
    private var fg: Color {
        switch kind {
        case .primary: .collieOnAccent
        case .secondary: .collieText
        case .quiet: .collieMuted
        case .attention: .collieBackground
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: .collieAccent
        case .attention: .collieAttention
        default: .clear
        }
    }
}

/// A text field on `sunken` with a `border` outline, `accent` while focused (a plain field draws no system ring).
public struct CollieField: ViewModifier {
    let mono: Bool
    @FocusState private var focused: Bool
    public init(mono: Bool = false) { self.mono = mono }
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        content.textFieldStyle(.plain).focused($focused)
            .font(mono ? .collieMono(13) : .collieUI(14)).foregroundStyle(Color.collieText)
            .padding(.horizontal, 12).frame(height: 36)
            .background(shape.fill(Color.collieSunken))
            .overlay(shape.strokeBorder(focused ? Color.collieAccent : .collieBorder, lineWidth: focused ? 2 : 1))
    }
}
extension View {
    public func collieField(mono: Bool = false) -> some View { modifier(CollieField(mono: mono)) }
}

public struct CollieCard: ViewModifier {
    var highlight: Color?
    public init(highlight: Color? = nil) { self.highlight = highlight }
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        content.background(shape.fill(Color.collieSurface))
            .overlay(shape.strokeBorder(highlight ?? .collieBorder, lineWidth: 1))
    }
}
extension View {
    public func collieCard(highlight: Color? = nil) -> some View { modifier(CollieCard(highlight: highlight)) }
}

public struct CollieTag: View {
    public enum Tone { case neutral, accent, attention, secondary }
    let text: String, tone: Tone
    public init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }
    public var body: some View {
        Text(text).font(.collieMono(11, .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
    private var color: Color {
        switch tone {
        case .neutral: .collieMuted
        case .accent: .collieAccent
        case .attention: .collieAttention
        case .secondary: .collieSecondary
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
                    Text(title).font(.collieUI(18, .semibold)).foregroundStyle(Color.collieText)
                    if let subtitle { Text(subtitle).font(.collieMono(12)).foregroundStyle(Color.collieMuted) }
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Color.collieBorder).frame(height: 1)
        }
    }
}

public struct PanelFooter: View {
    let leading: String, trailing: String?
    public init(_ leading: String, trailing: String? = nil) { self.leading = leading; self.trailing = trailing }
    public var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            HStack {
                Text(leading); Spacer(); if let trailing { Text(trailing) }
            }
            .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
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
                Text(title).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                Text(subtitle).font(.collieMono(12)).foregroundStyle(Color.collieMuted).multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Color.collieRaised : .clear))
            .overlay(shape.strokeBorder(selected ? Color.collieAccent : .collieBorder, lineWidth: selected ? 2 : 1))
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
