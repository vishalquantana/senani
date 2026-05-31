import SenaniEngine
import SenaniGmail

/// Bridges the frozen `GmailSync` to the engine's `GmailSyncing` seam without
/// editing SenaniGmail. The method signatures already match
/// (`fetchMessages(query:maxResults:)`), so this is a marker conformance.
extension GmailSync: @retroactive GmailSyncing {}
