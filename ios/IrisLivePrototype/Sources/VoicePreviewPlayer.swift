//
//  VoicePreviewPlayer.swift
//  IrisLivePrototype
//
//  Playback-only audio for a voice preview (LINK_API.md §13.5). A few seconds
//  of 24 kHz mono PCM16 from a preview token, and nothing else.
//
//  Why this is NOT AudioEngine
//  ---------------------------
//  AudioEngine is a full-duplex `.playAndRecord` / `.voiceChat` graph with
//  voice processing, a microphone tap, route observers and a rebuild path,
//  every part of which was tuned on a real device. It has no playback-only
//  mode: `start()` builds the capture tap and the player together, so using it
//  for a preview would mean opening the microphone to play a sample — and
//  giving it one would mean editing routing logic that is deliberately frozen.
//
//  So a preview gets its own small engine, and touches the shared
//  `AVAudioSession` as lightly as anything can:
//
//    · it only ever runs when NO live session is running (§13.5 forbids the
//      overlap, and `VoicePreviewController` enforces it), so it can never
//      pull the category out from under a conversation;
//    · it sets `.playback`, which follows whatever output the system is
//      already using — AirPods included — and adds no input route of its own;
//    · when it stops it deactivates and puts the category, mode and options
//      back exactly as it found them, so the next real session starts from the
//      state AudioEngine expects. (AudioEngine re-applies its own category on
//      every build anyway; this just means it never has to.)
//
//  It never calls into AudioEngine and AudioEngine never calls into it.
//

#if os(iOS)

import AVFoundation
import Foundation

final class VoicePreviewPlayer: @unchecked Sendable {

    /// Called on a private queue when playback could not be set up. The
    /// message is for a person, not a log.
    var onError: (@Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    /// Gemini downlink is 24 kHz mono; the mixer resamples to the hardware rate.
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private let queue = DispatchQueue(label: "app.iris.liveprototype.voicepreview")

    private var isRunning = false
    private var attached = false
    /// What the session looked like before the preview touched it.
    private var restore: (category: AVAudioSession.Category,
                          mode: AVAudioSession.Mode,
                          options: AVAudioSession.CategoryOptions)?

    // MARK: Lifecycle

    /// Prepares the session and the graph. Safe to call twice.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                self.restore = (session.category, session.mode, session.categoryOptions)
                // `.playback` and nothing more: no input, no override, no
                // preferred port. Whatever the phone is playing through now is
                // what the sample comes out of.
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true, options: [])

                if !self.attached {
                    self.engine.attach(self.player)
                    self.attached = true
                }
                self.engine.connect(self.player, to: self.engine.mainMixerNode, format: self.playbackFormat)
                self.engine.prepare()
                try self.engine.start()
                self.player.play()
                self.isRunning = true
            } catch {
                self.isRunning = false
                self.restoreSession()
                self.onError?("This phone could not open its speaker for the preview.")
            }
        }
    }

    /// Schedules a chunk of little-endian PCM16 mono 24 kHz audio.
    func enqueue(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let frameCount = pcm16.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let destination = channel[0]
            for index in 0..<frameCount {
                destination[index] = Float(Int16(littleEndian: samples[index])) / 32768.0
            }
        }
        queue.async { [weak self] in
            guard let self, self.isRunning, self.engine.isRunning else { return }
            if !self.player.isPlaying { self.player.play() }
            self.player.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    /// Stops immediately, dropping anything still queued, and hands the
    /// session back the way it was found.
    func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            player.stop()
            if engine.isRunning { engine.stop() }
            restoreSession()
        }
    }

    private func restoreSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        if let restore {
            // Put it back rather than leave `.playback` behind: the next real
            // session's own configuration then finds exactly what it expects.
            try? session.setCategory(restore.category, mode: restore.mode, options: restore.options)
        }
        restore = nil
    }
}

#endif
