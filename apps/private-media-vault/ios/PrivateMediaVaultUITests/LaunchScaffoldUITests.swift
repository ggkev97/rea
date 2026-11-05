import XCTest

/// UI scaffold. It is not in the default scheme's test action, so a normal
/// Run does not execute it. Do not record a UI pass from this file alone.
final class LaunchScaffoldUITests: XCTestCase {
    func testLaunchCoverIsNotAutomatedHere() throws {
        throw XCTSkip("Launch and lock-screen UI coverage needs a booted iOS Simulator or an iPhone. This file only reserves that test.")
    }
}
