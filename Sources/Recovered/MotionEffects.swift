import SwiftUI
import AppKit

/// Draws the decorative effects of one illustration at time `t`.
/// `rect` is where the illustration sits inside the canvas; all sizes scale with it.
struct ArtEffectsPainter {
    var effects: [PlacedEffect]
    var rect: CGRect
    var t: Double
    var sinceWake: Double
    var opacity: Double
    var arabic: Bool
    var dark: Bool
    var behind: Bool

    private var k: CGFloat { rect.width / 220 }
    private static let yellow = Color(red: 0.95, green: 0.72, blue: 0.02)
    private static let spark = Color(red: 1, green: 0.81, blue: 0.2)
    private static let brown = Color(red: 0.35, green: 0.27, blue: 0.2)
    private var steamColor: Color { dark ? Color(white: 0.9, opacity: 0.55) : Color(red: 0.47, green: 0.43, blue: 0.39, opacity: 0.6) }

    private func point(_ anchor: UnitPoint) -> CGPoint {
        CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
    }

    func paint(_ context: GraphicsContext) {
        var context = context
        context.opacity = opacity
        for placed in effects where placed.behind == behind {
            let p = point(placed.anchor), d = placed.delay
            switch placed.effect {
            case .steam: steam(context, at: p, delay: d)
            case .glint: glint(context, at: p, delay: d)
            case .coinGlow: coinGlow(context, at: p)
            case .rays: rays(context, at: p)
            case .shine: shine(context, at: p)
            case .fistBump: burst(context, at: p, period: 1.6, angles: [-60, -20, 20, 60], color: Self.yellow, width: 3)
            case .handshake: burst(context, at: p, period: 1.6, angles: [-70, -30, 10, 50, 90], color: Self.yellow, width: 3)
            case .spark: burst(context, at: p, period: 1.1, angles: [-50, 0, 50, 100], color: Self.spark, width: 2)
            case .confetti: confetti(context)
            case .gears: gears(context, at: p)
            case .dust: dust(context, at: p, delay: d)
            case .check: check(context, at: p)
            case .eyes: eyes(context, at: p)
            case .bang: badgeText(context, Text("!").font(.system(size: 20 * k, weight: .heavy)).foregroundColor(Self.yellow), at: p, period: 2, pill: false)
            case .scribble: scribble(context, at: p)
            case .thought: thought(context, at: p)
            case .deal: badgeText(context, Text(arabic ? "اتفقنا!" : "Deal!").font(.system(size: 11 * k, weight: .bold)).foregroundColor(Color(red: 0.17, green: 0.13, blue: 0.01)), at: p, period: 2.6, pill: true)
            }
        }
    }

    private func steam(_ context: GraphicsContext, at p: CGPoint, delay: Double) {
        for (i, (lag, dx)) in [(0.0, 0.0), (0.9, 6.0), (1.7, -6.0)].enumerated() {
            let q = EffectMath.cycle(t, period: 2.6, delay: delay + lag)
            var c = context; c.opacity *= EffectMath.rise(t, period: 2.6, delay: delay + lag)
            let x = p.x + dx * k + CGFloat(q) * 4 * k, y = p.y - CGFloat(q) * 30 * k
            var wisp = Path()
            wisp.move(to: CGPoint(x: x, y: y + 11 * k))
            wisp.addQuadCurve(to: CGPoint(x: x + 2 * k, y: y - 11 * k), control: CGPoint(x: x - (i == 1 ? 6 : 5) * k, y: y))
            c.stroke(wisp, with: .color(steamColor), style: StrokeStyle(lineWidth: 1.8 * k, lineCap: .round))
        }
    }

    private func star(_ size: CGFloat) -> Path {
        var s = Path()
        s.move(to: CGPoint(x: 0, y: -size)); s.addLine(to: CGPoint(x: size * 0.2, y: -size * 0.2)); s.addLine(to: CGPoint(x: size, y: 0))
        s.addLine(to: CGPoint(x: size * 0.2, y: size * 0.2)); s.addLine(to: CGPoint(x: 0, y: size)); s.addLine(to: CGPoint(x: -size * 0.2, y: size * 0.2))
        s.addLine(to: CGPoint(x: -size, y: 0)); s.addLine(to: CGPoint(x: -size * 0.2, y: -size * 0.2)); s.closeSubpath()
        return s
    }

    private func glint(_ context: GraphicsContext, at p: CGPoint, delay: Double) {
        let s = EffectMath.pulse(t, period: 2.2, from: 0.55, to: 1, delay: delay)
        guard s > 0 else { return }
        var c = context; c.translateBy(x: p.x, y: p.y); c.rotate(by: .radians(.pi / 2 * EffectMath.cycle(t, period: 2.2, delay: delay)))
        let shape = star(11 * k * CGFloat(s))
        c.fill(shape, with: .color(Color(red: 1, green: 0.96, blue: 0.78)))
        c.stroke(shape, with: .color(Self.yellow), lineWidth: 0.8 * k)
    }

    private func coinGlow(_ context: GraphicsContext, at p: CGPoint) {
        let g = EffectMath.pulse(t, period: 1.8, from: 0.62, to: 1)
        guard g > 0 else { return }
        let r = CGRect(x: p.x - 40 * k, y: p.y - 16 * k, width: 80 * k, height: 32 * k)
        context.fill(Path(ellipseIn: r), with: .radialGradient(Gradient(colors: [Self.yellow.opacity(0.45 * g), .clear]), center: p, startRadius: 0, endRadius: 40 * k))
    }

    private func rays(_ context: GraphicsContext, at p: CGPoint) {
        var c = context; c.translateBy(x: p.x, y: p.y); c.rotate(by: .radians(2 * .pi * t / 9))
        var wedges = Path()
        for i in 0..<12 {
            let a = Double(i) * .pi / 6
            wedges.move(to: .zero)
            wedges.addArc(center: .zero, radius: 75 * k, startAngle: .radians(a), endAngle: .radians(a + .pi / 18), clockwise: false)
            wedges.closeSubpath()
        }
        c.fill(wedges, with: .radialGradient(Gradient(colors: [Self.yellow.opacity(0.4), Self.yellow.opacity(0.15), .clear]), center: .zero, startRadius: 10 * k, endRadius: 75 * k))
    }

    private func shine(_ context: GraphicsContext, at p: CGPoint) {
        let q = EffectMath.cycle(t, period: 2.8)
        guard q > 0.6 else { return }
        var c = context
        let box = CGRect(x: p.x - 17 * k, y: p.y - 20 * k, width: 34 * k, height: 40 * k)
        c.clip(to: Path(roundedRect: box, cornerRadius: 6 * k))
        let x = box.minX - 20 * k + CGFloat((q - 0.6) / 0.4) * (box.width + 40 * k)
        var band = Path(); band.move(to: CGPoint(x: x, y: box.minY - 4 * k)); band.addLine(to: CGPoint(x: x + 8 * k, y: box.minY - 4 * k))
        band.addLine(to: CGPoint(x: x - 6 * k, y: box.maxY + 4 * k)); band.addLine(to: CGPoint(x: x - 14 * k, y: box.maxY + 4 * k)); band.closeSubpath()
        c.fill(band, with: .color(.white.opacity(0.8)))
    }

    private func burst(_ context: GraphicsContext, at p: CGPoint, period: Double, angles: [Double], color: Color, width: CGFloat) {
        let q = EffectMath.cycle(t, period: period)
        guard q > 0.6 else { return }
        let u = (q - 0.6) / 0.4
        var c = context; c.opacity *= u < 0.25 ? u / 0.25 : 1 - (u - 0.25) / 0.75
        let inner = (4 + 16 * u) * Double(k), length = 10 * (0.4 + 0.6 * u) * Double(k)
        for degrees in angles {
            let r = degrees * .pi / 180, dx = sin(r), dy = -cos(r)
            var line = Path()
            line.move(to: CGPoint(x: p.x + dx * inner, y: p.y + dy * inner))
            line.addLine(to: CGPoint(x: p.x + dx * (inner + length), y: p.y + dy * (inner + length)))
            c.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: width * k, lineCap: .round))
        }
    }

    private func confetti(_ context: GraphicsContext) {
        let colors: [Color] = [Self.yellow, Color(red: 0.9, green: 0.33, blue: 0.24), Color(red: 0.23, green: 0.61, blue: 0.29), Color(red: 0.23, green: 0.48, blue: 0.84), .white]
        func noise(_ i: Int, _ salt: Double) -> Double { let v = sin(Double(i) * 12.9898 + salt) * 43758.5453; return v - floor(v) }
        for i in 0..<26 {
            let duration = 1.4 + 1.2 * noise(i, 1), delay = 0.4 * noise(i, 2)
            let u = (sinceWake - delay) / duration
            guard u > 0, u < 1 else { continue }
            var c = context; c.opacity *= 1 - u
            c.translateBy(x: rect.minX + (0.2 + 0.6 * noise(i, 3)) * rect.width, y: rect.minY - 10 * k + CGFloat(u) * 240 * k)
            c.rotate(by: .radians(u * 3 * .pi))
            c.fill(Path(roundedRect: CGRect(x: -3 * k, y: -4.5 * k, width: 6 * k, height: 9 * k), cornerRadius: k), with: .color(colors[i % colors.count]))
        }
    }

    private func gear(radius: CGFloat, teeth: Int) -> Path {
        var g = Path()
        for i in 0..<(teeth * 2) {
            let a = Double(i) * .pi / Double(teeth), r = i.isMultiple(of: 2) ? radius : radius * 0.78
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { g.move(to: pt) } else { g.addLine(to: pt) }
        }
        g.closeSubpath()
        g.addEllipse(in: CGRect(x: -radius * 0.3, y: -radius * 0.3, width: radius * 0.6, height: radius * 0.6))
        return g
    }

    private func gears(_ context: GraphicsContext, at p: CGPoint) {
        for (offset, radius, period, fill) in [(CGPoint(x: -0.02, y: -0.04), 13.0, 4.0, Self.yellow), (CGPoint(x: 0.07, y: 0.08), 9.0, -2.7, Color(red: 0.81, green: 0.78, blue: 0.71))] {
            var c = context
            c.translateBy(x: p.x + offset.x * rect.width, y: p.y + offset.y * rect.height)
            c.rotate(by: .radians(2 * .pi * t / period))
            let shape = gear(radius: CGFloat(radius) * k, teeth: 8)
            c.fill(shape, with: .color(fill), style: FillStyle(eoFill: true))
            c.stroke(shape, with: .color(Self.brown), lineWidth: 0.8 * k)
        }
    }

    private func dust(_ context: GraphicsContext, at p: CGPoint, delay: Double) {
        let q = EffectMath.cycle(t, period: 1.24, delay: delay)
        var c = context; c.opacity *= 0.8 * (1 - q)
        let s = CGFloat(0.3 + 1.5 * q)
        let r = CGRect(x: p.x - 8 * k * s, y: p.y - 4 * k * s - CGFloat(q) * 3 * k, width: 16 * k * s, height: 8 * k * s)
        c.fill(Path(ellipseIn: r), with: .color(Color(red: 0.63, green: 0.55, blue: 0.43, opacity: 0.45)))
    }

    private func check(_ context: GraphicsContext, at p: CGPoint) {
        let s = CGFloat(EffectMath.pop(t, period: 2.4, from: 0.4, to: 0.85))
        guard s > 0 else { return }
        var c = context; c.translateBy(x: p.x, y: p.y); c.scaleBy(x: s, y: s)
        c.fill(Path(ellipseIn: CGRect(x: -13 * k, y: -13 * k, width: 26 * k, height: 26 * k)), with: .color(Color(red: 0.23, green: 0.61, blue: 0.29)))
        var mark = Path(); mark.move(to: CGPoint(x: -6 * k, y: 0)); mark.addLine(to: CGPoint(x: -1.5 * k, y: 5 * k)); mark.addLine(to: CGPoint(x: 6.5 * k, y: -5 * k))
        c.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: 2.6 * k, lineCap: .round, lineJoin: .round))
    }

    private func eyes(_ context: GraphicsContext, at p: CGPoint) {
        let g = 0.25 + 0.75 * (0.5 + 0.5 * cos(2 * .pi * EffectMath.cycle(t, period: 1.4)))
        let r = CGRect(x: p.x - 18 * k, y: p.y - 8 * k, width: 36 * k, height: 16 * k)
        context.fill(Path(ellipseIn: r), with: .radialGradient(Gradient(colors: [Color(red: 0.31, green: 0.86, blue: 1).opacity(0.75 * g), .clear]), center: p, startRadius: 0, endRadius: 18 * k))
    }

    private func badgeText(_ context: GraphicsContext, _ text: Text, at p: CGPoint, period: Double, pill: Bool) {
        let s = CGFloat(EffectMath.pop(t, period: period, from: 0.4, to: 0.85))
        guard s > 0 else { return }
        var c = context; c.translateBy(x: p.x, y: p.y); c.scaleBy(x: s, y: s)
        let resolved = c.resolve(text)
        if pill {
            let size = resolved.measure(in: CGSize(width: 200 * k, height: 60 * k))
            let box = CGRect(x: -size.width / 2 - 7 * k, y: -size.height / 2 - 1 * k, width: size.width + 14 * k, height: size.height + 2 * k)
            c.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(Self.yellow))
        }
        c.draw(resolved, at: .zero)
    }

    private func scribble(_ context: GraphicsContext, at p: CGPoint) {
        let q = EffectMath.cycle(t, period: 2.8)
        var c = context; c.opacity *= q < 0.85 ? 1 : 1 - (q - 0.85) / 0.15
        c.translateBy(x: p.x - 32 * k, y: p.y - 13 * k); c.scaleBy(x: k, y: k)
        var lines = Path()
        lines.move(to: CGPoint(x: 2, y: 8)); lines.addCurve(to: CGPoint(x: 22, y: 8), control1: CGPoint(x: 10, y: 2), control2: CGPoint(x: 14, y: 14))
        lines.addCurve(to: CGPoint(x: 40, y: 8), control1: CGPoint(x: 30, y: 2), control2: CGPoint(x: 34, y: 2))
        lines.move(to: CGPoint(x: 4, y: 18)); lines.addCurve(to: CGPoint(x: 26, y: 17), control1: CGPoint(x: 12, y: 13), control2: CGPoint(x: 18, y: 22))
        lines.addCurve(to: CGPoint(x: 46, y: 18), control1: CGPoint(x: 34, y: 12), control2: CGPoint(x: 38, y: 13))
        c.stroke(lines.trimmedPath(from: 0, to: min(1, q / 0.6)), with: .color(Self.brown), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    private func thought(_ context: GraphicsContext, at p: CGPoint) {
        let symbols = ["dollarsign.circle.fill", "hammer.fill", "gearshape.fill", "cup.and.saucer.fill"]
        var c = context; c.translateBy(x: p.x, y: p.y - CGFloat(sin(2 * .pi * t / 3)) * 2.5 * k)
        let bubble = CGRect(x: -21 * k, y: -16 * k, width: 42 * k, height: 32 * k)
        let paper = Color(nsColor: .controlBackgroundColor), edge = Color.primary.opacity(0.18)
        c.fill(Path(roundedRect: bubble, cornerRadius: 16 * k), with: .color(paper))
        c.stroke(Path(roundedRect: bubble, cornerRadius: 16 * k), with: .color(edge), lineWidth: 1.2 * k)
        let tail = CGRect(x: -16 * k, y: 18 * k, width: 7 * k, height: 7 * k)
        c.fill(Path(ellipseIn: tail), with: .color(paper)); c.stroke(Path(ellipseIn: tail), with: .color(edge), lineWidth: 1.2 * k)
        let symbol = symbols[Int(floor(t / 1.5)) % symbols.count]
        c.draw(Text(Image(systemName: symbol)).font(.system(size: 15 * k)).foregroundColor(Self.yellow), at: .zero)
    }
}
