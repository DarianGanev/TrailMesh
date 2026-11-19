import Foundation

public final class PackLease: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    fileprivate init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    public func close() {
        lock.lock(); let action = release; release = nil; lock.unlock(); action?()
    }
    deinit { close() }
}
public final class PackLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var installing = Set<String>()
    public init() {}
    public func acquire(_ key: String) -> PackLease {
        lock.lock(); defer { lock.unlock() }
        return acquireLocked(key)
    }
    func acquire(_ key: String, validating action: () throws -> Void) throws -> PackLease {
        lock.lock(); defer { lock.unlock() }
        try action()
        return acquireLocked(key)
    }
    private func acquireLocked(_ key: String) -> PackLease {
        counts[key, default: 0] += 1
        return PackLease { [self] in
            lock.lock(); counts[key, default: 0] -= 1; lock.unlock()
        }
    }
    public func withRemoval(_ key: String, _ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard counts[key, default: 0] == 0, !installing.contains(key) else { throw MapFailure.busy }
        try action()
    }
    func withMaintenance(_ action: () throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        try action()
    }
    func beginInstallation(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard installing.insert(key).inserted else { throw MapFailure.busy }
    }
    func endInstallation(_ key: String) {
        lock.lock(); installing.remove(key); lock.unlock()
    }
}

/// Stores for one canonical filesystem root must coordinate even when their
/// actors differ. Weak entries keep temporary roots out of a permanent cache;
/// active leases retain their state until the native consumer releases them.
final class PackRootRegistry: @unchecked Sendable {
    static let shared = PackRootRegistry()
    private final class Entry {
        weak var leases: PackLeases?
        init(_ leases: PackLeases) { self.leases = leases }
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func leases(for root: URL) -> PackLeases {
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[root.path]?.leases { return existing }
        entries = entries.filter { $0.value.leases != nil }
        let leases = PackLeases()
        entries[root.path] = Entry(leases)
        return leases
    }
}

/// Cancellation and publication share a lock. Once cancel returns, this operation
/// can never publish, even if a network callback arrives late.
public final class InstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public func cancel() {
        lock.lock()
        cancelled = true
        let actions = handlers.values
        handlers.removeAll()
        lock.unlock()
        for action in actions { action() }
    }
    func onCancel(_ action: @escaping @Sendable () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !Task.isCancelled else { throw MapFailure.cancelled }
        let id = UUID()
        handlers[id] = action
        return id
    }
    func removeHandler(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }
    public func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled || Task.isCancelled { throw MapFailure.cancelled } }
    func publish(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !Task.isCancelled else { throw MapFailure.cancelled }
        try action()
    }
}
