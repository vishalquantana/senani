import Testing
@testable import SenaniApp
import SenaniInference

@Test func testTargetLinksAppAndInference() {
    // Proves the SenaniAppTests target builds and links the SenaniApp module + SenaniInference.
    let err: InferenceError = .modelNotLoaded
    #expect(err == .modelNotLoaded)
}
