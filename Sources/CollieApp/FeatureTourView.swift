import SwiftUI
import CollieTheme

/// The info icon: the rail's foot (above the usage summary) and Compacta's bar (left of the usage button). A dot in the
/// accent color sits on its corner while a card is unseen.
struct TourButton: View {
    let ctx: ShellContext
    /// The color of the surface the icon sits on: the dot's ring, so it stays readable over the icon.
    let ring: Color
    var size: CGSize = CGSize(width: 40, height: 28)
    var tint: Color = .collieMuted

    var body: some View {
        let unseen = ctx.tour.hasUnseen
        Button(action: ctx.openTour) {
            Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(tint)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(Color.collieAccent).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(ring, lineWidth: 1.5).frame(width: 10, height: 10))
                            .padding(.top, 2).padding(.trailing, 5)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("O que o Collie faz").accessibilityLabel("O que o Collie faz")
        .accessibilityValue(unseen ? "com novidades" : "")
    }
}

/// The sheet: tabs per group, the card (illustration, text, how to call it, the button) and the carousel's footer.
/// ← and → change card, Esc closes. Nothing animates.
@MainActor struct FeatureTourView: View {
    let store: FeatureTourSeen
    /// The card's button: the host keeps the action and runs it when this sheet is gone (two sheets cannot be up together).
    let run: (FeatureTour.Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: FeatureTourModel
    @FocusState private var focused: Bool

    init(store: FeatureTourSeen, run: @escaping (FeatureTour.Action) -> Void) {
        self.store = store; self.run = run
        _model = State(initialValue: FeatureTourModel(seen: store.ids))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            slide
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            footer
        }
        .frame(width: 700, height: 400).background(Color.collieSurface)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.previous(); return .handled }
        .onKeyPress(.rightArrow) { model.next(); return .handled }
        .onAppear { focused = true; store.mark(model.current.id) }
        .onChange(of: model.index) {
            store.mark(model.current.id)
            AccessibilityNotification.Announcement("\(model.current.title). \(model.index + 1) de \(model.cards.count)").post()
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Text("O que o Collie faz").font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 2) { ForEach(FeatureTour.Group.allCases, id: \.self) { tab($0) } }.padding(.leading, 8)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.collieMuted)
                    .frame(width: 26, height: 26).contentShape(.rect)
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Fechar (Esc)").accessibilityLabel("Fechar")
        }
        .padding(.leading, 16).padding(.trailing, 12).frame(height: 46)
    }

    private func tab(_ g: FeatureTour.Group) -> some View {
        let on = model.group == g
        return Button { model.jump(to: g) } label: {
            Text(g.rawValue).font(.collieUI(12)).foregroundStyle(on ? Color.collieText : .collieMuted)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? Color.collieRaised : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: card

    private var slide: some View {
        let c = model.current
        return HStack(spacing: 0) {
            ZStack { Color.collieSunken; DotGrid(); FeatureArt(kind: c.art) }
                .frame(width: 250).accessibilityHidden(true)
            Rectangle().fill(Color.collieBorder).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                Text(c.group.rawValue.uppercased()).font(.collieMono(11)).kerning(0.7).foregroundStyle(Color.collieAccent)
                Text(c.title).font(.collieUI(21, .semibold)).foregroundStyle(Color.collieText).accessibilityAddTraits(.isHeader)
                Text(c.text).font(.collieUI(13.5)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Como chamar").font(.collieUI(12)).foregroundStyle(Color.collieMuted)
                    Text(c.how).font(.collieMono(11.5)).foregroundStyle(Color.collieText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.collieSunken, in: .rect(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.collieBorder, lineWidth: 1))
                }
                if let go = c.shortcut {
                    Button("\(go.label) →") { run(go.action); dismiss() }
                        .buttonStyle(CollieButtonStyle(.secondary)).controlSize(.small).padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            nav("chevron.left", "Anterior", enabled: model.canGoBack) { model.previous() }
            HStack(spacing: 0) { dots }.frame(maxWidth: .infinity)
            Text("\(model.index + 1) de \(model.cards.count)").font(.collieMono(11)).monospacedDigit()
                .foregroundStyle(Color.collieMuted).frame(minWidth: 52, alignment: .trailing)
            nav("chevron.right", "Próxima", enabled: model.canGoForward) { model.next() }
        }
        .padding(.horizontal, 14).frame(height: 46)
    }

    /// One dot per card, a thin bar between groups, the current one stretched.
    @ViewBuilder private var dots: some View {
        ForEach(model.cards.indices, id: \.self) { n in
            let c = model.cards[n], on = n == model.index
            if n > 0, model.cards[n - 1].group != c.group {
                Rectangle().fill(Color.collieBorder).frame(width: 1, height: 10).padding(.horizontal, 3).accessibilityHidden(true)
            }
            Button { model.show(n) } label: {
                Capsule().fill(on ? Color.collieAccent : .collieBorder).frame(width: on ? 18 : 7, height: 7)
                    .padding(.horizontal, 2.5).frame(height: 24).contentShape(.rect)
            }
            .buttonStyle(.plain).help(c.title).accessibilityLabel(c.title)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    private func nav(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.collieText)
                .frame(width: 30, height: 26)
                .background(Color.collieRaised, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.collieBorder, lineWidth: 1))
                .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35).accessibilityLabel(label)
    }
}

/// The canvas' dot grid, behind the illustration.
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            for x in stride(from: CGFloat(7), to: size.width, by: 14) {
                for y in stride(from: CGFloat(7), to: size.height, by: 14) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)), with: .color(Color.collieBorder))
                }
            }
        }
    }
}

// MARK: - Illustrations

/// The 17 schematic illustrations of the prototype, in a 190 × 150 space, drawn only with the theme's colors (they follow a
/// custom theme). Rounded rectangles, bars, circles, lines; the curves are short segments.
struct FeatureArt: View {
    let kind: FeatureTour.Art

    private var acc: Color { .collieAccent }
    private var att: Color { .collieAttention }
    private var sec: Color { .collieSecondary }
    private var bd: Color { .collieBorder }
    private var sf: Color { .collieSurface }

    var body: some View {
        ZStack(alignment: .topLeading) { art }.frame(width: 190, height: 150)
    }

    @ViewBuilder private var art: some View {
        switch kind {
        case .canvas: canvas
        case .paddock: paddock
        case .shepherd: shepherd
        case .loop: loop
        case .work: work
        case .palette: palette
        case .browser: browser
        case .device: device
        case .network: network
        case .design: design
        case .preview: preview
        case .diagram: diagram
        case .memory: memory
        case .sandbox: sandbox
        case .herds: herds
        case .plugins: plugins
        case .themes: themes
        }
    }

    /// A rounded card: surface fill, border outline.
    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> some View {
        ArtRect(x, y, w, h, fill: sf, stroke: bd)
    }
    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: Color? = nil) -> some View {
        ArtRect(x, y, w, 4, r: 2, fill: c ?? bd)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            box(14, 18, 70, 46); box(104, 84, 70, 46)
            bar(22, 28, 30, acc); bar(22, 38, 46); bar(112, 94, 30, acc); bar(112, 104, 46)
            ArtInk(path: curve(from: (84, 41), c1: (120, 41), c2: (70, 107), to: (104, 107)), stroke: acc)
            ArtDisc(84, 41, 4, fill: acc); ArtDisc(104, 107, 4, fill: acc)
        }
    }

    private var paddock: some View {
        ZStack(alignment: .topLeading) {
            ArtRect(14, 16, 76, 118, r: 10, stroke: acc, dash: [5, 4]); ArtRect(100, 16, 76, 118, r: 10, stroke: bd, dash: [5, 4])
            box(24, 30, 56, 34); box(24, 74, 56, 34); box(110, 30, 56, 34)
            ArtText("feat/a", 24, 126, 9, acc); ArtText("fix/b", 110, 126, 9, .collieMuted)
        }
    }

    private var shepherd: some View {
        ZStack(alignment: .topLeading) {
            box(60, 12, 70, 38); box(8, 100, 52, 34); box(69, 100, 52, 34); box(130, 100, 52, 34)
            bar(70, 24, 34, acc)
            ArtInk(path: poly([[(95, 50), (95, 76)], [(34, 100), (34, 76), (156, 76), (156, 100)], [(95, 76), (95, 100)]]), stroke: acc)
        }
    }

    private var loop: some View {
        ZStack(alignment: .topLeading) {
            ArtInk(path: poly([arcPoints(95, 75, 49, from: -90, to: 200.3, steps: 36)]), stroke: acc)
            ArtInk(path: poly([[(38, 44), (49, 58), (64, 49)]]), stroke: acc)
            ArtInk(path: poly([[(76, 77), (89, 90), (115, 62)]]), stroke: acc, lw: 5)
        }
    }

    private var work: some View {
        ZStack(alignment: .topLeading) {
            box(26, 16, 138, 118)
            ArtDisc(44, 40, 6, fill: acc); bar(58, 38, 84)
            ArtDisc(44, 66, 6, fill: acc); bar(58, 64, 64)
            ArtDisc(44, 92, 6, stroke: att); bar(58, 90, 90, att)
            ArtDisc(44, 116, 6, stroke: bd); bar(58, 114, 50)
        }
    }

    private var palette: some View {
        ZStack(alignment: .topLeading) {
            box(18, 34, 154, 34)
            ArtText("@dev revise isto", 32, 56, 13, .collieText)
            box(18, 76, 154, 52); bar(30, 88, 90, acc); bar(30, 100, 120); bar(30, 112, 70)
        }
    }

    private var browser: some View {
        ZStack(alignment: .topLeading) {
            box(16, 16, 158, 118)
            ArtDisc(30, 30, 3, fill: bd); ArtDisc(41, 30, 3, fill: bd)
            ArtRect(54, 24, 108, 12, r: 6, fill: .collieSunken, stroke: bd, lw: 1)
            ArtInk(path: poly([[(16, 44), (174, 44)]]), stroke: bd, lw: 1.5)
            bar(30, 58, 70); bar(30, 70, 110)
            ArtRect(30, 86, 50, 18, r: 5, fill: acc)
            ArtInk(path: poly([[(88, 96), (110, 104), (101, 108), (97, 117)]], close: true), stroke: .collieBackground, fill: .collieText, lw: 1.5)
        }
    }

    private var device: some View {
        ZStack(alignment: .topLeading) {
            ArtRect(62, 10, 66, 130, r: 12, fill: sf, stroke: bd); ArtRect(70, 22, 50, 94, r: 4, fill: .collieSunken)
            bar(76, 32, 30, acc); bar(76, 44, 38)
            ArtRect(76, 58, 38, 24, r: 4, fill: .collieRaised)
            ArtDisc(95, 128, 4, fill: bd); ArtDisc(104, 98, 9, stroke: acc)
        }
    }

    private var network: some View {
        ZStack(alignment: .topLeading) {
            box(10, 54, 48, 42); box(132, 54, 48, 42)
            ArtInk(path: poly([[(58, 66), (132, 66)], [(132, 84), (58, 84)]]), stroke: bd)
            ArtInk(path: poly([[(118, 60), (130, 66), (118, 72)], [(72, 78), (60, 84), (72, 90)]]), stroke: .collieMuted)
            ArtDisc(95, 75, 17, fill: sf, stroke: att)
            ArtInk(path: poly([[(88, 75), (102, 75)], [(95, 68), (95, 82)]]), stroke: att)
        }
    }

    private var design: some View {
        ZStack(alignment: .topLeading) {
            box(14, 16, 162, 118)
            ArtRect(28, 30, 60, 44, r: 5, fill: .collieRaised)
            ArtDisc(130, 52, 20, fill: sec, alpha: 0.8)
            ArtRect(28, 86, 100, 10, r: 5, fill: acc); ArtRect(28, 104, 66, 10, r: 5, fill: bd)
            ArtRect(84, 70, 8, 8, r: 0, fill: sf, stroke: acc)
        }
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            box(14, 16, 116, 118)
            bar(26, 30, 50, acc); bar(26, 44, 90); bar(26, 56, 74)
            ArtRect(26, 70, 92, 50, r: 5, fill: .collieRaised)
            ArtInk(path: poly([[(120, 60), (174, 60), (174, 100), (148, 100), (136, 112), (136, 100), (120, 100)]], close: true),
                   stroke: att, fill: sf, lw: 1.5)
            bar(128, 72, 36, att); bar(128, 84, 24)
        }
    }

    private var diagram: some View {
        ZStack(alignment: .topLeading) {
            box(64, 10, 62, 30); box(10, 104, 62, 30); box(118, 104, 62, 30)
            ArtInk(path: poly([[(95, 40), (95, 64)], [(41, 104), (41, 64), (149, 64), (149, 104)]]), stroke: acc)
            ArtInk(path: poly([[(95, 64), (89, 56), (101, 56)]], close: true), fill: acc, lw: 0)
        }
    }

    private var memory: some View {
        ZStack(alignment: .topLeading) {
            box(20, 14, 150, 32); box(20, 58, 150, 32); box(20, 102, 150, 32)
            bar(32, 24, 60, acc); bar(32, 34, 110); bar(32, 68, 48, sec); bar(32, 78, 96); bar(32, 112, 70, att); bar(32, 122, 84)
            ArtInk(path: poly([[(150, 26), (155, 31), (164, 21)]]), stroke: acc)
        }
    }

    private var sandbox: some View {
        ZStack(alignment: .topLeading) {
            ArtInk(path: shield, stroke: bd, fill: sf, lw: 1.5)
            ArtRect(62, 58, 66, 40, r: 6, fill: .collieRaised, stroke: att)
            bar(70, 68, 38, att)
            ArtRect(70, 80, 26, 10, r: 4, fill: acc); ArtRect(100, 80, 20, 10, r: 4, fill: bd)
        }
    }

    private var herds: some View {
        ZStack(alignment: .topLeading) {
            box(12, 20, 48, 34); box(71, 20, 48, 34); box(130, 20, 48, 34)
            ArtInk(path: poly([[(36, 54), (36, 76), (154, 76), (154, 54)], [(95, 54), (95, 76)]]), stroke: bd)
            ArtRect(40, 84, 110, 46, r: 9, fill: sf, stroke: acc)
            bar(54, 98, 54, acc); bar(54, 110, 80)
        }
    }

    private var plugins: some View {
        ZStack(alignment: .topLeading) {
            box(14, 34, 96, 84)
            bar(26, 48, 40, acc); bar(26, 60, 70); bar(26, 72, 56)
            ArtInk(path: poly([piece], close: true), stroke: sec, fill: .collieRaised, lw: 1.5)
            ArtInk(path: poly([[(110, 76), (128, 76)]]), stroke: sec)
        }
    }

    /// Three mini themes (the app's background, its inverse, the highlighted one) and the editor's color rows.
    private var themes: some View {
        ZStack(alignment: .topLeading) {
            Group {
                ArtRect(14, 20, 50, 44, r: 7, fill: .collieBackground, stroke: bd); ArtRect(42, 50, 14, 6, r: 3, fill: acc)
                ArtRect(70, 20, 50, 44, r: 7, fill: .collieText, stroke: bd); ArtRect(98, 50, 14, 6, r: 3, fill: .collieBackground)
                ArtRect(126, 20, 50, 44, r: 7, fill: .collieRaised, stroke: acc, lw: 2); ArtRect(154, 50, 14, 6, r: 3, fill: sec)
            }
            Group {
                box(14, 78, 162, 54)
                ArtRect(26, 90, 12, 12, r: 3, fill: sec); bar(46, 94, 60)
                ArtRect(26, 110, 12, 12, r: 3, fill: att); bar(46, 114, 84)
            }
        }
    }

    // MARK: geometry (SVG coordinates of the prototype)

    private typealias Pt = (CGFloat, CGFloat)

    private func poly(_ runs: [[Pt]], close: Bool = false) -> Path {
        var p = Path()
        for run in runs {
            guard let first = run.first else { continue }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for q in run.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            if close { p.closeSubpath() }
        }
        return p
    }

    private func curve(from a: Pt, c1: Pt, c2: Pt, to b: Pt) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: a.0, y: a.1))
        p.addCurve(to: CGPoint(x: b.0, y: b.1), control1: CGPoint(x: c1.0, y: c1.1), control2: CGPoint(x: c2.0, y: c2.1))
        return p
    }

    /// Points of an arc, in screen coordinates (y down); angles in degrees, growing clockwise on screen.
    private func arcPoints(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from: Double, to: Double, steps: Int) -> [Pt] {
        (0...steps).map { i in
            let t = (from + (to - from) * Double(i) / Double(steps)) * Double.pi / 180
            return (cx + r * CGFloat(cos(t)), cy + r * CGFloat(sin(t)))
        }
    }

    private var shield: Path {
        var p = Path()
        p.move(to: CGPoint(x: 95, y: 12)); p.addLine(to: CGPoint(x: 151, y: 32)); p.addLine(to: CGPoint(x: 151, y: 68))
        p.addCurve(to: CGPoint(x: 95, y: 138), control1: CGPoint(x: 151, y: 102), control2: CGPoint(x: 127, y: 126))
        p.addCurve(to: CGPoint(x: 39, y: 68), control1: CGPoint(x: 63, y: 126), control2: CGPoint(x: 39, y: 102))
        p.addLine(to: CGPoint(x: 39, y: 32)); p.closeSubpath()
        return p
    }

    /// The puzzle piece: a rounded right edge with a notch.
    private var piece: [Pt] {
        var pts: [Pt] = [(128, 52)]
        pts += arcPoints(148, 60, 8, from: -90, to: 0, steps: 6)
        pts.append((156, 66))
        pts += arcPoints(156, 76, 10, from: -90, to: -270, steps: 10)
        pts.append((156, 92))
        pts += arcPoints(148, 92, 8, from: 0, to: 90, steps: 6)
        pts.append((128, 100))
        return pts
    }
}

/// A rounded rectangle at (x, y); `stroke` and `fill` optional.
private struct ArtRect: View {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var r: CGFloat = 7
    var fill: Color?
    var stroke: Color?
    var lw: CGFloat = 1.5
    var dash: [CGFloat] = []

    init(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 7, fill: Color? = nil, stroke: Color? = nil,
         lw: CGFloat = 1.5, dash: [CGFloat] = []) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.r = r; self.fill = fill; self.stroke = stroke; self.lw = lw; self.dash = dash
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: r)
        shape.fill(fill ?? .clear)
            .overlay(shape.stroke(stroke ?? .clear, style: StrokeStyle(lineWidth: lw, dash: dash)))
            .frame(width: w, height: h).offset(x: x, y: y)
    }
}

/// A circle centered at (cx, cy).
private struct ArtDisc: View {
    let cx: CGFloat, cy: CGFloat, r: CGFloat
    var fill: Color?
    var stroke: Color?
    var lw: CGFloat = 2
    var alpha: Double = 1

    init(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, fill: Color? = nil, stroke: Color? = nil, lw: CGFloat = 2, alpha: Double = 1) {
        self.cx = cx; self.cy = cy; self.r = r; self.fill = fill; self.stroke = stroke; self.lw = lw; self.alpha = alpha
    }

    var body: some View {
        Circle().fill(fill ?? .clear)
            .overlay(Circle().stroke(stroke ?? .clear, lineWidth: lw))
            .frame(width: r * 2, height: r * 2).opacity(alpha).offset(x: cx - r, y: cy - r)
    }
}

/// A path in the 190 × 150 space (the view takes the whole space, so the coordinates are the path's own).
private struct ArtInk: View {
    let path: Path
    var stroke: Color?
    var fill: Color?
    var lw: CGFloat = 2

    var body: some View {
        ZStack {
            if let fill { path.fill(fill) }
            if let stroke, lw > 0 { path.stroke(stroke, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)) }
        }
    }
}

/// Monospaced text with its baseline at `y`.
private struct ArtText: View {
    let text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: Color

    init(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: Color) {
        self.text = text; self.x = x; self.y = y; self.size = size; self.color = color
    }

    var body: some View {
        Text(text).font(.collieMono(size)).foregroundStyle(color).fixedSize().offset(x: x, y: y - size)
    }
}
