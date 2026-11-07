import Testing
import Foundation
import CoreGraphics
@testable import FawalyApp

@Test func everyArtworkHasEffectsInsideImage() {
    for page in AppPage.allCases where page.hasArtwork {
        let effects = ArtScenes.effects(for: page.artwork)
        #expect(!effects.isEmpty, "no effects for \(page.artwork)")
        for placed in effects {
            #expect((0...1).contains(placed.anchor.x) && (0...1).contains(placed.anchor.y), "\(page.artwork) anchor outside image")
        }
    }
}

@Test func livelinessRestsAfterEightSecondsAndWakesOnHover() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var live = Liveliness(now: start)
    let open = MotionGate(reduceMotion: false, lowPower: false, visible: true)
    #expect(live.isLive(at: start.addingTimeInterval(7.9), gate: open))
    #expect(!live.isLive(at: start.addingTimeInterval(8.1), gate: open))
    live.wake(now: start.addingTimeInterval(20))
    #expect(live.isLive(at: start.addingTimeInterval(27), gate: open))
    #expect(live.lastWake == start.addingTimeInterval(20))
}

@Test func reduceMotionLowPowerAndHiddenWindowsNeverLoop() {
    let now = Date()
    let live = Liveliness(now: now)
    #expect(!live.isLive(at: now, gate: MotionGate(reduceMotion: true, lowPower: false, visible: true)))
    #expect(!live.isLive(at: now, gate: MotionGate(reduceMotion: false, lowPower: true, visible: true)))
    #expect(!live.isLive(at: now, gate: MotionGate(reduceMotion: false, lowPower: false, visible: false)))
}

@Test func effectCurvesStayInRange() {
    for step in 0...400 {
        let t = Double(step) * 0.037
        for value in [EffectMath.pulse(t, period: 2.2, from: 0.55, to: 1), EffectMath.rise(t, period: 2.6), EffectMath.pop(t, period: 2.4, from: 0.4, to: 0.85)] {
            #expect((0...1.2).contains(value), "curve value \(value) at \(t)")
        }
    }
    #expect(EffectMath.pulse(0.1, period: 2.2, from: 0.55, to: 1) == 0)
}

@Test func glyphMotionIsStillAtRest() {
    #expect(GlyphMotion.bell(0) == 0)
    #expect(abs(GlyphMotion.bell(1)) < 0.0001)
    #expect(GlyphMotion.lineReveal(index: 2, phase: 0) == 1)
    #expect(GlyphMotion.lineReveal(index: 2, phase: 1) == 1)
    #expect(GlyphMotion.lineReveal(index: 2, phase: 0.2) < 1)
}

@Test func fittedImageRectKeepsAspect() {
    let rect = ArtGeometry.fitted(imageSize: CGSize(width: 1430, height: 1100), in: CGSize(width: 174, height: 154))
    #expect(abs(rect.width - 174) < 0.01)
    #expect(abs(rect.height - 174 * 1100 / 1430) < 0.01)
    #expect(abs(rect.midY - 77) < 0.01)
}
