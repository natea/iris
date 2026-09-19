//
//  AuroraBackground.swift
//  IrisLivePrototype
//
//  The depth glass needs to refract. Deliberately cheap: four blurred radial
//  blobs whose offsets are animated by Core Animation with a single very slow
//  `repeatForever`, so there is no per-frame SwiftUI work and nothing is
//  re-laid-out. No TimelineView, no Canvas, no shader.
//
//  Reduce Motion stops the drift. Reduce Transparency flattens it to a plain
//  background so text contrast is never at the mercy of a gradient.
//

import SwiftUI

struct AuroraBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var drift = false

    var body: some View {
        ZStack {
            base.ignoresSafeArea()

            if !reduceTransparency {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    ZStack {
                        blob(palette.0, size: w * 1.15)
                            .offset(x: -w * 0.30, y: drift ? -h * 0.34 : -h * 0.22)
                        blob(palette.1, size: w * 1.05)
                            .offset(x: w * 0.34, y: drift ? -h * 0.06 : -h * 0.18)
                        blob(palette.2, size: w * 0.95)
                            .offset(x: drift ? -w * 0.24 : -w * 0.10, y: h * 0.26)
                        blob(palette.3, size: w * 1.20)
                            .offset(x: w * 0.20, y: drift ? h * 0.40 : h * 0.30)
                    }
                    .frame(width: w, height: h)
                    .blur(radius: 70)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) {
                        drift = true
                    }
                }
            }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(colorScheme == .dark ? 0.85 : 0.75), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }

    private var base: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.03, green: 0.03, blue: 0.08), Color(red: 0.05, green: 0.04, blue: 0.13)]
                : [Color(red: 0.93, green: 0.93, blue: 0.98), Color(red: 0.86, green: 0.88, blue: 0.97)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Iris's deep-space identity in the dark, a soft wash of the same hues in
    /// the light — so light mode is quieter rather than broken.
    private var palette: (Color, Color, Color, Color) {
        if colorScheme == .dark {
            return (
                Color(red: 0.29, green: 0.18, blue: 0.72),
                Color(red: 0.10, green: 0.31, blue: 0.68),
                Color(red: 0.13, green: 0.48, blue: 0.61),
                Color(red: 0.42, green: 0.15, blue: 0.55)
            )
        }
        return (
            Color(red: 0.66, green: 0.62, blue: 0.95),
            Color(red: 0.58, green: 0.74, blue: 0.96),
            Color(red: 0.60, green: 0.86, blue: 0.92),
            Color(red: 0.82, green: 0.68, blue: 0.94)
        )
    }
}

#Preview {
    AuroraBackground()
}
