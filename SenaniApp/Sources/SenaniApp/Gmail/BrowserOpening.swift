import Foundation

public protocol BrowserOpening: Sendable {
    func open(_ url: URL)
}

#if canImport(AppKit)
import AppKit

public struct NSWorkspaceBrowserOpener: BrowserOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif
