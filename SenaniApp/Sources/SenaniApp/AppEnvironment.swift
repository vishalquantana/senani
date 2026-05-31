import Foundation
import Observation
import SenaniStore
import SenaniInference
import SenaniGmail
import SenaniDocs
import SenaniRules
import SenaniEngine
import SenaniVoice
import SenaniModelCatalog
import SenaniCalendar
import SenaniLicensing
import SenaniReplyZero

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
    public let embedder: any Embedder
    public let gmail: GmailAuth
    public let orchestrator: Orchestrator
    public let scheduler: Scheduler
    
    // License State slice
    public let licenseState: LicenseState

    // Model Management slice
    public private(set) var generator: any TextGenerator
    public private(set) var hasModel: Bool = false
    public let catalog: ModelCatalog
    public let downloader: ModelDownloading
    public let choices: ModelChoiceStore
    public let tier: RAMTier
    
    public private(set) lazy var modelManager: ModelManager = ModelManager(
        downloader: downloader,
        installer: MLXGeneratorInstaller(setGenerator: { [weak self] gen in
            Task { @MainActor in self?.applyGenerator(gen) }
        }),
        choices: choices
    )

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
                 licenseState: LicenseState,
                 catalog: ModelCatalog, downloader: ModelDownloading, 
                 choices: ModelChoiceStore, tier: RAMTier,
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
        self.licenseState = licenseState
        self.catalog = catalog
        self.downloader = downloader
        self.choices = choices
        self.tier = tier
        self.pipeline = pipeline
        self.mailBackend = mailBackend
        self.autonomySettings = autonomySettings
        self.autonomyForAgent = autonomyForAgent
        self.spyBackend = spyBackend
    }

    private func applyGenerator(_ gen: any TextGenerator) {
        self.generator = gen
        self.hasModel = true
    }

    public static func live(
        base: URL? = nil,
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
        let embedder: any Embedder = MLXEmbedder(modelPath: Config.embeddingGemmaModelPath)

        let http = URLSessionHTTPClient()
        let tokenStore: any TokenStore = KeychainTokenStore()
        // Resolve the OAuth client id from env → Info.plist → app-support file
        // (GmailOAuthConfig), never from the gitignored Config struct. The
        // shipped binary therefore embeds no client id or secret; a desktop
        // PKCE flow needs no secret. If unconfigured we boot with an empty id —
        // the data store still opens; the Gmail flow surfaces its own error
        // until a client id is provided.
        let clientID = (try? GmailOAuthConfig.clientID()) ?? ""
        let gmail = GmailAuth(clientID: clientID, http: http, store: tokenStore, now: now)
        // The connected account's address is discovered at runtime (via the
        // OAuth flow / GmailAccountInfo); it is not baked into the shipped
        // binary. Default to empty until an account is connected.
        let accountEmail = ""
        let mailBackend = GmailMailBackend(http: http, tokenProvider: gmail, accountEmail: accountEmail)
        let sync = GmailSync(http: http, tokenProvider: gmail, accountEmail: accountEmail)

        // Document-fields pipeline: mirror sync/mailBackend's http + Gmail token
        // provider. Gmail's API uses "me" for the authenticated user when no
        // address is known yet, so an empty accountEmail still yields a valid path.
        let attachmentFetcher = GmailAttachmentFetcher(
            http: http, tokenProvider: gmail,
            accountEmail: accountEmail.isEmpty ? "me" : accountEmail)
        // LiteParseDocumentParser only succeeds when the native parse libs are
        // configured (SENANI_LITEPARSE_ENABLED); otherwise it throws and the
        // provider degrades to [:]. See HANDOFF.
        let documentFieldsProvider = GmailDocumentFieldsProvider(
            fetcher: attachmentFetcher,
            parser: LiteParseDocumentParser(),
            extractor: DocumentExtractor(generator: generator))
        let documentFields: @Sendable (Message) async -> [String: String] = {
            await documentFieldsProvider.fields(for: $0)
        }

        // License State wiring
        let licenseState = LicenseState()

        // Model Catalog wiring
        let modelsDir = resolvedBase.appendingPathComponent("Senani", isDirectory: true)
                                   .appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let catalog = ModelCatalog(http: URLSessionCatalogClient())
        let downloader = FileModelDownloader(baseDirectory: modelsDir)
        let choices = UserDefaultsModelChoiceStore()
        let tier = RAMTier.detectHost()

        let pipeline = try SqlitePipelineStore(database: database)
        let invoices = try SqliteInvoiceStore(database: database)
        let settings = AutonomySettingsStore.live()
        let autonomyForAgent: @Sendable (String) -> Autonomy = { settings.autonomy(forAgent: $0) }
        let explicitAutonomy: @Sendable (String) -> Autonomy? = { settings.explicitAutonomy(forAgent: $0) }
        let (orchestrator, scheduler) = Self.makeEngine(
            mailBackend: mailBackend, approvals: approvals, audit: audit, messages: messages,
            index: index, embedder: embedder, generator: generator, pipeline: pipeline,
            rules: rules, sync: sync, gmailAuth: gmail, licenseState: licenseState,
            invoices: invoices, accountEmail: accountEmail, explicitAutonomy: explicitAutonomy,
            documentFields: documentFields, now: now)

        let spy = SpyMailBackend()

        return AppEnvironment(database: database, messages: messages, rules: rules,
                              approvals: approvals, audit: audit, index: index,
                              generator: generator, embedder: embedder, gmail: gmail,
                              orchestrator: orchestrator, scheduler: scheduler,
                              licenseState: licenseState,
                              catalog: catalog, downloader: downloader,
                              choices: choices, tier: tier,
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
        
        // Preview License state
        let licenseState = LicenseState(status: .valid(.pro))

        // Preview Catalog stubs
        let catalog = ModelCatalog(http: URLSessionCatalogClient())
        let downloader = FileModelDownloader(baseDirectory: URL(fileURLWithPath: "/tmp/preview/models"))
        let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "preview")!)
        let tier = RAMTier.gb16

        let invoices = InMemoryInvoiceStore()
        let settings = AutonomySettingsStore.inMemory()
        let autonomyForAgent: @Sendable (String) -> Autonomy = { settings.autonomy(forAgent: $0) }
        let explicitAutonomy: @Sendable (String) -> Autonomy? = { settings.explicitAutonomy(forAgent: $0) }
        let (orchestrator, scheduler) = Self.makeEngine(
            mailBackend: mailBackend, approvals: approvals, audit: audit, messages: messages,
            index: index, embedder: embedder, generator: generator, pipeline: pipeline,
            rules: rules, sync: sync, gmailAuth: gmail, licenseState: licenseState,
            invoices: invoices, accountEmail: "preview@local", explicitAutonomy: explicitAutonomy,
            documentFields: { await FakeDocumentFieldsProvider().fields(for: $0) }, now: now)

        return AppEnvironment(database: database, messages: messages, rules: rules,
                              approvals: approvals, audit: audit, index: index,
                              generator: generator, embedder: embedder, gmail: gmail,
                              orchestrator: orchestrator, scheduler: scheduler,
                              licenseState: licenseState,
                              catalog: catalog, downloader: downloader,
                              choices: choices, tier: tier,
                              pipeline: pipeline,
                              mailBackend: mailBackend, autonomySettings: settings,
                              autonomyForAgent: autonomyForAgent, spyBackend: spy)
    }

    private static func makeEngine(
        mailBackend: any MailBackend, approvals: ApprovalStore, audit: PersistentAuditLog,
        messages: MessageStore, index: any VectorIndex, embedder: any Embedder,
        generator: any TextGenerator, pipeline: any PipelineStore, rules: RuleStore,
        sync: GmailSync, gmailAuth: GmailAuth, licenseState: LicenseState,
        invoices: any InvoiceStore, accountEmail: String,
        explicitAutonomy: @escaping @Sendable (String) -> Autonomy?,
        documentFields: @escaping @Sendable (Message) async -> [String: String] = { _ in [:] },
        now: @escaping @Sendable () -> Date
    ) -> (Orchestrator, Scheduler) {
        let triage = TriageAgent()
        
        let voiceProvider: @Sendable () -> any VoicePrefixProviding = {
            VoiceConditionerPrefixProvider(
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
        }

        // Phase 1 agents
        let replyDrafter = ReplyDrafterAgent(
            generator: generator,
            voice: voiceProvider()
        )
        
        // Phase 2 agents
        let booking = BookingAgent(
            availability: CalendarAvailabilityProvider(client: CalendarClient(http: URLSessionHTTPClient(), tokenProvider: gmailAuth))
        )
        let hygiene = InboxHygieneAgent()
        
        // Phase 3 agents
        let leadQualifier = LeadQualifierAgent()
        let followUp = FollowUpAgent(
            generator: generator,
            voice: voiceProvider(),
            pipelineRead: pipeline,
            pipelineTouch: pipeline,
            policy: FollowUpPolicy()
        )
        let proposalTracker = ProposalTrackerAgent(
            classifier: ReplyIntentClassifier(generator: generator)
        )
        let outreach = OutreachAgent(
            generator: generator,
            voice: voiceProvider()
        )
        let finance = InvoiceFinanceAgent()
        
        let allAgents: [any Agent] = [
            replyDrafter, booking, hygiene, leadQualifier, 
            followUp, proposalTracker, outreach, finance
        ]
        
        // Filter agents by license tier
        let enabledAgents = allAgents.filter { licenseState.enablesAgent(id: $0.id) }
        
        let registry = AgentRegistry(agents: enabledAgents)

        // Finding 1: needs-reply signal — pure NeedsReplyClassifier over the message's thread
        // (no LLM, no store population needed) so ReplyDrafter/FollowUp actually wake.
        let needsReplyClassifier = NeedsReplyClassifier()
        let needsReply: @Sendable (Message) -> Bool = { message in
            let thread = (try? messages.thread(id: message.threadId)) ?? [message]
            return needsReplyClassifier.classify(thread: thread, accountEmail: accountEmail)
        }

        let orchestrator = Orchestrator(
            registry: registry, triage: triage, mailBackend: mailBackend,
            approvals: approvals, audit: audit, messages: messages, index: index,
            embedder: embedder, generator: generator, pipeline: pipeline, rules: rules,
            // Finding 1: populate the read-only context seams. documentFields is now wired to the
            // attachment fetch+parse+extract pipeline (best-effort; agents degrade to subject/body
            // heuristics whenever it yields [:]).
            needsReply: needsReply,
            documentFields: documentFields,
            invoices: invoices,
            // Finding 4: user-set autonomy dials override routing; unset agents keep their static dial.
            autonomy: explicitAutonomy,
            now: now)
        let scheduler = Scheduler(
            sync: sync, store: messages, orchestrator: orchestrator,
            interval: 300, now: now)
        return (orchestrator, scheduler)
    }

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

    public func bootstrapPersistedModel() {
        do { _ = try modelManager.loadPersistedOnLaunch() }
        catch { /* leave NotReady */ }
    }
}
