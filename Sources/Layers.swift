import AppKit
import SwiftUI

// Looping animations as Core Animation layers: the window server renders them, so the app itself
// stays idle (no SwiftUI body re-evaluation per frame).

private class LayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct Equalizer: NSViewRepresentable {
    var color: Color
    var playing: Bool

    func makeNSView(context: Context) -> NSView { EqualizerView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? EqualizerView)?.update(color: NSColor(color), playing: playing)
    }

    private final class EqualizerView: LayerView {
        private let bars = (0..<4).map { _ in CALayer() }
        private var playing: Bool?

        override init(frame: NSRect) {
            super.init(frame: frame)
            for bar in bars {
                bar.cornerRadius = 1.25
                bar.anchorPoint = CGPoint(x: 0.5, y: 1)
                layer?.addSublayer(bar)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let gap: CGFloat = 2, width = (bounds.width - gap * 3) / 4
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
                bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: bounds.height)
            }
            CATransaction.commit()
        }

        func update(color: NSColor, playing: Bool) {
            for bar in bars { bar.backgroundColor = color.cgColor }
            guard playing != self.playing else { return }
            self.playing = playing
            // Gentle, unhurried swells: a narrower range, staggered so the bars never move in lockstep.
            let patterns: [[CGFloat]] = [
                [0.4, 0.75, 0.5, 0.9, 0.45], [0.7, 0.4, 0.85, 0.5, 0.65],
                [0.5, 0.9, 0.45, 0.7, 0.55], [0.8, 0.5, 0.65, 0.4, 0.75],
            ]
            for (index, bar) in bars.enumerated() {
                bar.removeAllAnimations()
                if playing {
                    let wave = CAKeyframeAnimation(keyPath: "transform.scale.y")
                    wave.values = patterns[index] + [patterns[index][0]]
                    wave.duration = [2.6, 3.1, 2.3, 2.8][index]
                    wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    wave.calculationMode = .cubic
                    wave.repeatCount = .infinity
                    wave.isRemovedOnCompletion = false
                    bar.add(wave, forKey: "wave")
                } else {
                    bar.transform = CATransform3DMakeScale(1, 0.25, 1)
                }
            }
        }
    }
}

/// "An agent is thinking": a four-point sparkle filled with slowly flowing Apple Intelligence colours.
/// It twinkles a quarter turn, rests, and repeats, while a tiny companion sparkle blinks beside it.
struct Thinking: NSViewRepresentable {
    var size: CGFloat

    func makeNSView(context: Context) -> NSView { ThinkingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    private final class ThinkingView: LayerView {
        private let colors = CALayer()       // masked by the star, so the flow stays inside it
        private let gradient = CAGradientLayer()
        private let star = CAShapeLayer()
        private let spark = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = [
                NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1), // orange
                NSColor(srgbRed: 1, green: 0.22, blue: 0.37, alpha: 1), // pink
                NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), // purple
                NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1), // blue
                NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1), // cyan
                NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1),
            ].map(\.cgColor)
            colors.addSublayer(gradient)
            colors.mask = star
            layer?.addSublayer(colors)
            spark.fillColor = NSColor.white.withAlphaComponent(0.9).cgColor
            spark.opacity = 0
            layer?.addSublayer(spark)

            let flow = CABasicAnimation(keyPath: "transform.rotation.z")
            flow.fromValue = 0
            flow.toValue = -Double.pi * 2
            flow.duration = 4
            flow.repeatCount = .infinity
            flow.isRemovedOnCompletion = false
            gradient.add(flow, forKey: "flow")

            // A quarter turn lands on the same silhouette, so the loop is seamless.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Double.pi / 2
            turn.duration = 1.1
            turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
            let breathe = CAKeyframeAnimation(keyPath: "transform.scale")
            breathe.values = [1, 0.62, 1.06, 1]
            breathe.keyTimes = [0, 0.45, 0.8, 1]
            breathe.duration = 1.1
            breathe.timingFunctions = [.init(name: .easeInEaseOut), .init(name: .easeOut), .init(name: .easeInEaseOut)]
            star.add(Self.loop([turn, breathe], every: 2), forKey: "twinkle")

            // The companion blinks while the big one rests.
            let blinkScale = CAKeyframeAnimation(keyPath: "transform.scale")
            blinkScale.values = [0.2, 1, 0.2]
            let blinkFade = CAKeyframeAnimation(keyPath: "opacity")
            blinkFade.values = [0, 1, 0]
            for blink in [blinkScale, blinkFade] {
                blink.duration = 0.7
                blink.beginTime = 1.1
                blink.timingFunctions = [.init(name: .easeOut), .init(name: .easeIn)]
            }
            spark.add(Self.loop([blinkScale, blinkFade], every: 2), forKey: "blink")
        }

        required init?(coder: NSCoder) { fatalError() }

        private static func loop(_ animations: [CAAnimation], every period: CFTimeInterval) -> CAAnimationGroup {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = period
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            return group
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = min(bounds.width, bounds.height)
            colors.frame = bounds
            let diagonal = side * 1.5 // covers the bounds at any rotation
            gradient.frame = CGRect(x: bounds.midX - diagonal / 2, y: bounds.midY - diagonal / 2, width: diagonal, height: diagonal)
            let main = side * 0.82
            star.frame = CGRect(x: 0, y: bounds.height - main, width: main, height: main)
            star.path = Self.sparkle(in: CGRect(origin: .zero, size: star.frame.size))
            let small = side * 0.36
            spark.frame = CGRect(x: bounds.width - small, y: 0, width: small, height: small)
            spark.path = Self.sparkle(in: CGRect(origin: .zero, size: spark.frame.size))
            CATransaction.commit()
        }

        /// Four points joined by curves pulled toward the centre: the familiar AI sparkle.
        private static func sparkle(in rect: CGRect) -> CGPath {
            let c = CGPoint(x: rect.midX, y: rect.midY), r = rect.width / 2, pinch = r * 0.2
            let tips = [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y),
                        CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)]
            let path = CGMutablePath()
            path.move(to: tips[0])
            for index in 0..<4 {
                let a = tips[index], b = tips[(index + 1) % 4]
                // The control point sits just off the centre, in the corner between the two tips.
                let control = CGPoint(x: c.x + (a.x + b.x > 2 * c.x ? pinch : -pinch),
                                      y: c.y + (a.y + b.y > 2 * c.y ? pinch : -pinch))
                path.addCurve(to: b, control1: control, control2: control)
            }
            path.closeSubpath()
            return path
        }
    }
}

struct Pulse: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> NSView { PulseView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? PulseView)?.ring.backgroundColor = NSColor(color).cgColor
    }

    private final class PulseView: LayerView {
        let ring = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.addSublayer(ring)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.7
            scale.toValue = 1.35
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.6
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.4
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.cornerRadius = bounds.width / 2
            CATransaction.commit()
        }
    }
}
