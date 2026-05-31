import Foundation

public enum CatalogError: Error, Sendable, Equatable {
    case network(String)
    case badStatus(Int)
    case malformedResponse
}

/// Minimal seam over an HTTP GET so the catalog is testable without the network.
public protocol CatalogHTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

/// Live client over URLSession.
public struct URLSessionCatalogClient: CatalogHTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CatalogError.badStatus(http.statusCode)
            }
            return data
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.network(error.localizedDescription)
        }
    }
}
