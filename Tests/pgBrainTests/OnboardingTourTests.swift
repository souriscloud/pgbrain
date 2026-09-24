import SwiftUI
import XCTest
@testable import pgBrain

final class OnboardingTourTests: XCTestCase {
    private let window = CGSize(width: 1600, height: 1000)

    func testStepsAreNumberedInOrder() {
        XCTAssertEqual(OnboardingTour.steps.map(\.id), Array(OnboardingTour.steps.indices))
        XCTAssertNil(OnboardingTour.steps.first?.anchor, "the welcome step is a centred card")
    }

    func testCardIsCentredWithoutTarget() {
        let c = OnboardingLayout.cardCenter(for: nil, in: window)
        XCTAssertEqual(c, CGPoint(x: 800, y: 500))
    }

    func testCardSitsRightOfANarrowLeftTarget() {
        let sidebar = CGRect(x: 0, y: 40, width: 280, height: 900)
        let c = OnboardingLayout.cardCenter(for: sidebar, in: window)
        XCTAssertGreaterThan(c.x - OnboardingLayout.cardSize.width / 2, sidebar.maxX)
    }

    func testCardStaysInsideWindowForAHugeTarget() {
        let grid = CGRect(x: 280, y: 150, width: 1320, height: 800)
        let c = OnboardingLayout.cardCenter(for: grid, in: window)
        let half = OnboardingLayout.cardSize
        XCTAssertGreaterThanOrEqual(c.x - half.width / 2, 0)
        XCTAssertLessThanOrEqual(c.x + half.width / 2, window.width)
        XCTAssertGreaterThanOrEqual(c.y - half.height / 2, 0)
        XCTAssertLessThanOrEqual(c.y + half.height / 2, window.height)
    }

    /// A nested anchor (schema picker inside the sidebar, new-tab button
    /// inside the tab strip) must survive the outer one.
    @MainActor
    func testNestedAnchorsAreAllReported() {
        final class Box { var keys: Set<OnboardingAnchor> = [] }
        let box = Box()
        let view = VStack {
            Text("picker").onboardingAnchor(.schemaPicker)
            Text("tree")
        }
        .onboardingAnchor(.sidebar)
        .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
            let _ = { box.keys = Set(anchors.keys) }()
            Color.clear
        }
        let host = NSHostingView(rootView: view.frame(width: 200, height: 200))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(box.keys, [.sidebar, .schemaPicker])
    }
}
