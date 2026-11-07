import Foundation
import CoreGraphics
import SwiftUI

/// Everything that may stop decorative motion: the user's Reduce Motion setting,
/// Low Power Mode and a window that isn't the active one.
struct MotionGate: Equatable {
    var reduceMotion: Bool
    var lowPower: Bool
    var visible: Bool
    var allowsMotion: Bool { !reduceMotion && !lowPower && visible }
}

/// Decorative loops play for a short spell after appearing or being hovered, then rest.
struct Liveliness: Equatable {
    static let activeSpan: TimeInterval = 8
    private(set) var lastWake: Date
    private(set) var liveUntil: Date
    init(now: Date) { lastWake = now; liveUntil = now.addingTimeInterval(Self.activeSpan) }
    mutating func wake(now: Date) { lastWake = now; liveUntil = max(liveUntil, now.addingTimeInterval(Self.activeSpan)) }
    func isLive(at now: Date, gate: MotionGate) -> Bool { gate.allowsMotion && now < liveUntil }
}

enum EffectMath {
    /// Position inside a repeating cycle, 0..<1.
    static func cycle(_ t: Double, period: Double, delay: Double = 0) -> Double {
        let x = (t - delay) / period
        return x - floor(x)
    }
    /// 0 outside `from...to`, a smooth 0→1→0 hump inside it.
    static func pulse(_ t: Double, period: Double, from: Double, to: Double, delay: Double = 0) -> Double {
        let p = cycle(t, period: period, delay: delay)
        guard p > from, p < to else { return 0 }
        return sin(.pi * (p - from) / (to - from))
    }
    /// Rising wisp: opacity peaks early, fades as it climbs.
    static func rise(_ t: Double, period: Double, delay: Double = 0) -> Double {
        let p = cycle(t, period: period, delay: delay)
        return p < 0.25 ? p / 0.25 * 0.9 : 0.9 * (1 - (p - 0.25) / 0.75)
    }
    /// Overshooting pop-in that holds, then shrinks away: a scale value (may exceed 1 briefly).
    static func pop(_ t: Double, period: Double, from: Double, to: Double, delay: Double = 0) -> Double {
        let p = cycle(t, period: period, delay: delay)
        guard p > from else { return 0 }
        if p > to { return max(0, 1 - (p - to) / (1 - to)) }
        let x = min(1, (p - from) / 0.12)
        return x < 1 ? x * (1 + 0.18 * sin(.pi * x)) : 1
    }
}

enum GlyphMotion {
    static let duration: TimeInterval = 0.75
    /// 0 at rest on both ends, 1 at the middle of the gesture.
    static func bell(_ phase: Double) -> Double { sin(.pi * min(max(phase, 0), 1)) }
    /// Notebook lines write themselves in one after another; fully drawn at rest.
    static func lineReveal(index: Int, phase: Double) -> Double {
        guard phase > 0, phase < 1 else { return 1 }
        return min(1, max(0.05, (phase * 1.4 - Double(index) * 0.15) / 0.6))
    }
}

enum ArtGeometry {
    /// Aspect-fit rectangle of an image inside a frame, centred like `.scaledToFit()`.
    static func fitted(imageSize: CGSize, in frame: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let scale = min(frame.width / imageSize.width, frame.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width, height: size.height)
    }
}

enum ArtEffect: Equatable {
    case steam, glint, coinGlow, rays, shine, fistBump, confetti, gears, spark, dust, check, eyes, bang, scribble, thought, handshake, deal
}

struct PlacedEffect: Equatable {
    var effect: ArtEffect
    /// Position on the illustration itself, 0...1 on both axes.
    var anchor: UnitPoint
    var delay: Double = 0
    var behind: Bool { effect == .rays }
}

enum IdleStyle { case breathe, step }

/// Anchor points were placed by eye on the bundled illustrations (see the motion preview).
enum ArtScenes {
    static func idle(for artwork: String) -> IdleStyle { artwork == "shift" ? .step : .breathe }
    static func effects(for artwork: String) -> [PlacedEffect] {
        switch artwork {
        case "shift":
            return [PlacedEffect(effect: .dust, anchor: UnitPoint(x: 0.16, y: 0.95)), PlacedEffect(effect: .dust, anchor: UnitPoint(x: 0.42, y: 0.94), delay: 0.4),
                    PlacedEffect(effect: .dust, anchor: UnitPoint(x: 0.74, y: 0.96), delay: 0.8), PlacedEffect(effect: .check, anchor: UnitPoint(x: 0.86, y: 0.20))]
        case "usage":
            return [PlacedEffect(effect: .glint, anchor: UnitPoint(x: 0.31, y: 0.29)), PlacedEffect(effect: .steam, anchor: UnitPoint(x: 0.21, y: 0.72)),
                    PlacedEffect(effect: .coinGlow, anchor: UnitPoint(x: 0.54, y: 0.78))]
        case "contest":
            return [PlacedEffect(effect: .rays, anchor: UnitPoint(x: 0.51, y: 0.72)), PlacedEffect(effect: .shine, anchor: UnitPoint(x: 0.515, y: 0.66)),
                    PlacedEffect(effect: .fistBump, anchor: UnitPoint(x: 0.54, y: 0.35)), PlacedEffect(effect: .confetti, anchor: UnitPoint(x: 0.5, y: 0.05))]
        case "settings":
            return [PlacedEffect(effect: .spark, anchor: UnitPoint(x: 0.62, y: 0.71)), PlacedEffect(effect: .gears, anchor: UnitPoint(x: 0.86, y: 0.26)),
                    PlacedEffect(effect: .steam, anchor: UnitPoint(x: 0.22, y: 0.76))]
        case "discovery":
            return [PlacedEffect(effect: .glint, anchor: UnitPoint(x: 0.72, y: 0.57)), PlacedEffect(effect: .eyes, anchor: UnitPoint(x: 0.64, y: 0.635)),
                    PlacedEffect(effect: .bang, anchor: UnitPoint(x: 0.57, y: 0.47))]
        case "worklog":
            return [PlacedEffect(effect: .scribble, anchor: UnitPoint(x: 0.42, y: 0.74)), PlacedEffect(effect: .steam, anchor: UnitPoint(x: 0.89, y: 0.72)),
                    PlacedEffect(effect: .thought, anchor: UnitPoint(x: 0.84, y: 0.11))]
        case "contractors":
            return [PlacedEffect(effect: .handshake, anchor: UnitPoint(x: 0.45, y: 0.51)), PlacedEffect(effect: .deal, anchor: UnitPoint(x: 0.45, y: 0.36))]
        default:
            return []
        }
    }
}
