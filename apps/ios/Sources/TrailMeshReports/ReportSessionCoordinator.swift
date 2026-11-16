import Foundation

/// Foreground product-session owner. SDK delegates call this synchronously on the
/// main actor: aggregate admission occurs before any asynchronous work is created.
@MainActor
public final class ReportSessionCoordinator: ReportSessionRadioDelegate {
    public static let maximumLinks = 4
    public static let maximumCandidates = 32
    public static let maximumQueuedCallbacks = 64
    public static let maximumQueuedBytes = 262144
    public static let terminalDrainMS: Int64 = 2000
    public private(set) var state: ReportSessionState = .stopped
    public private(set) var sessionID = ""
    public private(set) var radioEpoch: UInt64 = 0
    public private(set) var revision: UInt64 = 0
    public private(set) var events: [ReportSessionEvent] = []
    public var activeLinkCount: Int { links.count }
    public var waitingCandidateCount: Int { waiting.count }
    public var queuedCallbackCount: Int { reservations.count }
    public var queuedByteCount: Int { reservations.values.reduce(0) { $0 + $1.bytes } }
    // Internal deterministic scheduling seam; production leaves it nil.
    var beforeDispatchForTesting: (@MainActor (Data) async -> Void)?
    var readyActionBatchCount: Int { links.values.reduce(0) { $0 + $1.readyBatches.count } }
    public var onChange: (@MainActor () -> Void)?
    private let repository: ReportRepository
    private let radio: any ReportSessionRadio
    private let wallClock: @Sendable () -> Int64
    private let monotonic: @Sendable () -> Int64
    private let temporaryID: @Sendable () throws -> String
    private let jitter: @Sendable () -> Double
    private var context: RelevanceContext?
    private var intended = false, foreground = true
    private var generation: UInt64 = 0, ticket: UInt64 = 0, ingress: UInt64 = 0, batchSequence: UInt64 = 0
    private var observed: Int64 = 0
    private var waiting: [Candidate] = []
    private var links: [String: Link] = [:]
    private var tombstones: Set<String> = []
    private var rotationRequired = false
    private struct InputReservation {
        let bytes: Int
        var workFinished = false
        var outputFinished = false
    }
    private var reservations: [UInt64: InputReservation] = [:]
    private var cooldowns: [String: Cooldown] = [:]
    private var cooldownOrder: [String] = []
    private var ticker: Task<Void, Never>?
    private struct Candidate: Sendable { let endpoint: String; let peer: String }
    private struct Cooldown { let eligibleAt: Int64; let failures: Int }
    private final class Link {
        let candidate: Candidate
        let generation: UInt64
        let engine: ExchangeSession
        let began: Int64
        var connected = false, tickPending = false
        var drainAt: Int64?, succeeded = false, pauseAfterDrain = false
        var pending: Set<UInt64> = []
        var actionDrain = ReportActionDrain()
        var batchOrder: [UInt64] = []
        var readyBatches: [UInt64: [ExchangeAction]] = [:]
        var batchReservations: [UInt64: UInt64] = [:]
        var drainingBatches = false
        var peerClaimCount = 0
        init(candidate: Candidate, generation: UInt64, engine: ExchangeSession, began: Int64) {
            self.candidate = candidate; self.generation = generation; self.engine = engine; self.began = began
        }
    }
    public init(repository: ReportRepository, radio: any ReportSessionRadio,
                wallClock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                monotonic: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
                temporaryID: @escaping @Sendable () throws -> String = { try ReportAdvertisement.secureID() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.75...1.25) }) {
        self.repository = repository; self.radio = radio; self.wallClock = wallClock
        self.monotonic = monotonic; self.temporaryID = temporaryID; self.jitter = jitter
        if let id = try? temporaryID(), ReportAdvertisement.parse(Data("TMR1|\(id)".utf8)) != nil { sessionID = id }
        radio.delegate = self
    }
    public func start(context: RelevanceContext, publicSharingConsent: Bool) {
        stopTransport()
        self.context = context
        intended = publicSharingConsent
        guard publicSharingConsent else { state = .paused(.consentRequired); changed(); return }
        resume()
    }
    public func resume() {
        guard intended else { state = .paused(.consentRequired); changed(); return }
        guard foreground else { pause(.foregroundRequired); return }
        guard let context, configurationUsable(context) else { pause(.configurationRequired); return }
        stopTransport()
        do {
            sessionID = try temporaryID()
            guard let advertisement = ReportAdvertisement.parse(Data("TMR1|\(sessionID)".utf8)) else { throw ReportStoreError.clock }
            observed = monotonic()
            guard observed >= 0 else { throw ReportStoreError.clock }
            state = .running
            radio.start(advertisement: advertisement.encoded, epoch: radioEpoch)
            record("session_started")
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                    guard let self, self.state == .running else { break }
                    self.tick()
                }
            }
        } catch { pause(.storageFailure) }
        changed()
    }
    public func stop() {
        intended = false
        stopTransport(); state = .stopped; record("session_stopped"); changed()
    }
    public func setForeground(_ active: Bool) {
        foreground = active
        if !active, intended { pause(.foregroundRequired) }
        else if active, intended, state == .paused(.foregroundRequired) { resume() }
    }
    public func updateContext(_ context: RelevanceContext) { self.context = context; if intended { resume() } }
    private func configurationUsable(_ context: RelevanceContext) -> Bool {
        let probe = RelevanceReport(id: "local-configuration-check", observedAt: 0, expiresAt: Int64.max, latitude: 0, longitude: 0)
        let result = RelevancePolicy.evaluate(probe, context: context, now: wallClock())
        return result == .eligible || result == .notRelevant
    }
    private func pause(_ reason: ReportSessionPause) {
        stopTransport(); state = .paused(reason); record(reason == .radioUnavailable ? "radio_unavailable" : reason == .storageFailure ? "storage_failure" : "session_paused"); changed()
    }
    private func stopTransport() {
        radioEpoch &+= 1
        ticker?.cancel(); ticker = nil
        let old = Array(links.values)
        links.removeAll(); waiting.removeAll(); tombstones.removeAll(); rotationRequired = false
        radio.stop()
        for link in old {
            discardReadyBatches(link)
            Task { await link.engine.cancel() }
        }
    }
    public func noteAuthoredTestReport(_ evidence: SavedTestReportEvidence) { record("report_authored", bundleID: evidence.bundleID) }
    private func changed() { onChange?() }
    private func record(_ code: String, peer: String? = nil, bundleID: String? = nil) {
        revision &+= 1
        events.append(ReportSessionEvent(code: code, timestampMS: wallClock(), peerSessionID: peer, bundleID: bundleID))
        if events.count > 512 { events.removeFirst(events.count - 512) }
        changed()
    }
    private func current(_ link: Link) -> Bool { state == .running && links[link.candidate.endpoint] === link }
    private func eligible(_ peer: String) -> Bool {
        guard let value = cooldowns[peer] else { return true }
        return value.failures < 5 && monotonic() >= value.eligibleAt
    }
    private func remember(_ peer: String, success: Bool, progress: Bool = false) {
        let failures = progress || success ? 0 : min(5, (cooldowns[peer]?.failures ?? 0) + 1)
        let delay = progress ? Int64(0) : success ? 30000 : Int64(min(30000, max(1000, pow(2, Double(max(0, failures - 1))) * 1000 * jitter())))
        cooldowns[peer] = Cooldown(eligibleAt: monotonic() + delay, failures: failures)
        cooldownOrder.removeAll { $0 == peer }; cooldownOrder.append(peer)
        if cooldownOrder.count > 64 { cooldowns.removeValue(forKey: cooldownOrder.removeFirst()) }
    }
    private func fillSlots() {
        guard state == .running, !rotationRequired else { rotateIfIdle(); return }
        var index = 0
        while links.count < Self.maximumLinks && tombstones.count + links.count < 32 && index < waiting.count {
            let candidate = waiting[index]
            guard eligible(candidate.peer) else { index += 1; continue }
            waiting.remove(at: index)
            guard let link = reserve(candidate) else { continue }
            guard current(link) else { continue }
            radio.connect(endpoint: candidate.endpoint, advertisement: Data("TMR1|\(sessionID)".utf8), epoch: radioEpoch)
        }
        changed()
    }
    private func reserve(_ candidate: Candidate) -> Link? {
        guard let context, links.count < Self.maximumLinks, tombstones.count + links.count < 32, !rotationRequired, !tombstones.contains(candidate.endpoint),
              links[candidate.endpoint] == nil, !links.values.contains(where: { $0.candidate.peer == candidate.peer }), eligible(candidate.peer) else { return nil }
        do {
            generation &+= 1
            let token = generation
            let selected = SelectedReportExchangeStore(repository: repository, context: context, clock: wallClock)
            let store = SessionObservedStore(base: selected) { [weak self] outcome in
                await self?.committed(outcome, peer: candidate.peer, generation: token)
            }
            let engine = ExchangeSession(store: store, nonce: try ReportAdvertisement.secureNonce(), generation: token, wallClock: wallClock)
            let link = Link(candidate: candidate, generation: token, engine: engine, began: monotonic())
            links[candidate.endpoint] = link
            return link
        } catch { pause(.storageFailure); return nil }
    }
    private func committed(_ outcome: ReportStoreOutcome, peer: String, generation: UInt64) {
        guard links.values.contains(where: { $0.generation == generation }), state == .running else { return }
        switch outcome {
        case .stored: remember(peer, success: false, progress: true); record("report_stored", peer: peer)
        case .duplicate: record("report_duplicate", peer: peer)
        case .rejected: break
        }
    }
    private func rotateIfIdle() {
        guard state == .running, links.isEmpty, !tombstones.isEmpty else { return }
        // Old SDK endpoints have no meaning in a new epoch. Discovery will offer
        // fresh candidates; cooldowns survive and remain bounded independently.
        radioEpoch &+= 1; radio.stop(); waiting.removeAll(); tombstones.removeAll(); rotationRequired = false
        radio.start(advertisement: Data("TMR1|\(sessionID)".utf8), epoch: radioEpoch)
    }
    private func release(_ link: Link, succeeded: Bool) {
        guard current(link) else { return }
        links.removeValue(forKey: link.candidate.endpoint)
        discardReadyBatches(link)
        if tombstones.count < 32 { tombstones.insert(link.candidate.endpoint) }
        if tombstones.count == 32 { rotationRequired = true }
        remember(link.candidate.peer, success: succeeded)
        radio.disconnect(endpoint: link.candidate.endpoint)
        Task { await link.engine.disconnect() }
        record("link_closed", peer: link.candidate.peer)
        if link.pauseAfterDrain { pause(.storageFailure); return }
        fillSlots(); rotateIfIdle()
    }
    private func dispatch(_ actions: [ExchangeAction], link: Link) async {
        for action in actions {
            if let beforeDispatchForTesting { await beforeDispatchForTesting(action.bytes) }
            guard current(link), await link.engine.isLive(action), current(link) else { continue }
            guard link.pending.count < 64 else { record("queue_overflow", peer: link.candidate.peer); release(link, succeeded: false); return }
            ticket &+= 1
            let id = ticket
            link.pending.insert(id)
            do { try radio.send(action.bytes, endpoint: link.candidate.endpoint, ticket: id) }
            catch { link.pending.remove(id); record("send_failed", peer: link.candidate.peer); release(link, succeeded: false); return }
        }
        await observeCompletion(link)
    }
    private func observeCompletion(_ link: Link) async {
        guard current(link) else { return }
        let claims = (await link.engine.peerOutcomes).count
        guard current(link) else { return }
        if claims > link.peerClaimCount { link.peerClaimCount = claims; record("peer_received_claim", peer: link.candidate.peer) }
        let completionState = await link.engine.completion
        if let completion = completionState {
            guard current(link) else { return }
            if completion.localRepositoryFailure { link.pauseAfterDrain = true }
            link.succeeded = completion.succeeded
            if link.drainAt == nil { link.drainAt = monotonic() }
            releaseIfDrained(link)
        }
    }
    private func reserveBatch(_ link: Link) -> UInt64 {
        batchSequence &+= 1
        link.batchOrder.append(batchSequence)
        link.actionDrain.begin()
        return batchSequence
    }
    private func batchReady(_ actions: [ExchangeAction], id: UInt64, link: Link) async {
        guard current(link) else { finishBatch(id, link: link); return }
        if actions.isEmpty {
            // An empty tick never waits behind a suspended repository operation.
            // This keeps tick generation bounded and deadlines independent.
            finishBatch(id, link: link)
        } else { link.readyBatches[id] = actions }
        await observeCompletion(link)
        guard current(link), !link.drainingBatches else { return }
        link.drainingBatches = true
        Task { [weak self] in
            guard let self else { return }
            while self.current(link), let next = link.batchOrder.first, let batch = link.readyBatches.removeValue(forKey: next) {
                await self.dispatch(batch, link: link)
                self.finishBatch(next, link: link)
            }
            link.drainingBatches = false
        }
    }
    private func finishBatch(_ id: UInt64, link: Link) {
        link.batchOrder.removeAll { $0 == id }
        link.readyBatches.removeValue(forKey: id)
        if let reservation = link.batchReservations.removeValue(forKey: id) { finishReservation(reservation, work: false) }
        finishOperation(link)
    }
    private func discardReadyBatches(_ link: Link) {
        // Ready output can be discarded now, but its ingress reservation stays
        // charged until the task that retained the original bytes has returned.
        for id in Array(link.readyBatches.keys) { finishBatch(id, link: link) }
    }
    private func finishReservation(_ id: UInt64, work: Bool) {
        guard var reservation = reservations[id] else { return }
        if work { reservation.workFinished = true } else { reservation.outputFinished = true }
        if reservation.workFinished && reservation.outputFinished { reservations.removeValue(forKey: id) }
        else { reservations[id] = reservation }
    }
    private func finishOperation(_ link: Link) {
        link.actionDrain.finish()
        releaseIfDrained(link)
    }
    private func releaseIfDrained(_ link: Link) {
        guard current(link), link.actionDrain.mayRelease(completed: link.drainAt != nil, pendingPayloads: link.pending.count) else { return }
        release(link, succeeded: link.succeeded)
    }
    public func tick() {
        guard state == .running else { return }
        let now = monotonic()
        guard now >= observed else { pause(.storageFailure); return }
        observed = now
        for link in Array(links.values) {
            if let drain = link.drainAt {
                if now - drain >= Self.terminalDrainMS { release(link, succeeded: false) }
            } else if !link.connected {
                if now - link.began >= 15000 { release(link, succeeded: false) }
            } else if !link.tickPending {
                link.tickPending = true
                let batchID = reserveBatch(link)
                Task { [weak self] in
                    let actions = await link.engine.tick(elapsed: now)
                    guard let self else { return }
                    link.tickPending = false
                    await self.batchReady(actions, id: batchID, link: link)
                }
            }
        }
        fillSlots(); rotateIfIdle()
    }
    public func radioFound(endpoint: String, advertisement: Data, epoch: UInt64) {
        guard epoch == radioEpoch, state == .running, let peer = ReportAdvertisement.parse(advertisement)?.sessionID,
              sessionID < peer, !rotationRequired, !tombstones.contains(endpoint), links[endpoint] == nil,
              !waiting.contains(where: { $0.endpoint == endpoint || $0.peer == peer }), waiting.count < Self.maximumCandidates else { return }
        waiting.append(Candidate(endpoint: endpoint, peer: peer)); fillSlots()
    }
    public func radioLost(endpoint: String, epoch: UInt64) {
        guard epoch == radioEpoch else { return }; waiting.removeAll { $0.endpoint == endpoint }; changed()
    }
    public func radioRequested(endpoint: String, advertisement: Data, epoch: UInt64) -> Bool {
        guard epoch == radioEpoch, state == .running, let peer = ReportAdvertisement.parse(advertisement)?.sessionID, peer < sessionID else { return false }
        return reserve(Candidate(endpoint: endpoint, peer: peer)) != nil
    }
    public func radioMayVerify(endpoint: String, epoch: UInt64) -> Bool { epoch == radioEpoch && state == .running && links[endpoint] != nil }
    public func radioConnected(endpoint: String, epoch: UInt64) {
        guard epoch == radioEpoch, let link = links[endpoint], current(link), !link.connected else { return }
        link.connected = true; record("link_connected", peer: link.candidate.peer)
        let batchID = reserveBatch(link)
        Task { [weak self] in
            let actions = await link.engine.start(elapsed: self?.monotonic() ?? 0)
            guard let self else { return }
            await self.batchReady(actions, id: batchID, link: link)
        }
    }
    public func radioDisconnected(endpoint: String, epoch: UInt64) {
        guard epoch == radioEpoch, let link = links[endpoint] else { return }; release(link, succeeded: false)
    }
    public func radioReceived(_ bytes: Data, endpoint: String, epoch: UInt64) {
        guard epoch == radioEpoch, let link = links[endpoint], current(link), link.connected, link.drainAt == nil else { return }
        guard reservations.count < Self.maximumQueuedCallbacks, bytes.count <= Self.maximumQueuedBytes - queuedByteCount else {
            record("queue_overflow", peer: link.candidate.peer); release(link, succeeded: false); return
        }
        ingress &+= 1
        let reservation = ingress, elapsed = monotonic()
        reservations[reservation] = InputReservation(bytes: bytes.count)
        let batchID = reserveBatch(link)
        link.batchReservations[batchID] = reservation
        Task { [weak self] in
            let actions = await link.engine.receive(bytes, generation: link.generation, elapsed: elapsed)
            guard let self else { return }
            await self.batchReady(actions, id: batchID, link: link)
            self.finishReservation(reservation, work: true)
        }
    }
    public func radioSent(ticket: UInt64, succeeded: Bool, endpoint: String, epoch: UInt64) {
        guard epoch == radioEpoch, let link = links[endpoint], link.pending.remove(ticket) != nil else { return }
        guard succeeded else { record("send_failed", peer: link.candidate.peer); release(link, succeeded: false); return }
        releaseIfDrained(link)
    }
    public func radioUnavailable(epoch: UInt64) { guard epoch == radioEpoch else { return }; pause(.radioUnavailable) }
}

private struct SessionObservedStore: ReportExchangeStore {
    let base: SelectedReportExchangeStore
    let committed: @Sendable (ReportStoreOutcome) async -> Void
    func inventoryPage(after: String?, limit: Int, now: Int64) async throws -> ExchangeInventoryPage { try await base.inventoryPage(after: after, limit: limit, now: now) }
    func currentIDs(_ ids: [String], now: Int64) async throws -> Set<String> { try await base.currentIDs(ids, now: now) }
    func loadOutgoing(_ id: String, clock: @Sendable () -> Int64) async throws -> ExchangeOutgoing? { try await base.loadOutgoing(id, clock: clock) }
    func ingestTransferred(_ wire: Data, offeredHops: Int, clock: @Sendable () -> Int64) async throws -> ReportStoreOutcome {
        let outcome = try await base.ingestTransferred(wire, offeredHops: offeredHops, clock: clock)
        await committed(outcome)
        return outcome
    }
}

/// Tracks ownership of engine results across actor suspension. An empty result
/// cannot release a completed link while another task still owns a terminal batch.
/// Tick deadlines and explicit cancellation remain independent of this gate.
struct ReportActionDrain {
    private(set) var operations = 0
    mutating func begin() { operations += 1 }
    mutating func finish() { precondition(operations > 0); operations -= 1 }
    func mayRelease(completed: Bool, pendingPayloads: Int) -> Bool {
        completed && operations == 0 && pendingPayloads == 0
    }
}
