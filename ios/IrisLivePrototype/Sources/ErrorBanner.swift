//
//  ErrorBanner.swift
//  IrisLivePrototype
//
//  `LinkError` already speaks plain language. What does not is the socket:
//  `LiveClient` emits things like "Socket receive ended: Socket is not
//  connected" and "Closed (code 1006)". Those are the right strings to keep —
//  they are what a tester reads back — but they are the wrong strings to put
//  on a hero screen.
//
//  So this is a *presentation* mapping only: a known raw string becomes a
//  sentence, and the raw text is still shown verbatim in Settings → Debug.
//  Nothing unknown is swallowed: an unrecognised message is shown as-is rather
//  than replaced with a guess.
//

import SwiftUI

enum ErrorPresentation {

    /// Plain language for a raw controller error, or the raw string when we do
    /// not recognise it. Never invents a cause.
    static func humanize(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if text.hasPrefix("Socket receive ended") || text.hasPrefix("Send failed") {
            return "The connection to Gemini dropped. Tap the orb to start again."
        }
        if text.hasPrefix("Closed (code 1000") {
            return "The session ended."
        }
        if text.hasPrefix("Closed (code") {
            return "The session closed unexpectedly. Tap the orb to start again."
        }
        if text.hasPrefix("Gemini refused this session's token") {
            return "Your Mac's session token was refused. Tap the orb to ask for a fresh one."
        }
        // "Server going away" no longer reaches the banner at all: a `goAway`
        // is the server rotating the connection on its fixed lifetime, and
        // the app now reconnects into the same conversation instead of
        // telling the user their session is over. The mapping stays only for
        // a session with no reconnect behind it (the unpaired developer
        // fallback), and no longer claims the conversation is finished.
        if text.hasPrefix("Server going away") {
            return "Gemini is rotating this connection. Tap the orb to start again."
        }
        if text.hasPrefix("Unparsable frame") || text.hasPrefix("Failed to encode") {
            return "Iris and Gemini disagreed about a message. The details are in Settings → Debug."
        }
        if text.hasPrefix("Bad endpoint URL") || text.hasPrefix("Could not build endpoint URL") {
            return "Iris could not build a valid connection address. The details are in Settings → Debug."
        }
        if text == "Microphone permission denied." {
            return "Iris cannot hear you: microphone access is off for this app in iOS Settings."
        }
        // Everything else — including every `LinkError.message`, which is
        // already written for a person — passes through untouched.
        //
        // That is deliberate for LINK_API.md §15: a classified failure's
        // message IS the desktop's own sentence ("That chat is open in Hermes
        // Desktop…"), and rewriting it here would put the phone and the Mac
        // back to disagreeing about what happened. Nothing below §15's codes
        // is mapped, so the banner can never substitute the old generic
        // "Hermes is not reachable" line for a Hermes that was running.
        return text
    }
}

/// A dismissible banner that floats above the content, in glass because it is
/// part of the control layer rather than the transcript.
struct ErrorBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .padding(.trailing, 2)
        .irisGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problem")
        .accessibilityValue(text)
    }
}
