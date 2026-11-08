import SwiftUI
import AppKit

extension AppPage {
    var artwork: String { [.hires, .skills].contains(self) ? "discovery" : self == .connection ? "contractors" : self == .rules ? "shift" : rawValue }
    var hasArtwork: Bool { self != .home && self != .advisor }
}

@MainActor private enum WorkshopArtImages {
    static let all: [String: NSImage] = Dictionary(AppPage.allCases.compactMap { page in
        guard let url = AppResources.bundle.url(forResource: "crew-" + page.artwork, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (page.artwork, image)
    }, uniquingKeysWith: { first, _ in first })
}

/// Shared gate for decorative motion: Reduce Motion, Low Power Mode and inactive windows stop it.
private struct MotionEnvironment {
    var reduceMotion: Bool
    var activeState: ControlActiveState
    var gate: MotionGate {
        MotionGate(reduceMotion: reduceMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, visible: activeState != .inactive)
    }
}

/// Decorative artwork never carries status or replaces a control's accessible label.
/// It enters with a hop, lives for a few seconds with scene effects, then rests until hovered.
struct WorkshopIllustration: View {
    let page: AppPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme
    @State private var liveliness = Liveliness(now: Date())
    @State private var appearedAt = Date()
    @State private var hovered = false
    @State private var restTick = 0
    private var image: NSImage? { WorkshopArtImages.all[page.artwork] }
    private var gate: MotionGate { MotionEnvironment(reduceMotion: reduceMotion, activeState: activeState).gate }
    private static let frame = CGSize(width: 174, height: 154)

    var body: some View {
        let _ = restTick
        let running = liveliness.isLive(at: Date(), gate: gate) || entering(at: Date())
        ZStack {
            Ellipse().fill(Workshop.yellow.opacity(0.12)).frame(width: 148, height: 98).rotationEffect(.degrees(-12))
            Circle().strokeBorder(Workshop.yellow.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                .frame(width: 120, height: 120).offset(x: 15, y: -3)
            if let image {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { timeline in
                    scene(image: image, now: timeline.date)
                }
                .rotationEffect(.degrees(reduceMotion ? 0 : hovered ? -3 : 0))
                .offset(y: reduceMotion ? 0 : hovered ? -4 : 0)
            }
            Image(systemName: "sparkle").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Workshop.yellow).offset(x: 67, y: -44)
                .scaleEffect(reduceMotion ? 1 : hovered ? 1.25 : 1)
        }
        .frame(width: 184, height: 154)
        .onAppear { let now = Date(); appearedAt = now; liveliness = Liveliness(now: now) }
        .onHover { inside in
            hovered = inside
            if inside { liveliness.wake(now: Date()) }
        }
        // Re-evaluate once the lively spell ends so the timeline can pause.
        .task(id: liveliness.liveUntil) {
            let wait = liveliness.liveUntil.timeIntervalSinceNow + 0.7
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            restTick &+= 1
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: hovered)
        .accessibilityHidden(true)
    }

    private func entering(at now: Date) -> Bool { !reduceMotion && now.timeIntervalSince(appearedAt) < 0.7 }

    @ViewBuilder private func scene(image: NSImage, now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        let live = liveliness.isLive(at: now, gate: gate)
        // Effects and idle motion fade over the last 0.6 s instead of stopping abruptly.
        let fade = live ? min(1, liveliness.liveUntil.timeIntervalSince(now) / 0.6) : 0
        let entrance = reduceMotion ? 1 : min(1, max(0, now.timeIntervalSince(appearedAt) / 0.7))
        let pose = idlePose(t: t - appearedAt.timeIntervalSinceReferenceDate, weight: fade)
        let hop = Self.entrancePose(entrance)
        let rect = ArtGeometry.fitted(imageSize: image.size, in: Self.frame)
        let effects = ArtScenes.effects(for: page.artwork)
        let painter = { (behind: Bool) in
            ArtEffectsPainter(effects: effects, rect: rect, t: t, sinceWake: now.timeIntervalSince(liveliness.lastWake), opacity: fade,
                              arabic: layoutDirection == .rightToLeft, dark: colorScheme == .dark, behind: behind)
        }
        ZStack {
            if fade > 0 { Canvas { context, _ in painter(true).paint(context) } }
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            if fade > 0 { Canvas { context, _ in painter(false).paint(context) } }
        }
        .frame(width: Self.frame.width, height: Self.frame.height)
        .scaleEffect(x: pose.scaleX * hop.scaleX, y: pose.scaleY * hop.scaleY, anchor: UnitPoint(x: 0.5, y: 0.92))
        .rotationEffect(.degrees(pose.rotation), anchor: UnitPoint(x: 0.5, y: 0.92))
        .offset(y: pose.offsetY + hop.offsetY)
        .opacity(hop.opacity)
    }

    private struct Pose { var scaleX = 1.0, scaleY = 1.0, rotation = 0.0, offsetY = 0.0, opacity = 1.0 }

    private func idlePose(t: Double, weight: Double) -> Pose {
        guard weight > 0, t > 0.7 else { return Pose() }
        switch ArtScenes.idle(for: page.artwork) {
        case .breathe:
            let b = (1 - cos(2 * .pi * EffectMath.cycle(t, period: 3.4, delay: 0.7))) / 2 * weight
            return Pose(scaleX: 1 + 0.012 * b, scaleY: 1 + 0.018 * b, offsetY: -2 * b)
        case .step:
            let s = sin(2 * .pi * EffectMath.cycle(t, period: 0.62, delay: 0.7))
            return Pose(rotation: -0.8 * s * weight, offsetY: -3 * abs(s) * weight)
        }
    }

    /// Squash-and-stretch hop: low and wide → tall overshoot → settled.
    private static func entrancePose(_ u: Double) -> Pose {
        if u >= 1 { return Pose() }
        func mix(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
        if u < 0.6 {
            let x = u / 0.6
            return Pose(scaleX: mix(0.9, 1.03, x), scaleY: mix(0.86, 1.06, x), offsetY: mix(14, -4, x), opacity: min(1, x * 1.6))
        }
        let x = (u - 0.6) / 0.4
        return Pose(scaleX: mix(1.03, 1, x), scaleY: mix(1.06, 1, x), offsetY: mix(-4, 0, x))
    }
}

/// Small, legible workshop pictograms drawn natively at every display scale.
/// Each one performs a short gesture when hovered or when its page becomes active.
struct WorkshopGlyph: View {
    let page: AppPage
    var size: CGFloat = 22
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: startedAt == nil)) { timeline in
            let phase = startedAt.map { min(1, timeline.date.timeIntervalSince($0) / GlyphMotion.duration) } ?? 0
            Canvas { context, bounds in draw(context, bounds: bounds, phase: phase) }
        }
        .frame(width: size, height: size)
        .onHover { if $0 { play() } }
        .onChange(of: active) { _, isActive in if isActive { play() } }
        .task(id: startedAt) {
            guard startedAt != nil else { return }
            try? await Task.sleep(for: .seconds(GlyphMotion.duration + 0.05))
            startedAt = nil
        }
        .accessibilityHidden(true)
    }

    private func play() { if !reduceMotion && startedAt == nil { startedAt = Date() } }

    private func draw(_ base: GraphicsContext, bounds: CGSize, phase: Double) {
        var root = base
        root.scaleBy(x: bounds.width / 32, y: bounds.height / 32)
        let ink = GraphicsContext.Shading.color(Color.primary)
        let accent = GraphicsContext.Shading.color(Workshop.yellow)
        let b = GlyphMotion.bell(phase)
        func line(_ c: GraphicsContext, _ points: [CGPoint], close: Bool = false, width: CGFloat = 2) {
            var path = Path(); guard let first = points.first else { return }
            path.move(to: first); for point in points.dropFirst() { path.addLine(to: point) }
            if close { path.closeSubpath() }
            c.stroke(path, with: ink, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        func rect(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 3, fill: Bool = false) {
            let path = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius)
            if fill { c.fill(path, with: accent) }
            c.stroke(path, with: ink, lineWidth: 2)
        }
        func circle(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ d: CGFloat, fill: Bool = false) {
            let path = Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d))
            if fill { c.fill(path, with: accent) }
            c.stroke(path, with: ink, lineWidth: 2)
        }
        func moved(_ dx: Double = 0, _ dy: Double = 0, rotate degrees: Double = 0, around pivot: CGPoint = .zero, scaleX: Double = 1) -> GraphicsContext {
            var c = root
            c.translateBy(x: pivot.x + dx, y: pivot.y + dy); c.rotate(by: .degrees(degrees)); c.scaleBy(x: scaleX, y: 1); c.translateBy(x: -pivot.x, y: -pivot.y)
            return c
        }
        switch page {
        case .shift, .rules:
            circle(root, 11, 9, 10, fill: true)
            line(root, [.init(x: 7, y: 27), .init(x: 8, y: 23), .init(x: 12, y: 21), .init(x: 20, y: 21), .init(x: 24, y: 23), .init(x: 25, y: 27)])
            let helmet = moved(0, -3 * b, rotate: -14 * b, around: CGPoint(x: 16, y: 10))
            line(helmet, [.init(x: 9, y: 11), .init(x: 23, y: 11)])
            line(helmet, [.init(x: 13, y: 9), .init(x: 13, y: 6), .init(x: 19, y: 6), .init(x: 19, y: 9)], close: true)
            line(root, [.init(x: 3, y: 15), .init(x: 3, y: 24)]); line(root, [.init(x: 29, y: 15), .init(x: 29, y: 24)])
        case .usage:
            rect(root, 5, 17, 22, 10, fill: true); line(root, [.init(x: 6, y: 22), .init(x: 26, y: 22)])
            let coin = moved(0, -6 * b, around: CGPoint(x: 16, y: 10), scaleX: phase > 0 && phase < 1 ? cos(2 * .pi * phase) : 1)
            circle(coin, 11, 5, 10, fill: true); line(coin, [.init(x: 16, y: 8), .init(x: 16, y: 12)])
        case .hires, .skills:
            rect(root, 5, 15, 22, 13, fill: true); rect(moved(0, -3 * b), 11, 11, 10, 5)
            let rays = moved(around: CGPoint(x: 16, y: 9), scaleX: 1 + 0.5 * b)
            line(rays, [.init(x: 16, y: 2), .init(x: 16, y: 7)])
            line(rays, [.init(x: 5, y: 5), .init(x: 8, y: 8)]); line(rays, [.init(x: 27, y: 5), .init(x: 24, y: 8)])
            line(root, [.init(x: 16, y: 19), .init(x: 16, y: 25)]); line(root, [.init(x: 13, y: 22), .init(x: 19, y: 22)])
        case .contractors:
            rect(root, 4, 12, 24, 15, fill: true); rect(moved(0, -3 * b), 11, 6, 10, 6)
            line(root, [.init(x: 4, y: 18), .init(x: 28, y: 18)]); rect(root, 13, 16, 6, 6, radius: 1)
        case .worklog:
            rect(root, 6, 4, 21, 25, fill: true)
            line(root, [.init(x: 11, y: 5), .init(x: 11, y: 28)])
            for (index, y) in [11.0, 16.0, 21.0].enumerated() {
                let reveal = GlyphMotion.lineReveal(index: index, phase: phase)
                line(root, [.init(x: 15, y: y), .init(x: 15 + 7 * reveal, y: y)])
            }
        case .contest:
            let wobble = 10 * sin(3 * .pi * phase) * (1 - phase)
            let cupContext = moved(rotate: phase > 0 && phase < 1 ? wobble : 0, around: CGPoint(x: 16, y: 28))
            var cup = Path(); cup.move(to: .init(x: 9, y: 5)); cup.addLine(to: .init(x: 23, y: 5)); cup.addQuadCurve(to: .init(x: 16, y: 21), control: .init(x: 23, y: 20)); cup.addQuadCurve(to: .init(x: 9, y: 5), control: .init(x: 9, y: 20)); cup.closeSubpath()
            cupContext.fill(cup, with: accent); cupContext.stroke(cup, with: ink, lineWidth: 2)
            line(cupContext, [.init(x: 9, y: 8), .init(x: 4, y: 8), .init(x: 5, y: 15), .init(x: 10, y: 16)])
            line(cupContext, [.init(x: 23, y: 8), .init(x: 28, y: 8), .init(x: 27, y: 15), .init(x: 22, y: 16)])
            line(cupContext, [.init(x: 16, y: 21), .init(x: 16, y: 27)]); line(cupContext, [.init(x: 10, y: 28), .init(x: 22, y: 28)])
        case .home:
            let roof = moved(0, -2 * b)
            line(roof, [.init(x: 3, y: 15), .init(x: 16, y: 4), .init(x: 29, y: 15)])
            line(root, [.init(x: 7, y: 14), .init(x: 7, y: 28), .init(x: 25, y: 28), .init(x: 25, y: 14)])
            rect(root, 13, 19, 6, 9, radius: 1, fill: true)
        case .connection:
            line(root, [.init(x: 16, y: 10), .init(x: 7, y: 24), .init(x: 25, y: 24), .init(x: 16, y: 10)])
            circle(moved(0, -2 * b), 11, 2, 10, fill: true)
            circle(root, 2, 21, 9); circle(root, 21, 21, 9)
        case .advisor:
            rect(moved(0, -2 * b), 3, 5, 18, 13, radius: 4, fill: true)
            line(root, [.init(x: 7, y: 18), .init(x: 6, y: 22), .init(x: 12, y: 18)])
            rect(root, 13, 15, 16, 12, radius: 4)
            line(root, [.init(x: 24, y: 27), .init(x: 27, y: 30), .init(x: 27, y: 25)])
        case .settings:
            for (y, x, slide) in [(8.0, 12.0, 8.0), (16.0, 22.0, -8.0), (24.0, 9.0, 10.0)] {
                line(root, [.init(x: 4, y: y), .init(x: 28, y: y)])
                circle(root, x - 3 + slide * b, y - 3, 6, fill: true)
            }
        }
    }
}

/// Status pill icon: a swinging hammer at work, a steaming cup on break,
/// a drifting ghost when skipped, a rocking moon when clocked out, otherwise a dot.
struct LivingStatusIcon: View {
    enum Kind: Equatable { case dot, hammer, cup, ghost, moon }
    let kind: Kind
    let color: Color
    var size: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    private var animates: Bool { kind != .dot && MotionEnvironment(reduceMotion: reduceMotion, activeState: activeState).gate.allowsMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animates)) { timeline in
            let t = animates ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, bounds in draw(context, bounds: bounds, t: t) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(_ base: GraphicsContext, bounds: CGSize, t: Double) {
        var c = base; c.scaleBy(x: bounds.width / 24, y: bounds.height / 24)
        let ink = GraphicsContext.Shading.color(color)
        let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        switch kind {
        case .dot:
            c.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: 24, height: 24)), with: ink)
        case .hammer:
            var hammer = c
            let swing = -28 * (1 - cos(2 * .pi * EffectMath.cycle(t, period: 0.55))) / 2
            hammer.translateBy(x: 5, y: 19); hammer.rotate(by: .degrees(swing)); hammer.translateBy(x: -5, y: -19)
            var handle = Path(); handle.move(to: CGPoint(x: 5, y: 19)); handle.addLine(to: CGPoint(x: 13, y: 11))
            var head = Path(); head.move(to: CGPoint(x: 11, y: 5)); head.addLine(to: CGPoint(x: 17, y: 11)); head.addLine(to: CGPoint(x: 15, y: 13)); head.addLine(to: CGPoint(x: 9, y: 7)); head.closeSubpath()
            hammer.stroke(handle, with: ink, style: style); hammer.stroke(head, with: ink, style: style)
            var floor = Path(); floor.move(to: CGPoint(x: 3, y: 21)); floor.addLine(to: CGPoint(x: 11, y: 21)); c.stroke(floor, with: ink, style: style)
        case .cup:
            var cup = Path()
            cup.move(to: CGPoint(x: 5, y: 11)); cup.addLine(to: CGPoint(x: 16, y: 11)); cup.addLine(to: CGPoint(x: 16, y: 15))
            cup.addQuadCurve(to: CGPoint(x: 10.5, y: 20), control: CGPoint(x: 16, y: 20)); cup.addQuadCurve(to: CGPoint(x: 5, y: 15), control: CGPoint(x: 5, y: 20)); cup.closeSubpath()
            cup.move(to: CGPoint(x: 16, y: 12)); cup.addQuadCurve(to: CGPoint(x: 16, y: 16), control: CGPoint(x: 20, y: 14))
            c.stroke(cup, with: ink, style: style)
            for (x, lag) in [(9.0, 0.0), (12.0, 0.6)] {
                let q = EffectMath.cycle(t, period: 1.8, delay: lag)
                var wisp = c; wisp.opacity = q < 0.4 ? q / 0.4 : 1 - (q - 0.4) / 0.6
                var path = Path(); path.move(to: CGPoint(x: x, y: 8 - q * 4)); path.addQuadCurve(to: CGPoint(x: x + 1, y: 4 - q * 4), control: CGPoint(x: x + 1.5, y: 6.5 - q * 4))
                wisp.stroke(path, with: ink, style: style)
            }
        case .ghost:
            let drift = (1 - cos(2 * .pi * EffectMath.cycle(t, period: 2.2))) / 2
            var ghost = c; ghost.translateBy(x: 2 * drift, y: -3 * drift); ghost.opacity = 1 - 0.45 * drift
            var body = Path()
            body.move(to: CGPoint(x: 6, y: 20)); body.addLine(to: CGPoint(x: 6, y: 10)); body.addArc(center: CGPoint(x: 12, y: 10), radius: 6, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            body.addLine(to: CGPoint(x: 18, y: 20)); body.addLine(to: CGPoint(x: 16, y: 18)); body.addLine(to: CGPoint(x: 14, y: 20)); body.addLine(to: CGPoint(x: 12, y: 18))
            body.addLine(to: CGPoint(x: 10, y: 20)); body.addLine(to: CGPoint(x: 8, y: 18)); body.closeSubpath()
            ghost.stroke(body, with: ink, style: style)
            ghost.fill(Path(ellipseIn: CGRect(x: 9, y: 9, width: 2, height: 2)), with: ink); ghost.fill(Path(ellipseIn: CGRect(x: 13, y: 9, width: 2, height: 2)), with: ink)
        case .moon:
            var moon = c
            let rock = -12 * (1 - cos(2 * .pi * EffectMath.cycle(t, period: 3))) / 2
            moon.translateBy(x: 12, y: 12); moon.rotate(by: .degrees(rock)); moon.translateBy(x: -12, y: -12)
            moon.draw(Text(Image(systemName: "moon.fill")).font(.system(size: 17, weight: .semibold)).foregroundColor(color), at: CGPoint(x: 12, y: 12))
        }
    }
}

