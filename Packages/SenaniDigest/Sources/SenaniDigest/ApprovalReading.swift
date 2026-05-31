import Foundation
import SenaniStore

/// The minimal read seam the DigestBuilder needs from the approval queue:
/// a point-in-time count of proposals awaiting the user. Defined as a protocol
/// so the builder stays testable and never couples to ApprovalStore's full API.
public protocol ApprovalReading: Sendable {
    func pendingCount() throws -> Int
}

/// The frozen ApprovalStore conforms via its existing `pending()` reader.
extension ApprovalStore: ApprovalReading {
    public func pendingCount() throws -> Int {
        try pending().count
    }
}
