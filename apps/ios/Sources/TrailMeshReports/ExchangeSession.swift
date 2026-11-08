import Foundation

/// A transport must check isLive immediately before dispatching each tagged action.
public struct ExchangeAction: Sendable {
    public let generation: UInt64
    public let bytes: Data
}
public actor ExchangeSession {
    private let store: any ReportExchangeStore
    private let nonce: Data
    private let generation: UInt64
    private let wallClock: @Sendable () -> Int64
    private struct QueuedInput { let bytes: Data; let elapsed: Int64; let continuation: CheckedContinuation<[ExchangeAction], Never> }
    private var pending: [QueuedInput] = []
    private var queuedBytes = 0
    private var invalidated = false
    private var active = true, started = false, working = false
    private var peer: Data?
    private var decoder = ExchangeStreamDecoder()
    private var maxFrame = 16_384, maxChunk = 1024, traffic = 0
    private var began: Int64 = 0, last: Int64 = 0, observed: Int64 = 0
    private var localPage = 0, remotePage = 0, offered = 0, remoteTransfers = 0
    private var cursor: String?, lastRemoteID: String?
    private var advertised: [ExchangeDescriptor]? = nil
    private var remoteMore = true
    private var moreLocal = false, localDone = false, remoteDone = false
    private var outbound: [ExchangeDescriptor] = [], requested: [ExchangeDescriptor] = []
    private var awaiting: (Int, ExchangeDescriptor)?
    private var incoming: Incoming?
    private var completed: [Int: (ExchangeDescriptor, Int, Data)] = [:]
    private var acknowledged: [Int: (String, Int)] = [:]
    public private(set) var peerOutcomes: [Int] = []
    public private(set) var failureReason: Int?
    // Counts only queued callbacks, excluding the operation currently awaiting storage.
    var queuedInputCount: Int { pending.count }
    private struct Incoming { let transfer: Int; let descriptor: ExchangeDescriptor; var bytes: Data; var received: [Bool]; var count = 0 }

    public init(store: any ReportExchangeStore, nonce: Data, generation: UInt64, wallClock: @escaping @Sendable () -> Int64) { self.store = store; self.nonce = nonce; self.generation = generation; self.wallClock = wallClock }
    public func isLive(_ action: ExchangeAction) -> Bool { action.generation == generation && !invalidated }
    private func discardPending() { let callbacks = pending; pending.removeAll(); queuedBytes = 0; for callback in callbacks { callback.continuation.resume(returning: []) } }
    public func cancel() { invalidated = true; active = false; incoming = nil; decoder = ExchangeStreamDecoder(); discardPending() }
    public func disconnect() { cancel() }
    private func emit(_ body: ExchangeBody) throws -> ExchangeAction {
        let frame = ExchangeFrame(source: nonce, destination: peer ?? Data(repeating: 0, count: 16), body: body)
        let bytes = try ExchangeWire.encode(frame, maxFrame: maxFrame)
        guard traffic + bytes.count <= 262_144 else { throw SessionFailure.reason(2) }
        traffic += bytes.count
        return ExchangeAction(generation: generation, bytes: bytes)
    }
    private enum SessionFailure: Error { case reason(Int), stale }
    private func live() throws { guard active else { throw SessionFailure.stale } }
    private func close(_ reason: Int) -> [ExchangeAction] {
        guard active else { return [] }
        failureReason = reason == 0 ? nil : reason
        // CLOSE itself is bounded even when the encounter byte budget is exhausted.
        let frame = peer.map { ExchangeFrame(source: nonce, destination: $0, body: .close(reason)) }
        let bytes = frame.flatMap { try? ExchangeWire.encode($0) }
        active = false; incoming = nil; discardPending()
        return bytes.map { [ExchangeAction(generation: generation, bytes: $0)] } ?? []
    }
    private func time(_ elapsed: Int64) throws {
        guard elapsed >= 0, elapsed >= observed else { throw SessionFailure.reason(5) }
        observed = elapsed
        if elapsed - began >= 30_000 || (peer == nil && elapsed - began >= 5_000) || elapsed - last >= 10_000 { throw SessionFailure.reason(5) }
    }
    public func start(elapsed: Int64) -> [ExchangeAction] {
        guard active, !started else { return [] }
        guard elapsed >= 0, nonce.count == 16, nonce != Data(repeating: 0, count: 16) else { return close(3) }
        started = true; began = elapsed; last = elapsed; observed = elapsed
        do { return [try emit(.hello(features: 1, maxFrame: 16_384, maxChunk: 1024))] } catch { return close(2) }
    }
    public func tick(elapsed: Int64) -> [ExchangeAction] {
        guard active, started else { return [] }
        do { try time(elapsed); return [] } catch { return close(5) }
    }
    public func receive(_ bytes: Data, generation callbackGeneration: UInt64, elapsed: Int64) async -> [ExchangeAction] {
        guard active, started, callbackGeneration == generation else { return [] }
        guard pending.count < 64, queuedBytes + bytes.count <= 262_144 else { return close(2) }
        // Validate event ordering on ingress, before repository suspension can delay it.
        do { try time(elapsed) } catch { return close(5) }
        last = elapsed
        return await withCheckedContinuation { continuation in
            pending.append(QueuedInput(bytes: bytes, elapsed: elapsed, continuation: continuation)); queuedBytes += bytes.count
            if !working { working = true; Task { await self.drain() } }
        }
    }
    private func drain() async {
        while !pending.isEmpty {
            let input = pending.removeFirst(); queuedBytes -= input.bytes.count
            let actions = await process(input.bytes, elapsed: input.elapsed)
            input.continuation.resume(returning: actions)
        }
        working = false
    }
    private func process(_ bytes: Data, elapsed: Int64) async -> [ExchangeAction] {
        guard active else { return [] }
        do {
            // A tick may have advanced the clock after this callback was queued.
            // Its original arrival timestamp was already checked by receive.
            try time(max(observed, elapsed))
            guard bytes.count <= 262_144, traffic + bytes.count <= 262_144 else { throw SessionFailure.reason(2) }
            traffic += bytes.count
            let frames = try decoder.feed(bytes)
            var actions: [ExchangeAction] = []
            for frame in frames {
                try live()
                _ = try ExchangeWire.encode(frame, maxFrame: maxFrame)
                actions += try await handle(frame, now: wallClock())
                guard actions.count <= 256 else { throw SessionFailure.reason(2) }
                if !active { return actions }
            }
            try live(); return actions
        } catch SessionFailure.stale { return [] }
        catch let SessionFailure.reason(reason) { return close(reason) }
        catch ExchangeWireError.unsupported { return close(6) }
        catch ExchangeWireError.malformed { return close(3) }
        catch { return close(4) }
    }
    private func page(now: Int64) async throws -> [ExchangeAction] {
        guard localPage < 8, offered < 32 else { throw SessionFailure.reason(2) }
        let result = try await store.inventoryPage(after: cursor, limit: 8, now: wallClock()); try live()
        cursor = result.nextCursor; moreLocal = result.hasMore && localPage < 7
        advertised = result.entries
        return [try emit(.summary(page: localPage, more: moreLocal, entries: result.entries))]
    }
    private func finishPage(now: Int64) async throws -> [ExchangeAction] {
        advertised = nil
        if moreLocal { localPage += 1; return try await page(now: now) }
        localDone = true
        var actions = [try emit(.done)]; actions += try finish(); return actions
    }
    private func finish() throws -> [ExchangeAction] {
        if localDone && remoteDone && incoming == nil && requested.isEmpty && awaiting == nil { return close(0) }; return []
    }
    private func sendNext(now: Int64) async throws -> [ExchangeAction] {
        guard !outbound.isEmpty else { return try await finishPage(now: now) }
        let descriptor = outbound.removeFirst()
        guard let loaded = try await store.loadOutgoing(descriptor.id, now: wallClock()) else { throw SessionFailure.reason(4) }; try live()
        guard loaded.descriptor == descriptor else { throw SessionFailure.reason(4) }
        offered += 1; awaiting = (offered, descriptor)
        var actions = [try emit(.offer(transfer: offered, descriptor: descriptor))]
        for offset in stride(from: 0, to: loaded.wire.count, by: maxChunk) {
            actions.append(try emit(.chunk(transfer: offered, offset: offset, total: loaded.wire.count, bytes: loaded.wire.subdata(in: offset..<min(offset + maxChunk, loaded.wire.count)))))
        }
        return actions
    }
    private func handle(_ frame: ExchangeFrame, now: Int64) async throws -> [ExchangeAction] {
        if case let .hello(features, frameLimit, chunkLimit) = frame.body {
            guard peer == nil, frame.destination == Data(repeating: 0, count: 16), frame.source != nonce, frame.source != Data(repeating: 0, count: 16) else { throw SessionFailure.reason(3) }
            guard features & 1 == 1 else { throw SessionFailure.reason(6) }
            peer = frame.source; maxFrame = min(maxFrame, frameLimit); maxChunk = min(maxChunk, min(chunkLimit, maxFrame - 47)); decoder.maxFrame = maxFrame
            return try await page(now: now)
        }
        guard let peer, frame.source == peer, frame.destination == nonce else { throw SessionFailure.reason(3) }
        switch frame.body {
        case let .summary(number, more, entries):
            guard !remoteDone, remoteMore, requested.isEmpty, incoming == nil, number == remotePage,
                  entries.first.map({ lastRemoteID == nil || lastRemoteID! < $0.id }) ?? true else { throw SessionFailure.reason(3) }
            remoteMore = more
            remotePage += 1; lastRemoteID = entries.last?.id ?? lastRemoteID
            let known = try await store.currentIDs(entries.map(\.id), now: wallClock()); try live()
            requested = entries.filter { !known.contains($0.id) }
            // A final page is followed by DONE only after its requested transfers finish.
            guard !more || remotePage < 8 else { throw SessionFailure.reason(3) }
            return [try emit(.request(requested.map(\.id)))]
        case let .request(ids):
            guard let advertised, awaiting == nil, outbound.isEmpty else { throw SessionFailure.reason(3) }
            let chosen = advertised.filter { ids.contains($0.id) }
            guard chosen.map(\.id) == ids else { throw SessionFailure.reason(3) }
            guard offered + ids.count <= 32 else { throw SessionFailure.reason(2) }
            outbound = chosen
            return try await sendNext(now: now)
        case let .offer(transfer, descriptor):
            guard incoming == nil, requested.first == descriptor, transfer == remoteTransfers + 1 else { throw SessionFailure.reason(3) }
            remoteTransfers = transfer
            incoming = Incoming(transfer: transfer, descriptor: descriptor, bytes: Data(count: descriptor.total), received: Array(repeating: false, count: descriptor.total))
            return []
        case let .chunk(transfer, offset, total, bytes):
            guard bytes.count <= maxChunk else { throw SessionFailure.reason(3) }
            if let done = completed[transfer] {
                guard done.0.total == total, done.2.subdata(in: offset..<offset + bytes.count) == bytes else { throw SessionFailure.reason(3) }
                return [try emit(.received(transfer: transfer, id: done.0.id, result: done.1))]
            }
            guard var buffer = incoming, transfer == buffer.transfer, total == buffer.descriptor.total else { throw SessionFailure.reason(3) }
            for (index, byte) in bytes.enumerated() {
                let position = offset + index
                if buffer.received[position] { guard buffer.bytes[position] == byte else { throw SessionFailure.reason(3) } }
                else { buffer.bytes[position] = byte; buffer.received[position] = true; buffer.count += 1 }
            }
            incoming = buffer
            guard buffer.count == total else { return [] }
            // Verify requested identity before any repository write.
            let checked = ReportAdmission.validate(buffer.bytes, now: now)
            let outcome: ReportStoreOutcome
            if checked.outcome == "accepted", checked.bundleID != buffer.descriptor.id { outcome = .rejected(.invalid) }
            else { outcome = try await store.ingestTransferred(buffer.bytes, offeredHops: buffer.descriptor.hops, clock: wallClock) }
            try live()
            let result: Int
            switch outcome { case .stored: result = 0; case .duplicate: result = 1; case .rejected(.expired): result = 2; case .rejected(.invalid): result = 3; case .rejected(.quota): result = 4; case .rejected(.unsupported): result = 5 }
            completed[transfer] = (buffer.descriptor, result, buffer.bytes); incoming = nil; requested.removeFirst()
            return [try emit(.received(transfer: transfer, id: buffer.descriptor.id, result: result))]
        case let .received(transfer, id, result):
            if let previous = acknowledged[transfer] { guard previous.0 == id && previous.1 == result else { throw SessionFailure.reason(3) }; return [] }
            guard let waiting = awaiting, waiting.0 == transfer, waiting.1.id == id else { throw SessionFailure.reason(3) }
            acknowledged[transfer] = (id, result); peerOutcomes.append(result); awaiting = nil
            return try await sendNext(now: now)
        case .done:
            guard !remoteDone, !remoteMore, remotePage > 0, requested.isEmpty, incoming == nil else { throw SessionFailure.reason(3) }
            remoteDone = true; return try finish()
        case let .close(reason):
            guard reason != 0 || (localDone && remoteDone && incoming == nil && requested.isEmpty && awaiting == nil) else { throw SessionFailure.reason(3) }
            active = false; incoming = nil; discardPending(); failureReason = reason == 0 ? nil : reason; return []
        case .hello: throw SessionFailure.reason(3)
        }
    }
}
