//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import Defaults
import SwiftUI

class MusicVisualizerModel: NSView, AudioCaptureLevelsConsumer {
    private var barLayers: [CAGradientLayer] = []
    private var isPlaying = false
    private var isActive = true
    private var useRealtime = false
    private var tintColor: NSColor = .systemBlue
    private var lastTintColor: NSColor?
    private var rainbowEnabled = false
    private static let rainbowKey = "rainbowColors"
    private static let rainbowSteps = 12
    private static let baseRainbowCycleSeconds: CFTimeInterval = 12
    private var rainbowCycleSeconds: CFTimeInterval = 12
    private var rainbowSpeed: Double = 1

    private weak var attachedManager: AudioCaptureManager?
    private var lastAppliedLevels: [Float]
    private static let levelChangeThreshold: Float = 0.005
    private static let minBarScale: CGFloat = 0.12
    private static let idleBarScale: CGFloat = 0.3
    private static let animationKey = "scaleAnimation"

    private let barWidth: CGFloat = 2
    private let barCount = AudioCaptureManager.barCount
    private let spacing: CGFloat = 1
    private let totalHeight: CGFloat = 14

    override init(frame frameRect: NSRect) {
        self.lastAppliedLevels = [Float](repeating: 0, count: AudioCaptureManager.barCount)
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        self.lastAppliedLevels = [Float](repeating: 0, count: AudioCaptureManager.barCount)
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    deinit {
        attachedManager?.clearLevelsConsumer(self)
    }

    private func setupBars() {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        if frame.width < totalWidth {
            frame.size = CGSize(width: totalWidth, height: totalHeight)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        for i in 0..<barCount {
            let barLayer = CAGradientLayer()
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            applyFrame(to: barLayer, at: i, height: barWidth)
            barLayer.cornerRadius = barWidth / 2
            barLayer.contentsScale = scale
            barLayer.shouldRasterize = false
            barLayer.startPoint = CGPoint(x: 0.5, y: 0)
            barLayer.endPoint = CGPoint(x: 0.5, y: 1)
            barLayer.colors = [tintColor.withAlphaComponent(0.6).cgColor, tintColor.cgColor]
            layer?.addSublayer(barLayer)
            barLayers.append(barLayer)
        }
    }

    private func expandBars(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (index, barLayer) in barLayers.enumerated() {
            applyFrame(to: barLayer, at: index, height: totalHeight)
            barLayer.transform = CATransform3DMakeScale(1.0, Self.idleBarScale, 1.0)
        }
        CATransaction.commit()
    }

    private func collapseBarsToDots() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (index, barLayer) in barLayers.enumerated() {
            barLayer.removeAnimation(forKey: Self.animationKey)
            barLayer.transform = CATransform3DIdentity
            applyFrame(to: barLayer, at: index, height: barWidth)
        }
        CATransaction.commit()
    }

    private func startRandomAnimating() {
        for (index, barLayer) in barLayers.enumerated() {
            animateBar(barLayer, delay: Double(index) * 0.08)
        }
    }

    private func animateBar(_ barLayer: CAGradientLayer, delay: Double = 0) {
        guard isPlaying else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        var values: [CGFloat] = []
        var keyTimes: [NSNumber] = []
        let numSteps = 50
        let startValue = CGFloat.random(in: 0.3...1.0)
        for i in 0...numSteps {
            if i == 0 || i == numSteps {
                values.append(startValue)
            } else {
                values.append(CGFloat.random(in: 0.3...1.0))
            }
            keyTimes.append(NSNumber(value: Double(i) / Double(numSteps)))
        }
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = 15
        animation.repeatCount = .infinity
        animation.calculationMode = .cubic
        animation.beginTime = CACurrentMediaTime() + delay
        if #available(macOS 12.0, *) {
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.transform = CATransform3DMakeScale(1.0, startValue, 1.0)
        CATransaction.commit()
        barLayer.add(animation, forKey: Self.animationKey)
    }

    private func stopRandomAnimating() {
        for barLayer in barLayers {
            barLayer.removeAnimation(forKey: Self.animationKey)
        }
    }

    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        updateRainbowAnimation()
        if playing {
            expandBars(animated: true)
            if !useRealtime {
                startRandomAnimating()
            }
        } else {
            collapseBarsToDots()
        }
    }

    func setUseRealtime(_ enabled: Bool) {
        guard useRealtime != enabled else { return }
        useRealtime = enabled
        // Force the next incoming frame through the threshold guard.
        for i in 0..<lastAppliedLevels.count { lastAppliedLevels[i] = -1 }
        guard isPlaying else { return }
        if enabled {
            stopRandomAnimating()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for barLayer in barLayers {
                barLayer.transform = CATransform3DMakeScale(1.0, Self.idleBarScale, 1.0)
            }
            CATransaction.commit()
            startRandomAnimating()
        }
    }

    func attach(to manager: AudioCaptureManager) {
        guard attachedManager !== manager else { return }
        attachedManager?.clearLevelsConsumer(self)
        attachedManager = manager
        if isActive { manager.setLevelsConsumer(self) }
    }

    /// An inactive view (the closed-notch waveform while the notch is open)
    /// asks for no levels, so nothing is computed or delivered for it.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        guard let manager = attachedManager else { return }
        if active {
            manager.setLevelsConsumer(self)
        } else {
            manager.clearLevelsConsumer(self)
        }
    }

    func syncCurrentLevels(from manager: AudioCaptureManager) {
        guard attachedManager === manager,
              let values = manager.latestLevelsSnapshot() else { return }
        applyLevels(values)
    }

    func audioCaptureManager(_ manager: AudioCaptureManager, didProduceLevels values: [Float]) {
        applyLevels(values)
    }

    private func applyLevels(_ values: [Float]) {
        guard isPlaying, useRealtime, values.count == barCount else { return }
        var maxDelta: Float = 0
        for i in 0..<barCount {
            let d = abs(values[i] - lastAppliedLevels[i])
            if d > maxDelta { maxDelta = d }
        }
        guard maxDelta >= Self.levelChangeThreshold else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barCount {
            let v = values[i]
            lastAppliedLevels[i] = v
            let clamped = max(Self.minBarScale, min(1.0, CGFloat(v)))
            barLayers[i].transform = CATransform3DMakeScale(1.0, clamped, 1.0)
        }
        CATransaction.commit()
    }

    func setTintColor(_ color: NSColor) {
        if let last = lastTintColor, last.isEqual(color) { return }
        lastTintColor = color
        tintColor = color
        guard !rainbowEnabled else { return }
        applyTintColors()
    }

    private func applyTintColors() {
        let colors = [tintColor.withAlphaComponent(0.6).cgColor, tintColor.cgColor]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayers.forEach { $0.colors = colors }
        CATransaction.commit()
    }

    // MARK: Rainbow

    func setRainbow(_ enabled: Bool) {
        guard rainbowEnabled != enabled else { return }
        rainbowEnabled = enabled
        if enabled {
            setStaticRainbowColors()
        } else {
            applyTintColors()
        }
        updateRainbowAnimation()
    }

    /// Speed 1 is one full turn of hues in 12 seconds; 2 is twice as fast;
    /// 0 holds the colors still.
    func setRainbowSpeed(_ speed: Double) {
        let speed = max(0, speed)
        guard speed != rainbowSpeed else { return }
        rainbowSpeed = speed
        if speed > 0 { rainbowCycleSeconds = Self.baseRainbowCycleSeconds / speed }
        // The animation's duration is fixed once added, so swap it for a new one.
        for barLayer in barLayers { barLayer.removeAnimation(forKey: Self.rainbowKey) }
        updateRainbowAnimation()
    }

    /// The hue drift is a Core Animation loop, so the render server advances
    /// it by itself and the app does no per-frame work. It only exists while
    /// the bars are moving.
    private func updateRainbowAnimation() {
        let shouldAnimate = rainbowEnabled && isPlaying && rainbowSpeed > 0
        for (index, barLayer) in barLayers.enumerated() {
            let running = barLayer.animation(forKey: Self.rainbowKey) != nil
            if shouldAnimate && !running {
                barLayer.add(rainbowAnimation(forBar: index), forKey: Self.rainbowKey)
            } else if !shouldAnimate && running {
                barLayer.removeAnimation(forKey: Self.rainbowKey)
            }
        }
    }

    private func rainbowColors(forBar index: Int, phase: CGFloat) -> [CGColor] {
        let hue = (CGFloat(index) / CGFloat(barCount) * 0.85 + phase).truncatingRemainder(dividingBy: 1)
        let top = NSColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1.0)
        let bottom = NSColor(
            hue: (hue + 0.06).truncatingRemainder(dividingBy: 1),
            saturation: 0.9, brightness: 0.85, alpha: 0.7
        )
        return [bottom.cgColor, top.cgColor]
    }

    private func rainbowAnimation(forBar index: Int) -> CAKeyframeAnimation {
        let steps = Self.rainbowSteps
        let animation = CAKeyframeAnimation(keyPath: "colors")
        // The last keyframe is a full turn, equal to the first, so the loop is seamless.
        animation.values = (0...steps).map { rainbowColors(forBar: index, phase: CGFloat($0) / CGFloat(steps)) }
        animation.duration = rainbowCycleSeconds
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        if #available(macOS 12.0, *) {
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 12)
        }
        return animation
    }

    private func setStaticRainbowColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            barLayer.colors = rainbowColors(forBar: index, phase: 0)
        }
        CATransaction.commit()
    }

    private func applyFrame(to barLayer: CALayer, at index: Int, height: CGFloat) {
        let x = CGFloat(index) * (barWidth + spacing)
        barLayer.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
        barLayer.position = CGPoint(x: x + barWidth / 2, y: totalHeight / 2)
    }
}

struct MusicVisualizer: NSViewRepresentable {
    let isPlaying: Bool
    let tintColor: Color
    /// False when this waveform isn't on screen, so it stops asking for levels.
    var isActive: Bool = true
    @Default(.realtimeAudioWaveform) var realtimeEnabled: Bool
    @Default(.rainbowWaveform) var rainbowEnabled: Bool
    @Default(.rainbowWaveformSpeed) var rainbowSpeed: Double
    @ObservedObject private var audioCapture = AudioCaptureManager.shared

    func makeNSView(context: Context) -> MusicVisualizerModel {
        let spectrum = MusicVisualizerModel()
        spectrum.setActive(isActive)
        spectrum.setTintColor(NSColor(tintColor))
        spectrum.setRainbowSpeed(rainbowSpeed)
        spectrum.setRainbow(rainbowEnabled)
        spectrum.setUseRealtime(realtimeEnabled && audioCapture.isCapturing)
        spectrum.setPlaying(isPlaying)
        spectrum.attach(to: audioCapture)
        spectrum.syncCurrentLevels(from: audioCapture)
        return spectrum
    }

    func updateNSView(_ nsView: MusicVisualizerModel, context: Context) {
        nsView.setActive(isActive)
        nsView.setTintColor(NSColor(tintColor))
        nsView.setRainbowSpeed(rainbowSpeed)
        nsView.setRainbow(rainbowEnabled)
        nsView.setUseRealtime(realtimeEnabled && audioCapture.isCapturing)
        nsView.setPlaying(isPlaying)
        nsView.syncCurrentLevels(from: audioCapture)
    }
}

#Preview {
    ZStack {
        Color.black
        MusicVisualizer(isPlaying: true, tintColor: .green)
            .frame(width: 18, height: 14)
    }
    .padding()
}
