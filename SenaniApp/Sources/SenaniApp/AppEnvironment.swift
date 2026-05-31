import Foundation
import SenaniStore
import SenaniInference
import SenaniGmail
import SenaniRules
import SenaniEngine
import SenaniVoice

/// Records applied actions so preview-graph UI tests can assert execution
/// happened without a real Gmail backend. Used only by AppEnvironment.preview().
public final class SpyMailBackend: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [(Action, Message)] = []
    public init() {}
    public func apply(_ action: Action, to message: Message) async throws {
        _record(action, message)
    }
    private func _record(_ action: Action, _ message: Message) {
        lock.lock(); _applied.append((action, message)); lock.unlock()
    }
    public var applied: [(action: Action, message: Message)] {
        lock.lock(); defer { lock.unlock() }
        return _applied.map { (action: $0.0, message: $0.1) }
    }
}

/// The composition root (reconciliation §3 / §4.1). The ONLY place stores and
/// backends are constructed. Screens receive these via @EnvironmentObject and
/// never build a store, backend, Keychain, or network client themselves.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let database: SenaniDatabase
    public let messages: MessageStore
    public let rules: RuleStore
    public let approvals: ApprovalStore
    public let audit: PersistentAuditLog
    public let index: any VectorIndex
    public let generator: any TextGenerator
    public let embedder: any Embedder
    public let gmail: GmailAuth
    public let orchestrator: Orchestrator
    public let scheduler: Scheduler
    
    // Additive properties for Phase-1/2/3 features
    public let pipeline: any PipelineStore
    public let mailBackend: any MailBackend
    public let autonomySettings: AutonomySettingsStore
    public let autonomyForAgent: @Sendable (String) -> Autonomy
    public let spyBackend: SpyMailBackend

    @Published public var selectedItem: NavigationItem = .inbox
    @Published public var selectedMessageID: Message.ID?

    private init(database: SenaniDatabase, messages: MessageStore, rules: RuleStore,
                 approvals: ApprovalStore, audit: PersistentAuditLog, index: any VectorIndex,
                 generator: any TextGenerator, embedder: any Embedder, gmail: GmailAuth,
                 orchestrator: Orchestrator, scheduler: Scheduler,
                 pipeline: any PipelineStore,
                 mailBackend: any MailBackend, autonomySettings: AutonomySettingsStore,
                 autonomyForAgent: @escaping @Sendable (String) -> Autonomy,
                 spyBackend: SpyMailBackend) {
        self.database = database
        self.messages = messages
        self.rules = rules
        self.approvals = approvals
        self.audit = audit
        self.index = index
        self.generator = generator
        self.embedder = embedder
        self.gmail = gmail
        self.orchestrator = orchestrator
        self.scheduler = scheduler
        self.pipeline = pipeline
        self.mailBackend = mailBackend
        self.autonomySettings = autonomySettings
        self.autonomyForAgent = autonomyForAgent
        self.spyBackend = spyBackend
    }

    public static func live(
        base: URL? = nil,
        clientID: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> AppEnvironment {
        let fm = FileManager.default
        let resolvedBase = try base ?? AppSupport.applicationSupportBase(fileManager: fm)
        let dbURL = try AppSupport.databaseURL(base: resolvedBase, fileManager: fm)

        let database = try SenaniDatabase.file(at: dbURL.path)
        let nowSeconds: @Sendable () -> Double = { now().timeIntervalSince1970 }

        let messages = MessageStore(database: database)
        let rules = RuleStore(database: database)
        let approvals = ApprovalStore(database: database, now: nowSeconds)
        let audit = PersistentAuditLog(database: database, now: nowSeconds)
        let index = SqliteVecIndex(database: database)
        let generator: any TextGenerator = NotReadyTextGenerator()
        let embedder: any Embedder = FakeEmbedder()

        let http = URLSessionHTTPClient()
        let tokenStore: any TokenStore = KeychainTokenStore()
        let gmail = GmailAuth(clientID: clientID ?? liveClientID(), http: http, store: tokenStore, now: now)
        let accountEmail = ""
        let mailBackend = GmailMailBackend(http: http, tokenProvider: gmail, accountEmail: accountEmail)
        let sync = GmailSync(http: http, tokenProvider: gmail, accountEmail: accountEmail)

        let pipeline = try SqlitePipelineStore(database: database)
        let (orchestrator, scheduler) = Self.makeEngine(
            mailBackend: mailBackend, approvals: approvals, audit: audit, messages: messages,
            index: index, embedder: embedder, generator: generator, pipeline: pipeline,
            rules: rules, sync: sync, now: now)

        let settings = AutonomySettingsStore.live()
        let autonomyForAgent: @Sendable (String) -> Autonomy = { settings.autonomy(forAgent: $0) }
        let spy = SpyMailBackend()

        return AppEnvironment(database: database, messages: messages, rules: rules,
                              approvals: approvals, audit: audit, index: index,
                              generator: generator, embedder: embedder, gmail: gmail,
                              orchestrator: orchestrator, scheduler: scheduler,
                              pipeline: pipeline,
                              mailBackend: mailBackend, autonomySettings: settings,
                              autonomyForAgent: autonomyForAgent, spyBackend: spy)
    }

    public static func preview(now: @escaping @Sendable () -> Date = Date.init) -> AppEnvironment {
        let database = (try? SenaniDatabase.inMemory()) ?? { fatalError("in-memory DB must build") }()
        let nowSeconds: @Sendable () -> Double = { now().timeIntervalSince1970 }

        let messages = MessageStore(database: database)
        let rules = RuleStore(database: database)
        let approvals = ApprovalStore(database: database, now: nowSeconds)
        let audit = PersistentAuditLog(database: database, now: nowSeconds)
        let index: any VectorIndex = InMemoryVectorIndex()
        let generator: any TextGenerator = FakeTextGenerator()
        let embedder: any Embedder = FakeEmbedder()

        let http = URLSessionHTTPClient()
        let tokenStore: any TokenStore = InMemoryTokenStore()
        let gmail = GmailAuth(clientID: "preview-client-id", http: http, store: tokenStore, now: now)
        
        let spy = SpyMailBackend()
        let mailBackend: any MailBackend = spy
        let sync = GmailSync(http: http, tokenProvider: gmail, accountEmail: "preview@local")

        let pipeline = InMemoryPipelineStore(seededDeals)
        let (orchestrator, scheduler) = Self.makeEngine(
            mailBackend: mailBackend, approvals: approvals, audit: audit, messages: messages,
            index: index, embedder: embedder, generator: generator, pipeline: pipeline,
            rules: rules, sync: sync, now: now)

        let settings = AutonomySettingsStore.inMemory()
        let autonomyForAgent: @Sendable (String) -> Autonomy = { settings.autonomy(forAgent: $0) }

        return AppEnvironment(database: database, messages: messages, rules: rules,
                              approvals: approvals, audit: audit, index: index,
                              generator: generator, embedder: embedder, gmail: gmail,
                              orchestrator: orchestrator, scheduler: scheduler,
                              pipeline: pipeline,
                              mailBackend: mailBackend, autonomySettings: settings,
                              autonomyForAgent: autonomyForAgent, spyBackend: spy)
    }

    private static func makeEngine(
        mailBackend: any MailBackend, approvals: ApprovalStore, audit: PersistentAuditLog,
        messages: MessageStore, index: any VectorIndex, embedder: any Embedder,
        generator: any TextGenerator, pipeline: any PipelineStore, rules: RuleStore,
        sync: GmailSync, now: @escaping @Sendable () -> Date
    ) -> (Orchestrator, Scheduler) {
        let triage = TriageAgent()
        let replyDrafter = ReplyDrafterAgent(
            generator: generator,
            voice: VoiceConditionerPrefixProvider(
                conditioner: VoiceConditioner(embedder: embedder, index: index),
                profile: VoiceProfile(
                    scope: "global",
                    averageSentenceWords: 15.0,
                    greeting: "Hi",
                    signoff: "Best,",
                    commonPhrases: [],
                    emojiRate: 0.0
                )
            )
        )
        
        let registry = AgentRegistry(agents: [replyDrafter])
        let orchestrator = Orchestrator(
            registry: registry, triage: triage, mailBackend: mailBackend,
            approvals: approvals, audit: audit, messages: messages, index: index,
            embedder: embedder, generator: generator, pipeline: pipeline, rules: rules, now: now)
        let scheduler = Scheduler(
            sync: sync, store: messages, orchestrator: orchestrator,
            interval: 300, now: now)
        return (orchestrator, scheduler)
    }

    private static func liveClientID() -> String {
        ProcessInfo.processInfo.environment["SENANI_GOOGLE_CLIENT_ID"]
            ?? "REPLACE_WITH_GOOGLE_OAUTH_DESKTOP_CLIENT_ID"
    }

    /// Deterministic seed covering several stages for previews/tests.
    public static let seededDeals: [Deal] = [
        Deal(id: "sarah@acme.com", contactEmail: "sarah@acme.com", company: "Acme Corp",
             stage: .qualified, score: 82, value: nil,
             lastTouch: Date(timeIntervalSince1970: 1_700_000_000), sourceMessageId: "m-1"),
        Deal(id: "vp@globex.com", contactEmail: "vp@globex.com", company: "Globex",
             stage: .proposal, score: 64, value: 24_000,
             lastTouch: Date(timeIntervalSince1970: 1_700_100_000), sourceMessageId: "m-2"),
        Deal(id: "ops@initech.com", contactEmail: "ops@initech.com", company: "Initech",
             stage: .negotiation, score: 71, value: 9_500,
             lastTouch: Date(timeIntervalSince1970: 1_700_200_000), sourceMessageId: "m-3"),
        Deal(id: "ceo@hooli.com", contactEmail: "ceo@hooli.com", company: "Hooli",
             stage: .won, score: 90, value: 50_000,
             lastTouch: Date(timeIntervalSince1970: 1_700_300_000), sourceMessageId: "m-4"),
    ]
}
