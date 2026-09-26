//
//  AudioEngine.swift
//  IrisLivePrototype
//
//  Mic capture -> 16 kHz mono PCM16 chunks, and 24 kHz mono PCM16 playback
//  with a barge-in flush. Mirrors the behaviour of the Electron/web pipeline
//  in src/hooks/useAudioPipeline.ts.
//
//  Route resilience: the audio graph is rebuilt from scratch whenever the
//  hardware changes underneath us (Bluetooth headset connected/disconnected,
//  interruption, category change). AVAudioEngine stops itself when the IO
//  format changes — e.g. the speaker's 48 kHz becomes an HFP headset's
//  16 kHz — and it does not come back on its own.
//

#if os(iOS)

import AVFoundation
import Foundation

/// A snapshot of what the audio stack is doing right now. Pulled by the UI so
/// a human tester can read the route and the counters off the screen.
struct AudioStatus: Sendable, Equatable {
    var inputName: String = "—"
    var outputName: String = "—"
    var inputSampleRate: Double = 0
    var outputSampleRate: Double = 0
    var graphInputSampleRate: Double = 0
    var engineRunning: Bool = false
    var rebuildCount: Int = 0
    var buffersScheduled: Int = 0
    var buffersDropped: Int = 0
    var lastRouteChange: String = "—"
    var lastRebuildReason: String = "—"

    /// e.g. "In: AirPods Pro (HFP) 16000 Hz · Out: AirPods Pro 16000 Hz"
    var routeLine: String {
        let inHz = inputSampleRate > 0 ? "\(Int(inputSampleRate)) Hz" : "? Hz"
        let outHz = outputSampleRate > 0 ? "\(Int(outputSampleRate)) Hz" : "? Hz"
        return "In: \(inputName) \(inHz) · Out: \(outputName) \(outHz)"
    }

    /// e.g. "engine: running · graph in 16000 Hz · rebuilds 2"
    var engineLine: String {
        let graphHz = graphInputSampleRate > 0 ? "\(Int(graphInputSampleRate)) Hz" : "?"
        return "engine: \(engineRunning ? "running" : "stopped") · graph in \(graphHz) · rebuilds \(rebuildCount)"
    }
}

final class AudioEngine: @unchecked Sendable {

    /// Called on a private serial queue with ~40 ms of little-endian PCM16
    /// mono audio at 16 kHz.
    var onCapturedChunk: (@Sendable (Data) -> Void)?
    /// Called on a private serial queue for non-fatal audio errors.
    var onError: (@Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    /// 16 kHz mono Int16 interleaved — exactly what the Live API wants uplink.
    private let uplinkFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    /// Gemini downlink is 24 kHz mono. AVAudioPlayerNode wants float, so the
    /// player is connected at 24 kHz float32 and the mixer resamples to the
    /// hardware rate for us — including when the hardware drops to the 16 kHz
    /// of a Bluetooth HFP link.
    private let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: 24_000,
        channels: 1
    )!

    private var pendingUplink = Data()
    /// 640 frames @ 16 kHz = 40 ms = 1280 bytes.
    private let uplinkChunkBytes = 640 * 2

    /// Chunk assembly only. Never mutates the graph.
    private let queue = DispatchQueue(label: "app.iris.liveprototype.audio")
    /// The single serial context for *all* graph mutation: start, stop,
    /// rebuild, and every notification handler. Nothing else touches the
    /// engine, the player connections, or the tap.
    private let graphQueue = DispatchQueue(label: "app.iris.liveprototype.audio.graph")

    // Graph state — graphQueue only.
    private var isRunning = false
    private var tapInstalled = false
    private var playerAttached = false
    private var currentInputFormat: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []
    private var rebuildPending = false
    private var pendingReasons: [String] = []
    private var interrupted = false

    // Status — statusLock only.
    private let statusLock = NSLock()
    private var status = AudioStatus()

    // MARK: - Status

    /// Thread-safe snapshot for the UI.
    func currentStatus() -> AudioStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return status
    }

    private func mutateStatus(_ body: (inout AudioStatus) -> Void) {
        statusLock.lock()
        body(&status)
        statusLock.unlock()
    }

    // MARK: - Session

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat gives us the system AEC + noise suppression, which is what
        // keeps Gemini from hearing (and interrupting) its own voice.
        //
        // .allowBluetoothHFP stays on deliberately: this is a two-way voice
        // session and we need the headset's *microphone*. A2DP is an
        // output-only profile, so .allowBluetoothA2DP would give us a nicer
        // downlink and no uplink, and .voiceChat will not select it for a
        // .playAndRecord session anyway. The price of HFP is the narrowband
        // 8/16 kHz clock on both directions — which is exactly the IO format
        // change this class now rebuilds for.
        //
        // No .defaultToSpeaker: observed on device, it pins a .voiceChat session
        // to the loudspeaker even with AirPods connected and preferred, and
        // every re-application of the category snaps the route back. The
        // loudspeaker is chosen explicitly below instead, only when no headset
        // is present. Re-setting an unchanged category also fires a
        // categoryChange route event, so only set it when it actually differs.
        let wanted: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if session.category != .playAndRecord || session.mode != .voiceChat
            || session.categoryOptions != wanted {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: wanted)
        }
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])

        // HFP input and output are one port pair, so preferring the headset's
        // microphone moves both directions onto it.
        let headsetTypes: [AVAudioSession.Port] = [.bluetoothHFP, .headsetMic, .bluetoothLE, .usbAudio]
        let inputs = session.availableInputs ?? []
        let headset = inputs.first { headsetTypes.contains($0.portType) }
        print("[audio] available inputs: \(inputs.map { "\($0.portName) [\($0.portType.rawValue)]" })")
        if let headset {
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(headset)
            print("[audio] preferred input → \(headset.portName)")
        } else {
            if session.preferredInput != nil { try session.setPreferredInput(nil) }
            // Loudspeaker rather than the quiet earpiece when nothing is plugged in.
            try session.overrideOutputAudioPort(.speaker)
            print("[audio] no headset → loudspeaker override")
        }
        var route = session.currentRoute
        // iOS may decline the headset (observed: AirPods listed and preferred,
        // route stays on the phone). Never leave a hands-free session on the
        // quiet earpiece — fall back to the loudspeaker. A later route change to
        // the headset (e.g. chosen in the system route picker) clears this.
        if route.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try session.overrideOutputAudioPort(.speaker)
            route = session.currentRoute
            print("[audio] headset not adopted → loudspeaker fallback")
        }
        print("[audio] route now: in\(route.inputs.map { $0.portName }) out\(route.outputs.map { $0.portName })")
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts capture + playback. Errors are reported through `onError`
    /// rather than thrown: the build runs off the main thread because settling
    /// a freshly-switched route can take a few tens of milliseconds.
    func start() {
        graphQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.interrupted = false
            self.registerObservers()
            do {
                // The session must be configured and *active* before any node
                // format is read: an inactive session reports the default
                // 48 kHz route, not the headset that is really attached.
                try self.buildGraph(reason: "start")
            } catch {
                self.isRunning = false
                self.removeObservers()
                self.mutateStatus { $0.engineRunning = false }
                self.log("start failed: \(error.localizedDescription)")
                self.onError?("Audio engine failed: \(error.localizedDescription)")
            }
            self.refreshRouteStatus()
        }
    }

    func stop() {
        graphQueue.sync {
            guard isRunning else { return }
            isRunning = false
            interrupted = false
            removeObservers()
            teardownGraph(detachPlayer: true)
            currentInputFormat = nil
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        }
        queue.async { [weak self] in self?.pendingUplink.removeAll() }
        mutateStatus { $0.engineRunning = false }
    }

    // MARK: - Graph construction (graphQueue only)

    private func teardownGraph(detachPlayer: Bool) {
        dispatchPrecondition(condition: .onQueue(graphQueue))
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        if engine.isRunning { engine.stop() }
        if playerAttached {
            engine.disconnectNodeOutput(player)
            if detachPlayer {
                engine.detach(player)
                playerAttached = false
            }
        }
    }

    /// Stop, tear down, re-read the *current* hardware format, and build the
    /// whole graph again. Safe to run any number of times.
    private func buildGraph(reason: String) throws {
        dispatchPrecondition(condition: .onQueue(graphQueue))

        teardownGraph(detachPlayer: false)

        try configureSession()

        let input = engine.inputNode
        // Voice processing re-plumbs the IO unit, so enable it *before* the
        // format is read; with VP on, the input and output formats are coupled.
        if input.isVoiceProcessingEnabled == false {
            try? input.setVoiceProcessingEnabled(true)
        }

        let inputFormat = try resolveInputFormat(input)

        guard let converter = AVAudioConverter(from: inputFormat, to: uplinkFormat) else {
            throw NSError(
                domain: "AudioEngine", code: -2,
                userInfo: [NSLocalizedDescriptionKey:
                            "Cannot build 16 kHz converter from \(Int(inputFormat.sampleRate)) Hz"]
            )
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        // The converter is captured *by value* here, so this closure can never
        // see a half-replaced converter: a rebuild removes this tap first and
        // then installs a new closure holding the new converter.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCaptured(buffer, converter: converter)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        player.play()

        currentInputFormat = inputFormat
        let running = engine.isRunning
        mutateStatus {
            $0.engineRunning = running
            $0.graphInputSampleRate = inputFormat.sampleRate
            $0.lastRebuildReason = reason
        }
        log("graph built (\(reason)) input=\(Int(inputFormat.sampleRate)) Hz "
            + "ch=\(inputFormat.channelCount) running=\(running)")
    }

    /// During a route switch the input node transiently reports 0 Hz / 0
    /// channels. That is not a failure — wait it out instead of throwing the
    /// session away.
    private func resolveInputFormat(_ input: AVAudioInputNode) throws -> AVAudioFormat {
        for attempt in 0..<20 {
            let format = input.inputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 { return format }
            log("input format not ready (attempt \(attempt + 1)) — retrying")
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "AudioEngine", code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                        "Input node still has no usable format after 1 s (route settling?)"]
        )
    }

    // MARK: - Rebuild scheduling

    /// Coalesces a burst of notifications into one rebuild.
    private func scheduleRebuild(reason: String, delay: TimeInterval = 0.15) {
        graphQueue.async { [weak self] in
            guard let self, self.isRunning, !self.interrupted else { return }
            self.pendingReasons.append(reason)
            guard !self.rebuildPending else { return }
            self.rebuildPending = true
            self.graphQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.rebuildPending = false
                let reasons = self.pendingReasons.joined(separator: "+")
                self.pendingReasons.removeAll()
                guard self.isRunning, !self.interrupted else { return }
                do {
                    try self.buildGraph(reason: reasons)
                    self.mutateStatus { $0.rebuildCount += 1 }
                } catch {
                    self.mutateStatus { $0.engineRunning = false }
                    self.log("rebuild failed (\(reasons)): \(error.localizedDescription)")
                    self.onError?("Audio rebuild failed: \(error.localizedDescription)")
                }
                self.refreshRouteStatus()
            }
        }
    }

    // MARK: - Notifications

    private func registerObservers() {
        dispatchPrecondition(condition: .onQueue(graphQueue))
        let center = NotificationCenter.default

        // The engine stopped itself because the IO format changed underneath
        // it. This is the Bluetooth case: nothing else brings it back.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.log("AVAudioEngineConfigurationChange")
            self?.scheduleRebuild(reason: "configChange")
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.log("mediaServicesWereReset")
            self?.scheduleRebuild(reason: "mediaServicesReset", delay: 0.3)
        })
    }

    private func removeObservers() {
        dispatchPrecondition(condition: .onQueue(graphQueue))
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func handleRouteChange(_ note: Notification) {
        let session = AVAudioSession.sharedInstance()
        let rawReason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) ?? .unknown
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription

        let oldDescription = previous.map(Self.describe) ?? "—"
        let newDescription = Self.describe(session.currentRoute)
        let label = "\(Self.name(for: reason)): \(oldDescription) -> \(newDescription)"
        log("routeChange \(label)")
        mutateStatus { $0.lastRouteChange = Self.name(for: reason) }
        refreshRouteStatus()

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange,
             .override, .routeConfigurationChange:
            graphQueue.async { [weak self] in
                guard let self, self.isRunning, !self.interrupted else { return }
                let live = self.engine.inputNode.inputFormat(forBus: 0)
                let formatChanged = live.sampleRate > 0
                    && live.sampleRate != (self.currentInputFormat?.sampleRate ?? 0)
                if !self.engine.isRunning || formatChanged {
                    self.scheduleRebuild(reason: "route:\(Self.name(for: reason))")
                } else {
                    self.log("routeChange \(Self.name(for: reason)) — engine still running "
                             + "at \(Int(live.sampleRate)) Hz, no rebuild")
                }
            }
        default:
            break
        }
    }

    private func handleInterruption(_ note: Notification) {
        let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
        guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            log("interruption began")
            graphQueue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.interrupted = true
                self.teardownGraph(detachPlayer: false)
                self.mutateStatus { $0.engineRunning = false }
            }

        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            )
            log("interruption ended shouldResume=\(options.contains(.shouldResume))")
            guard options.contains(.shouldResume) else { return }
            graphQueue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.interrupted = false
                self.scheduleRebuild(reason: "interruptionEnded", delay: 0.2)
            }

        @unknown default:
            break
        }
    }

    // MARK: - Route description

    private func refreshRouteStatus() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let inputName = route.inputs.first?.portName ?? "none"
        let inputType = route.inputs.first.map { Self.shortType($0.portType) } ?? ""
        let outputName = route.outputs.first?.portName ?? "none"
        let sampleRate = session.sampleRate
        let inputRate = session.inputNumberOfChannels > 0 ? sampleRate : 0
        mutateStatus {
            $0.inputName = inputType.isEmpty ? inputName : "\(inputName) (\(inputType))"
            $0.outputName = outputName
            $0.inputSampleRate = inputRate
            $0.outputSampleRate = sampleRate
        }
    }

    private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let ins = route.inputs.map { "\($0.portName)/\(shortType($0.portType))" }
        let outs = route.outputs.map { "\($0.portName)/\(shortType($0.portType))" }
        return "in[\(ins.joined(separator: ","))] out[\(outs.joined(separator: ","))]"
    }

    private static func shortType(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .bluetoothHFP: return "HFP"
        case .bluetoothA2DP: return "A2DP"
        case .bluetoothLE: return "BLE"
        case .builtInMic: return "built-in mic"
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "earpiece"
        case .headsetMic: return "wired mic"
        case .headphones: return "wired"
        default: return type.rawValue
        }
    }

    private static func name(for reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigChange"
        @unknown default: return "unhandled"
        }
    }

    /// Diagnostics only. Never touches the API key — it does not live here.
    private func log(_ message: String) {
        print("[audio] \(message)")
    }

    // MARK: - Capture

    private func handleCaptured(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }

        let ratio = uplinkFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: uplinkFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            onError?("Audio conversion failed: \(conversionError.localizedDescription)")
            return
        }
        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData
        else { return }

        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        let chunk = Data(bytes: channel[0], count: byteCount)

        queue.async { [weak self] in
            guard let self else { return }
            self.pendingUplink.append(chunk)
            while self.pendingUplink.count >= self.uplinkChunkBytes {
                let slice = self.pendingUplink.prefix(self.uplinkChunkBytes)
                self.pendingUplink.removeFirst(self.uplinkChunkBytes)
                self.onCapturedChunk?(Data(slice))
            }
        }
    }

    // MARK: - Playback

    /// Schedules a chunk of little-endian PCM16 mono 24 kHz audio.
    func enqueuePlayback(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let frameCount = pcm16.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.floatChannelData
        else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let destination = channel[0]
            for index in 0..<frameCount {
                // Little-endian on every Apple platform we target.
                destination[index] = Float(Int16(littleEndian: samples[index])) / 32768.0
            }
        }

        // Scheduling happens on the graph queue so a buffer can never be handed
        // to a player that a rebuild is in the middle of disconnecting.
        graphQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning, self.playerAttached, self.engine.isRunning else {
                self.mutateStatus { $0.buffersDropped += 1 }
                return
            }
            if !self.player.isPlaying { self.player.play() }
            self.player.scheduleBuffer(buffer, completionHandler: nil)
            self.mutateStatus { $0.buffersScheduled += 1 }
        }
    }

    /// Barge-in: drop everything still queued so the model stops mid-sentence.
    func flushPlayback() {
        graphQueue.async { [weak self] in
            guard let self, self.isRunning, self.playerAttached else { return }
            self.player.stop()   // clears all scheduled buffers
            if self.engine.isRunning { self.player.play() }
        }
    }
}

#endif
