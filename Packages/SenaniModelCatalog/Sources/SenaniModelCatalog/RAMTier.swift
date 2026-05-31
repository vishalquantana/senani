import Foundation

/// Host RAM tier used to recommend Gemma 4-bit variants (ARCHITECTURE "Local model strategy").
public enum RAMTier: String, Sendable, CaseIterable, Equatable {
    case gb8
    case gb16
    case gb32

    private static let giB: UInt64 = 1024 * 1024 * 1024

    /// Detect the tier from `ProcessInfo.processInfo.physicalMemory` (bytes).
    public static func detect(physicalMemory: UInt64) -> RAMTier {
        if physicalMemory < 12 * giB { return .gb8 }
        if physicalMemory < 24 * giB { return .gb16 }
        return .gb32
    }

    /// Convenience for the live host.
    public static func detectHost() -> RAMTier {
        detect(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// Largest on-disk model size (bytes) we recommend for this tier.
    public var maxModelBytes: Int64 {
        switch self {
        case .gb8: return 3_000_000_000
        case .gb16: return 7_000_000_000
        case .gb32: return 20_000_000_000
        }
    }

    /// The preferred default model id for this tier.
    public var defaultModelId: String {
        switch self {
        case .gb8: return "mlx-community/gemma-3-1b-it-4bit"
        case .gb16: return "mlx-community/gemma-3-4b-it-4bit"
        case .gb32: return "mlx-community/gemma-3-12b-it-4bit"
        }
    }

    public var displayName: String {
        switch self {
        case .gb8: return "8 GB"
        case .gb16: return "16 GB"
        case .gb32: return "32 GB+"
        }
    }
}
