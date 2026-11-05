import XCTest

/// Scaffold for checks that need Apple frameworks. This file is not part of the
/// Linux `swift test` target. A skip is not evidence that Keychain, Face ID,
/// Photos, or AVFoundation behaved correctly.
final class AppleOnlyScaffoldTests: XCTestCase {
    func testKeychainAndFaceIDAreNotExecutedByThisScaffold() throws {
        throw XCTSkip("Run a device or simulator pass before treating Keychain or Face ID as checked. This scaffold does not call them.")
    }

    func testPhotosCameraAndPlaybackAreNotExecutedByThisScaffold() throws {
        throw XCTSkip("Photos, camera, and AVFoundation playback need a simulator or iPhone. This scaffold does not launch them.")
    }
}
