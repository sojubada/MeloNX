//
//  TVMenuMusic.swift
//  MeloNX tvOS
//
//  Background music on the game library screen.
//
//  - A file in <data root>/music/ (.mp3 .m4a .aac .wav .caf .aiff) is played in
//    a loop if present, so any track of your own can be used.
//  - Otherwise a short original tune is synthesised at launch (no bundled audio):
//    soft pad, plucked arpeggio, bass and a bell melody over C–Am–F–G, ~21 s loop.
//
//  Plays only while the library is on screen: stops when a game starts or the
//  app goes to the background, and follows the 메뉴 음악 settings.
//

import AVFoundation
import Combine
import UIKit

final class TVMenuMusic {
    static let shared = TVMenuMusic()

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var buffer: AVAudioPCMBuffer?
    private var scheduled = false
    private var filePlayer: AVAudioPlayer?
    private var appActive = true
    private var started = false
    private var rendering = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "caf", "aiff", "aif"]

    var musicFolder: URL { TVPaths.root.appendingPathComponent("music", isDirectory: true) }

    /// Called once after launch.
    func start() {
        guard !started else { return }
        started = true

        try? FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        TVSettings.shared.$values
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        TVEmulator.shared.$state
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true
            self?.update()
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = false
            self?.update()
        }

        update()
    }

    // MARK: Play / pause

    private var shouldPlay: Bool {
        TVSettings.shared.values.menuMusic && appActive && !TVEmulator.shared.isRunning
    }

    func update() {
        if shouldPlay {
            play(volume: TVSettings.shared.values.menuMusicVolume)
        } else {
            pause()
        }
    }

    private func customTrack() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: musicFolder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func play(volume: Float) {
        if let url = customTrack() {
            if filePlayer?.url != url {
                filePlayer?.stop()
                filePlayer = try? AVAudioPlayer(contentsOf: url)
                filePlayer?.numberOfLoops = -1
                filePlayer?.prepareToPlay()
                TVLog.write("menu music: \(url.lastPathComponent)")
            }
            if let filePlayer {
                if node.isPlaying { node.pause() }
                filePlayer.volume = volume
                if !filePlayer.isPlaying { filePlayer.play() }
                return
            }
        }

        filePlayer?.stop()
        filePlayer = nil

        guard let buffer else {
            renderBuiltInTune()        // only when no file of your own is used
            return
        }
        node.volume = volume
        if !engine.isRunning {
            do { try engine.start() } catch {
                TVLog.write("menu music: engine start failed: \(error.localizedDescription)")
                return
            }
        }
        if !scheduled {
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            scheduled = true
        }
        if !node.isPlaying { node.play() }
    }

    private func pause() {
        if TVEmulator.shared.isRunning {
            // A game owns the audio hardware now: release ours completely
            filePlayer?.stop()
            node.stop()
            scheduled = false
            if engine.isRunning { engine.stop() }
        } else {
            filePlayer?.pause()
            if node.isPlaying { node.pause() }
            if engine.isRunning { engine.pause() }
        }
    }

    private func renderBuiltInTune() {
        guard !rendering else { return }
        rendering = true
        let format = self.format
        DispatchQueue.global(qos: .utility).async {
            let rendered = TVMenuMusic.render(format: format)
            DispatchQueue.main.async {
                self.buffer = rendered
                self.rendering = false
                self.update()
            }
        }
    }

    // MARK: Built-in tune

    nonisolated private static func freq(_ midi: Int) -> Double {
        440.0 * pow(2.0, Double(midi - 69) / 12.0)
    }

    /// Adds one note into the stereo loop (wrapping round the end so the loop
    /// is seamless). `wave` gives the waveform for a phase in radians.
    nonisolated private static func addNote(_ l: inout [Float], _ r: inout [Float], sr: Double,
                                            start: Double, length: Double, midi: Int, amp: Double,
                                            pan: Double, attack: Double, decay: Double,
                                            wave: (Double) -> Double) {
        let total = l.count
        let f = freq(midi)
        let n = Int(length * sr)
        let s0 = Int(start * sr)
        let gl = Float(amp * (1 - pan)), gr = Float(amp * (1 + pan))
        for i in 0..<n {
            let t = Double(i) / sr
            let env = (t < attack ? t / attack : 1.0) * exp(-(max(t - attack, 0)) / decay)
            if env < 0.0005 && t > attack { break }
            let v = Float(env * wave(2 * .pi * f * t))
            let k = (s0 + i) % total
            l[k] += v * gl
            r[k] += v * gr
        }
    }

    nonisolated static func render(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let beat = 60.0 / 92.0                       // 92 BPM
        let totalBeats = 32                          // 8 bars of 4/4
        let frames = Int(Double(totalBeats) * beat * sr)
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)

        // C maj7 – A m7 – F maj7 – G6, two bars each
        let chords: [(bass: Int, tones: [Int])] = [
            (36, [60, 64, 67, 71]),
            (33, [57, 60, 64, 67]),
            (29, [53, 57, 60, 64]),
            (31, [55, 59, 62, 64]),
        ]
        // bell melody, one value per beat (0 = rest)
        let melody: [Int] = [
            76, 0, 74, 72,  74, 0, 67, 0,
            72, 0, 71, 69,  67, 0, 64, 0,
            69, 0, 72, 76,  74, 0, 72, 0,
            71, 0, 74, 72,  71, 0, 67, 0,
        ]

        let soft: (Double) -> Double = { sin($0) + 0.25 * sin(2 * $0) }
        let pluck: (Double) -> Double = { sin($0) + sin(3 * $0) / 9 + 0.2 * sin(2 * $0) }
        let bell: (Double) -> Double = { sin($0) + 0.35 * sin(2 * $0) + 0.12 * sin(3.01 * $0) }

        for (c, chord) in chords.enumerated() {
            let chordStart = Double(c * 8) * beat

            // pad: slow attack, long tail into the next chord, slight detune
            for tone in chord.tones {
                for detune in [-0.0015, 0.0015] {
                    let f = freq(tone) * (1 + detune)
                    let n = Int(9.5 * beat * sr)
                    let s0 = Int(chordStart * sr)
                    for i in 0..<n {
                        let t = Double(i) / sr
                        let held = 8 * beat
                        var env = min(t / 0.8, 1.0)
                        if t > held { env *= exp(-(t - held) / 0.5) }
                        let v = Float(0.022 * env * sin(2 * .pi * f * t))
                        let k = (s0 + i) % frames
                        l[k] += v * (detune < 0 ? 1.2 : 0.8)
                        r[k] += v * (detune < 0 ? 0.8 : 1.2)
                    }
                }
            }

            // bass on beats 1 and 3
            for b in stride(from: 0, to: 8, by: 2) {
                addNote(&l, &r, sr: sr, start: chordStart + Double(b) * beat, length: 1.9 * beat,
                        midi: chord.bass + 12, amp: 0.16, pan: 0, attack: 0.01, decay: 0.55, wave: soft)
            }

            // plucked arpeggio in eighth notes
            let pattern = [0, 1, 2, 3, 2, 1, 3, 2]
            for e in 0..<16 {
                let tone = chord.tones[pattern[e % pattern.count]] + 12
                addNote(&l, &r, sr: sr, start: chordStart + Double(e) * beat / 2, length: 1.2,
                        midi: tone, amp: 0.055, pan: e % 2 == 0 ? -0.35 : 0.35,
                        attack: 0.004, decay: 0.22, wave: pluck)
            }
        }

        for (i, note) in melody.enumerated() where note != 0 {
            addNote(&l, &r, sr: sr, start: Double(i) * beat, length: 2.4,
                    midi: note, amp: 0.085, pan: 0.1, attack: 0.006, decay: 0.55, wave: bell)
        }

        // normalise to -2 dBFS
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(l[i]), abs(r[i])) }
        let gain: Float = peak > 0 ? 0.79 / peak : 1

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            channels[0][i] = l[i] * gain
            channels[1][i] = r[i] * gain
        }
        return buffer
    }
}
