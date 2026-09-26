//
//  ActivityRenderTests.swift
//
//  Renders every Live Activity and widget presentation to a PNG so a person
//  can look at it. A Live Activity cannot be screenshotted from a test bundle
//  — there is no API to start one headlessly — so this is the closest thing to
//  seeing the work: the same views, at the sizes iOS gives them.
//
//  It writes nothing unless `IRIS_SHOT_DIR` is set in the environment, so an
//  ordinary test run is unaffected. What it always does, set or not, is
//  exercise every view's body against every state, which is itself worth
//  having: a view that traps on an empty `runs` array fails here.
//

import XCTest
import SwiftUI
@testable import IrisLivePrototype

@MainActor
final class ActivityRenderTests: XCTestCase {

    private var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["IRIS_SHOT_DIR"], !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The dark chrome iOS draws a Live Activity into.
    private func render(
        _ name: String,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat = 22,
        background: Color = Color(red: 0.07, green: 0.06, blue: 0.16),
        @ViewBuilder content: () -> some View
    ) {
        let view = content()
            .frame(width: width, height: height, alignment: .topLeading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            return XCTFail("\(name) produced no image — a view body failed to render")
        }
        XCTAssertGreaterThan(image.size.width, 0, name)
        guard let directory, let data = image.pngData() else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private let now = Date(timeIntervalSince1970: 1_789_870_600)

    // MARK: Lock Screen

    func testLockScreenPresentations() {
        render("lock-running", width: 360, height: 118) {
            IrisActivityLockScreenView(
                state: .preview(.running, now: now), macName: "studio", now: now)
        }
        render("lock-needs-attention", width: 360, height: 140) {
            IrisActivityLockScreenView(
                state: .preview(.needsAttention, now: now), macName: "studio", now: now)
        }
        // The same running state, gone stale: dimmed, no spinner, and it says
        // when the Mac last reported instead of implying work continues.
        render("lock-stale", width: 360, height: 118) {
            IrisActivityLockScreenView(
                state: .preview(.running, now: now.addingTimeInterval(-260)),
                macName: "studio", isStale: true, now: now)
        }
        render("lock-finished-failed", width: 360, height: 96) {
            IrisActivityLockScreenView(
                state: .preview(.finishedFailed, now: now), macName: "studio", now: now)
        }
        // The case that must never read "0 steps".
        render("lock-steps-unknown", width: 360, height: 100) {
            IrisActivityLockScreenView(
                state: .preview(.stepsUnknown, now: now), macName: "studio", now: now)
        }
        // Always-On: dimmed screen, no animation.
        render("lock-always-on", width: 360, height: 118) {
            IrisActivityLockScreenView(
                state: .preview(.running, now: now), macName: "studio",
                isLuminanceReduced: true, now: now)
        }
    }

    // MARK: Dynamic Island

    /// The real Island is composed by the system; this lays the four regions
    /// out the way it does, at roughly the size it gives them, so the content
    /// can be judged.
    func testDynamicIslandExpanded() {
        for (name, state, stale) in [
            ("island-expanded-running", IrisRunActivityAttributes.ContentState.preview(.running, now: now), false),
            ("island-expanded-needs-attention", .preview(.needsAttention, now: now), false),
            ("island-expanded-stale", .preview(.running, now: now.addingTimeInterval(-260)), true),
        ] {
            render(name, width: 360, height: 150, cornerRadius: 44, background: .black) {
                VStack(spacing: 10) {
                    HStack(alignment: .top) {
                        IrisIslandLeadingView(state: state, isStale: stale)
                        Spacer()
                        IrisIslandTrailingView(state: state)
                    }
                    IrisIslandCenterView(state: state)
                    IrisIslandBottomView(state: state, isStale: stale, now: now)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
            }
        }
    }

    func testDynamicIslandCompactAndMinimal() {
        for (name, state, stale) in [
            ("island-compact-running", IrisRunActivityAttributes.ContentState.preview(.running, now: now), false),
            ("island-compact-needs-attention", .preview(.needsAttention, now: now), false),
            ("island-compact-stale", .preview(.running, now: now), true),
        ] {
            render(name, width: 190, height: 38, cornerRadius: 19, background: .black) {
                HStack {
                    IrisIslandCompactLeadingView(state: state, isStale: stale)
                    Spacer()
                    IrisIslandCompactTrailingView(state: state, isStale: stale)
                }
                .padding(.horizontal, 12)
                .foregroundStyle(.white)
            }
        }
        render("island-minimal", width: 38, height: 38, cornerRadius: 19, background: .black) {
            IrisIslandMinimalView(state: .preview(.needsAttention, now: now))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Home-screen widget

    func testWidgetFamilies() {
        let widgetBackground = LinearGradient(
            colors: [Color(red: 0.09, green: 0.08, blue: 0.19),
                     Color(red: 0.05, green: 0.06, blue: 0.13)],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        func widget(_ name: String, medium: Bool, snapshot: IrisWidgetSnapshot) {
            let size: CGFloat = medium ? 360 : 170
            let view = Group {
                if medium {
                    IrisMediumWidgetView(snapshot: snapshot, now: now)
                } else {
                    IrisSmallWidgetView(snapshot: snapshot, now: now)
                }
            }
            .padding(16)
            .frame(width: size, height: 170, alignment: .topLeading)
            .background(widgetBackground)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let image = renderer.uiImage else { return XCTFail(name) }
            guard let directory, let data = image.pngData() else { return }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }

        for (label, sample) in [("active", IrisWidgetSnapshot.Sample.active),
                                ("waiting", .waiting),
                                ("idle", .idle),
                                ("stale", .stale)] {
            widget("widget-small-\(label)", medium: false, snapshot: .preview(sample, now: now))
            widget("widget-medium-\(label)", medium: true, snapshot: .preview(sample, now: now))
        }
        widget("widget-small-unpaired", medium: false, snapshot: .unpaired)
        widget("widget-medium-unpaired", medium: true, snapshot: .unpaired)
    }

    func testAccessoryFamilies() {
        render("accessory-rectangular", width: 160, height: 72, cornerRadius: 12, background: .black) {
            IrisAccessoryRectangularView(snapshot: .preview(.waiting, now: now), now: now)
                .padding(8)
                .foregroundStyle(.white)
        }
        render("accessory-circular", width: 76, height: 76, cornerRadius: 38, background: .black) {
            IrisAccessoryCircularView(snapshot: .preview(.active, now: now), now: now)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white)
        }
    }
}
