import Foundation

/// Resolves on-disk locations for the live app graph. Kept tiny and injectable
/// so AppEnvironment.live() can place the database under the user's Application
/// Support directory while tests redirect to a temp directory.
public enum AppSupport {
    public static let folderName = "Senani"
    public static let databaseFileName = "senani.sqlite"

    /// Returns `<base>/Senani/senani.sqlite`, creating `<base>/Senani` if needed.
    /// In production `base` is the user's Application Support directory.
    public static func databaseURL(base: URL, fileManager: FileManager) throws -> URL {
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// The user's Application Support directory (the default `base` for live()).
    public static func applicationSupportBase(fileManager: FileManager) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
    }
}
