//
//  ContentView.swift
//  IrisLivePrototype
//
//  Minimal harness: paste a key, press Start, talk, watch transcripts.
//  The key lives in memory only — it is never written to disk and never
//  printed to the console.
//

import SwiftUI
import AVKit

@MainActor
final class LiveSessionController: ObservableObject {

    enum Status: String {
        case idle = "Idle"
        case connecting = "Connecting…"
        case ready = "Live"
        case closed = "Closed"
    }

    struct TranscriptLine: Identifiable {
        let id = UUID()
        let speaker: String
        var text: String
    }

    @Published var status: Status = .idle
    @Published var lines: [TranscriptLine] = []
    @Published var errorText: String = ""
    @Published var audioChunksReceived: Int = 0
    @Published var audioBytesReceived: Int = 0
    @Published var isRunning = false
    /// Route + engine diagnostics, polled off the audio engine.
    @Published var audioStatus = AudioStatus()

    private var client: LiveClient?
    private var pump: Task<Void, Never>?
    private var statusPoll: Task<Void, Never>?
    private let audio = AudioEngine()

    func start(apiKey: String, voice: String) {
        guard !isRunning else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorText = "Paste an API key or ephemeral token first."
            return
        }

        errorText = ""
        lines = []
        audioChunksReceived = 0
        audioBytesReceived = 0
        audioStatus = AudioStatus()
        status = .connecting
        isRunning = true
        startStatusPolling()

        let client = LiveClient(config: .init(
            apiKey: key,
            voiceName: voice,
            systemInstruction: "You are a terse voice assistant. Answer in one or two short sentences unless asked for more."
        ))
        self.client = client

        pump = Task { [weak self] in
            guard let self else { return }
            let stream = await client.events()
            await client.connect()
            for await event in stream {
                await self.apply(event)
            }
            await MainActor.run { self.status = .closed }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        statusPoll?.cancel()
        statusPoll = nil
        audio.stop()
        audioStatus = audio.currentStatus()
        let client = self.client
        self.client = nil
        pump?.cancel()
        pump = nil
        Task { await client?.close() }
        status = .closed
    }

    private func apply(_ event: LiveEvent) async {
        switch event {
        case .opened:
            status = .connecting

        case .setupComplete:
            status = .ready
            await startMicrophone()

        case .audio(let pcm):
            audioChunksReceived += 1
            audioBytesReceived += pcm.count
            audio.enqueuePlayback(pcm)

        case .inputTranscript(let text):
            append(speaker: "You", text: text)

        case .outputTranscript(let text):
            append(speaker: "Iris", text: text)

        case .text(let text):
            append(speaker: "Iris", text: text)

        case .interrupted:
            audio.flushPlayback()
            lines.append(.init(speaker: "—", text: "[interrupted]"))

        case .generationComplete:
            break

        case .turnComplete:
            lines.append(.init(speaker: "—", text: "[turn complete]"))

        case .goAway(let timeLeft):
            errorText = "Server going away (\(timeLeft ?? "soon"))"

        case .sessionResumption:
            break

        case .error(let message):
            errorText = message

        case .closed(let code, let reason):
            status = .closed
            isRunning = false
            statusPoll?.cancel()
            statusPoll = nil
            audio.stop()
            errorText = "Closed (code \(code))" + (reason.map { ": \($0)" } ?? "")
        }
    }

    private func startMicrophone() async {
        let granted = await audio.requestMicrophonePermission()
        guard granted else {
            errorText = "Microphone permission denied."
            return
        }
        audio.onError = { [weak self] message in
            Task { @MainActor in self?.errorText = message }
        }
        audio.onCapturedChunk = { [weak self] chunk in
            Task { [weak self] in
                guard let client = await self?.currentClient else { return }
                await client.sendAudio(chunk)
            }
        }
        audio.start()
    }

    /// The audio engine owns its own serial queue, so the UI samples it
    /// rather than being pushed to from the audio thread.
    private func startStatusPolling() {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.audio.currentStatus()
                if snapshot != self.audioStatus { self.audioStatus = snapshot }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private var currentClient: LiveClient? { client }

    /// Appends to the trailing line when the same speaker keeps streaming —
    /// transcription arrives in small fragments.
    private func append(speaker: String, text: String) {
        if var last = lines.last, last.speaker == speaker {
            last.text += text
            lines[lines.count - 1] = last
        } else {
            lines.append(.init(speaker: speaker, text: text))
        }
    }
}

struct ContentView: View {
    @StateObject private var controller = LiveSessionController()
    @State private var apiKey: String = KeychainStore.loadKey() ?? ""
    @State private var keySaved: Bool = KeychainStore.loadKey() != nil
    @State private var voice: String = "Iapetus"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {

                SecureField("Gemini API key or ephemeral token", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isRunning)

                if keySaved {
                    HStack {
                        Text("Key saved in this iPhone's Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget key", role: .destructive) {
                            KeychainStore.deleteKey()
                            apiKey = ""
                            keySaved = false
                        }
                        .font(.caption)
                        .disabled(controller.isRunning)
                    }
                }

                HStack {
                    TextField("Voice", text: $voice)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(controller.isRunning)
                        .frame(maxWidth: 140)

                    Spacer()

                    // Apple's own output picker: lets the tester move audio to
                    // AirPods by hand, which tells us whether iOS permits the
                    // route at all when the app cannot force it.
                    RoutePicker()
                        .frame(width: 36, height: 36)

                    Button(controller.isRunning ? "Stop" : "Start") {
                        if controller.isRunning {
                            controller.stop()
                        } else {
                            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { keySaved = KeychainStore.saveKey(trimmed) }
                            controller.start(apiKey: apiKey, voice: voice)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRunning ? .red : .accentColor)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(controller.status.rawValue)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(controller.audioChunksReceived) chunks · \(controller.audioBytesReceived / 1024) KB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Route + engine diagnostics. This is what a tester reads back
                // when Bluetooth playback misbehaves.
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.audioStatus.routeLine)
                    Text(controller.audioStatus.engineLine)
                    Text("in \(controller.audioChunksReceived) chunks → scheduled \(controller.audioStatus.buffersScheduled) · dropped \(controller.audioStatus.buffersDropped) · last route event: \(controller.audioStatus.lastRouteChange) · last rebuild: \(controller.audioStatus.lastRebuildReason)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(controller.errorText.isEmpty ? " " : controller.errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(controller.lines) { line in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.speaker)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(line.text)
                                        .font(.body)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: controller.lines.count) {
                        if let last = controller.lines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Iris Live Probe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .idle: return .gray
        case .connecting: return .orange
        case .ready: return .green
        case .closed: return .gray
        }
    }
}

#Preview {
    ContentView()
}


/// System audio-route picker (the AirPlay/Bluetooth output chooser).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
