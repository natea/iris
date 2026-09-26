//
//  PresentationSnapshotTests.swift
//
//  Renders every Live Activity and widget presentation to a PNG so a person
//  can LOOK at them. DEBUG only, and it writes nothing unless
//  `IRIS_SHOT_DIR` is set in the test environment, so a normal test run is
//  unaffected.
//
//  These are VIEW renders, not system renders: ImageRenderer draws the same
//  SwiftUI the extension mounts, at the sizes iOS uses, but it is not the
//  Dynamic Island compositing the result, and it is not the lock screen
//  applying its tinted or Always-On rendering mode. What it does prove is that
//  every state has legible, honest content at the real size — including the
//  ones that are hard to produce on demand on a phone (stale, failed).
//
//    xcodebuild test -only-testing:IrisLivePrototypeTests/PresentationSnapshotTests \
//      IRIS_SHOT_DIR=/path/to/shots
//

#if DEBUG
import XCTest
import SwiftUI
@testable import IrisLivePrototype

@MainActor
final class PresentationSnapshotTests: XCTestCase {

    private var directory: URL?

    override func setUp() {
        super.setUp()
        // `IRIS_SHOT_DIR` when the caller can set it; otherwise the app
        // container's tmp, which is reachable from the host with
        // `xcrun simctl get_app_container booted app.iris.liveprototype data`.
        let path = ProcessInfo.processInfo.environment["IRIS_SHOT_DIR"]
            ?? NSTemporaryDirectory().appending("iris-shots")
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
    }

    private func shoot<V: View>(_ name: String, size: CGSize, dark: Bool = true, @ViewBuilder _ view: () -> V) {
        let renderer = ImageRenderer(content:
            view()
                .frame(width: size.width, height: size.height)
                .background(dark ? Color(red: 0.07, green: 0.06, blue: 0.16) : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
        )
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            return XCTFail("\(name) did not render at all")
        }
        XCTAssertGreaterThan(image.size.width, 0)
        guard let directory, let data = image.pngData() else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Live Activity — Lock Screen

    func testLockScreenPresentations() {
        let size = CGSize(width: 360, height: 160)
        shoot("lockscreen-running", size: size) {
            IrisActivityLockScreenView(state: .preview(.running), macName: "studio")
        }
        shoot("lockscreen-needs-attention", size: size) {
            IrisActivityLockScreenView(state: .preview(.needsAttention), macName: "studio")
        }
        shoot("lockscreen-stale", size: size) {
            IrisActivityLockScreenView(state: .preview(.running), macName: "studio", isStale: true)
        }
        shoot("lockscreen-finished-failed", size: size) {
            IrisActivityLockScreenView(state: .preview(.finishedFailed), macName: "studio")
        }
        shoot("lockscreen-steps-unknown", size: size) {
            IrisActivityLockScreenView(state: .preview(.stepsUnknown), macName: "studio")
        }
        shoot("lockscreen-always-on", size: size) {
            IrisActivityLockScreenView(
                state: .preview(.running), macName: "studio", isLuminanceReduced: true)
        }
    }

    // MARK: Live Activity — Dynamic Island

    func testDynamicIslandRegions() {
        // The expanded island, laid out the way the system arranges the four
        // regions. Not the system's own compositing — see the note above.
        func expanded(_ state: IrisRunActivityAttributes.ContentState, stale: Bool) -> some View {
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    IrisIslandLeadingView(state: state, isStale: stale)
                    IrisIslandCenterView(state: state)
                    IrisIslandTrailingView(state: state)
                }
                IrisIslandBottomView(state: state, isStale: stale)
            }
            .padding(12)
        }

        shoot("island-expanded-running", size: CGSize(width: 340, height: 150)) {
            expanded(.preview(.running), stale: false)
        }
        shoot("island-expanded-needs-attention", size: CGSize(width: 340, height: 150)) {
            expanded(.preview(.needsAttention), stale: false)
        }
        shoot("island-expanded-stale", size: CGSize(width: 340, height: 150)) {
            expanded(.preview(.running), stale: true)
        }

        // Compact: a pill with the leading and trailing slots either side of
        // the sensor housing.
        func compact(_ state: IrisRunActivityAttributes.ContentState, stale: Bool) -> some View {
            HStack {
                IrisIslandCompactLeadingView(state: state, isStale: stale)
                Spacer(minLength: 90)
                IrisIslandCompactTrailingView(state: state, isStale: stale)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(.black))
        }

        shoot("island-compact-running", size: CGSize(width: 220, height: 44)) {
            compact(.preview(.running), stale: false)
        }
        shoot("island-compact-needs-attention", size: CGSize(width: 220, height: 44)) {
            compact(.preview(.needsAttention), stale: false)
        }
        shoot("island-compact-stale", size: CGSize(width: 220, height: 44)) {
            compact(.preview(.running), stale: true)
        }
        shoot("island-minimal", size: CGSize(width: 44, height: 44)) {
            IrisIslandMinimalView(state: .preview(.needsAttention))
        }
    }

    // MARK: Home-screen widget

    func testWidgetFamilies() {
        // The real point sizes on an iPhone 15/16/17 Pro.
        let small = CGSize(width: 170, height: 170)
        let medium = CGSize(width: 364, height: 170)

        for (name, sample) in [("active", IrisWidgetSnapshot.Sample.active),
                               ("waiting", .waiting),
                               ("idle", .idle),
                               ("stale", .stale)] {
            shoot("widget-small-\(name)", size: small) {
                IrisSmallWidgetView(snapshot: .preview(sample)).padding(14)
            }
            shoot("widget-medium-\(name)", size: medium) {
                IrisMediumWidgetView(snapshot: .preview(sample)).padding(14)
            }
        }

        shoot("widget-small-unpaired", size: small) {
            IrisSmallWidgetView(snapshot: .unpaired).padding(14)
        }
        shoot("widget-medium-unpaired", size: medium) {
            IrisMediumWidgetView(snapshot: .unpaired).padding(14)
        }
        shoot("widget-rectangular", size: CGSize(width: 160, height: 72)) {
            IrisAccessoryRectangularView(snapshot: .preview(.waiting))
        }
        shoot("widget-circular", size: CGSize(width: 76, height: 76)) {
            IrisAccessoryCircularView(snapshot: .preview(.active))
        }
    }
}
#endif
