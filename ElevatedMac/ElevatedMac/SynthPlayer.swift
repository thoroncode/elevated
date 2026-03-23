// SynthPlayer.swift
// Generates the Elevated soundtrack via CSynth and plays it via AVAudioEngine.

import Foundation
import AVFoundation
import CSynth

class SynthPlayer {
    static let sampleRate: Double = 44100
    static let totalSamples: AVAudioFrameCount = AVAudioFrameCount(ELEVATED_TOTAL_SAMPLES)

    private let engine   = AVAudioEngine()
    private let player   = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    /// Synthesize and enqueue the audio.  Runs synthesis on a background thread;
    /// calls completion(success) on the main thread when done.
    func synthesize(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fmt = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                    channels: 2)!
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: Self.totalSamples) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            buf.frameLength = Self.totalSamples

            // Allocate flat interleaved buffer for CSynth output
            let n = Int(ELEVATED_TOTAL_SAMPLES) * 2
            let flat = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { flat.deallocate() }

            let durStr = String(format: "%.1f", Double(ELEVATED_TOTAL_SAMPLES) / Self.sampleRate)
            print("[SynthPlayer] Starting synthesis (\(durStr)s)…")
            let t0 = Date()
            elevated_generate_music(flat)
            let elapsed = -t0.timeIntervalSinceNow
            print("[SynthPlayer] Synthesis done in \(String(format: "%.1f", elapsed))s")

            // De-interleave flat [L,R,L,R,…] → AVAudioPCMBuffer (non-interleaved)
            guard let L = buf.floatChannelData?[0],
                  let R = buf.floatChannelData?[1] else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let count = Int(Self.totalSamples)
            // Find peak for normalisation
            var peak: Float = 1e-6
            for i in 0 ..< n {
                let v = flat[i] < 0 ? -flat[i] : flat[i]
                if v > peak { peak = v }
            }
            let gain = 1.0 / peak
            for i in 0 ..< count {
                L[i] = flat[i * 2]     * gain
                R[i] = flat[i * 2 + 1] * gain
            }

            self.buffer = buf
            DispatchQueue.main.async { completion(true) }
        }
    }

    func play() {
        guard let buffer = buffer else { return }

        let fmt = buffer.format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        do {
            try engine.start()
        } catch {
            print("[SynthPlayer] Engine start failed: \(error)")
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
        print("[SynthPlayer] Playback started")
    }

    /// Current playback position in seconds.
    var currentTime: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / Self.sampleRate
    }
}
