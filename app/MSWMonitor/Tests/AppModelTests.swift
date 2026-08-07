import XCTest
@testable import MSWMonitor

@MainActor
final class AppModelTests: XCTestCase {
    func testInitialWorkspacesAreFixedAndStopped() {
        let model = AppModel()

        XCTAssertEqual(model.workspaces.map(\.id), [.dev, .playgrounds, .personal])
        XCTAssertEqual(model.workspaces.map(\.state), [.stopped, .stopped, .stopped])
        XCTAssertEqual(model.observationCount, 0)
        XCTAssertEqual(model.observationText, "Not yet refreshed")
    }

    func testRefreshAdvancesVisibleObservationCounter() {
        let model = AppModel()

        model.refresh()
        XCTAssertEqual(model.observationCount, 1)
        XCTAssertEqual(model.observationText, "Observation #1")

        model.refresh()
        XCTAssertEqual(model.observationText, "Observation #2")
    }
}
