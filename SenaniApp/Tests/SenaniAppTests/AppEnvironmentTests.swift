import Testing
import Foundation
@testable import SenaniApp
import SenaniInference

@Test func appSupportResolvesUnderBaseDirectoryAndCreatesIt() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("senani-test-\(UUID().uuidString)", isDirectory: true)
    let dbURL = try AppSupport.databaseURL(base: tmp, fileManager: .default)
    #expect(dbURL.lastPathComponent == "senani.sqlite")
    #expect(dbURL.deletingLastPathComponent().lastPathComponent == "Senani")
    // The Senani directory must have been created.
    var isDir: ObjCBool = false
    let dir = dbURL.deletingLastPathComponent().path
    #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
    #expect(isDir.boolValue == true)
    try? FileManager.default.removeItem(at: tmp)
}

@MainActor
@Test func previewBuildsACompleteGraph() async {
    let env = AppEnvironment.preview()
    // Every pinned member is constructed (the graph is complete).
    _ = env.messages
    _ = env.rules
    _ = env.approvals
    // preview generator is the FakeTextGenerator: it never throws.
    let out = try? await env.generator.generate(prompt: "hi", maxTokens: 4)
    #expect(out != nil)
    // preview embedder returns a vector.
    let vec = try? await env.embedder.embed("hi")
    #expect(vec?.isEmpty == false)
}

@MainActor
@Test func liveBuildsAFileBackedGraphInATempDirectory() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("senani-live-\(UUID().uuidString)", isDirectory: true)
    let env = try AppEnvironment.live(base: tmp)
    // The live generator is NotReady until a model is picked: it throws.
    _ = env.gmail
    // The DB file was created on disk.
    let dbPath = try AppSupport.databaseURL(base: tmp, fileManager: .default).path
    #expect(FileManager.default.fileExists(atPath: dbPath))
    try? FileManager.default.removeItem(at: tmp)
}

@MainActor
@Test func liveGeneratorIsNotReadyUntilModelPicked() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("senani-live-\(UUID().uuidString)", isDirectory: true)
    let env = try AppEnvironment.live(base: tmp)
    await #expect(throws: InferenceError.modelNotLoaded) {
        _ = try await env.generator.generate(prompt: "hi", maxTokens: 4)
    }
    try? FileManager.default.removeItem(at: tmp)
}
