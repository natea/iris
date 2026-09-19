//
//  GlassSupport.swift
//  IrisLivePrototype
//
//  One place where Liquid Glass is gated, so no other view has to carry an
//  `if #available` or an accessibility check.
//
//  The deployment target stays at iOS 18 (see README) because this app already
//  runs on a real phone and raising the floor to 26 would be a regression for
//  anything not yet updated. The cost of keeping it is exactly this file: every
//  other view calls `.irisGlass(…)` / `GlassContainer` and reads as if glass
//  were always available.
//
//  SDK-verified against iPhoneSimulator27.0.sdk:
//    SwiftUICore.View.glassEffect(_ glass: Glass = .regular, in shape: some Shape)  iOS 26.0
//    SwiftUICore.Glass  — .regular, .clear, .identity, .tint(_:), .interactive(_:)  iOS 26.0
//    SwiftUICore.GlassEffectContainer(spacing:content:)                             iOS 26.0
//    SwiftUI.GlassButtonStyle / GlassProminentButtonStyle (.glass/.glassProminent)  iOS 26.0
//  Note: this SDK has no `glassEffect(_:in:isEnabled:)` overload, only `(_:in:)`.
//

import SwiftUI
import AVKit

// MARK: - Style

/// A glass recipe expressed without naming `Glass`, so it can appear in
/// signatures that are not gated to iOS 26.
enum IrisGlassStyle: Equatable {
    case regular
    case clear
    case tinted(Color)
    /// Tinted and reacting to touch — for controls, never for content.
    case interactive(Color?)

    /// What stands in for glass when Reduce Transparency is on, or before 26.
    var fallbackFill: Color {
        switch self {
        case .regular, .clear: return Color.primary.opacity(0.08)
        case .tinted(let color): return color.opacity(0.22)
        case .interactive(let color): return (color ?? .primary).opacity(0.22)
        }
    }
}

@available(iOS 26.0, *)
extension IrisGlassStyle {
    var glass: Glass {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        case .tinted(let color): return .regular.tint(color)
        case .interactive(let color): return .regular.tint(color).interactive()
        }
    }
}

// MARK: - Modifier

private struct IrisGlassModifier<S: Shape>: ViewModifier {
    let style: IrisGlassStyle
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Apple's guidance for Reduce Transparency is an opaque surface,
            // not a thinner blur.
            content
                .background(style.fallbackFill, in: shape)
                .background(Color(uiColor: .systemBackground).opacity(0.92), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.18), lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(style.glass, in: shape)
        } else {
            content
                .background(style.fallbackFill, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26, `.ultraThinMaterial` before it, an opaque
    /// surface when Reduce Transparency is on.
    func irisGlass<S: Shape>(_ style: IrisGlassStyle = .regular, in shape: S) -> some View {
        modifier(IrisGlassModifier(style: style, shape: shape))
    }

    func irisGlass(_ style: IrisGlassStyle = .regular) -> some View {
        modifier(IrisGlassModifier(style: style, shape: Capsule()))
    }

    @ViewBuilder
    func irisGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

// MARK: - Container

/// Groups sibling glass shapes so they refract as one piece of material and
/// blend when they move together. A no-op before iOS 26.
struct GlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Route picker

/// System audio-route picker (the AirPlay/Bluetooth output chooser). This is
/// how the user moves Iris to AirPods, so it stays one tap from the orb.
struct RoutePicker: UIViewRepresentable {
    var tint: Color = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.activeTintColor = UIColor(Color.accentColor)
        view.tintColor = UIColor(tint)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tint)
    }
}
