//
//  PairingSheet.swift
//  IrisLivePrototype
//
//  The confirmation an `iris-link://pair` scan raises. Moved out of
//  ContentView unchanged: the user compares this number with the one on the
//  Mac before anything is sent, and the secret itself is never shown.
//
//  It is presented from the app's root, so it appears over whatever screen is
//  open when the QR is scanned.
//

import SwiftUI

struct PairingSheet: View {
    let offer: PairingOffer
    @ObservedObject var pairing: PairingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair with this Mac?")
                    .font(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 4) {
                    Text(offer.desktopName)
                        .font(.headline)
                    Text(offer.address)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirmation code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(offer.code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .kerning(4)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("Check that these six digits match the code Iris is showing on the Mac. If they do not match, do not pair.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if pairing.messageIsError && !pairing.message.isEmpty {
                    Text(pairing.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    Task {
                        await pairing.confirmPair()
                        if pairing.paired != nil { dismiss() }
                    }
                } label: {
                    if pairing.isPairing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pairing.isPairing)

                Button("Not now", role: .cancel) {
                    pairing.cancelPending()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(pairing.isPairing)
    }
}

extension PairingOffer: Identifiable {
    /// Identifies the sheet without exposing the secret.
    public var id: String { "\(address)#\(code)" }
}
