import Foundation
import NearbyConnections
import TrailMeshReports

/// Product service adapter. Automatic compatible-link acceptance is authorized
/// only by the coordinator's active explicit public-sharing consent. SDK codes
/// do not authenticate a person, and they are never logged or exported.
@MainActor
final class ProductNearbyRadio: ReportSessionRadio {
    weak var delegate: (any ReportSessionRadioDelegate)?
    private var manager: ConnectionManager?
    private var scanner: Discoverer?
    private var broadcaster: Advertiser?
    private var endpoints: Set<String> = []
    private var epoch: UInt64 = 0
    private var pending: [Int64: (ticket: UInt64, endpoint: String)] = [:]
    private enum SendFailure: Error { case unavailable, capacity }
    func start(advertisement: Data, epoch: UInt64) {
        stop()
        self.epoch = epoch
        let manager = ConnectionManager(serviceID: ReportAdvertisement.serviceID, strategy: .cluster, queue: .main)
        manager.delegate = self
        let scanner = Discoverer(connectionManager: manager)
        scanner.delegate = self
        let broadcaster = Advertiser(connectionManager: manager)
        broadcaster.delegate = self
        self.manager = manager; self.scanner = scanner; self.broadcaster = broadcaster
        scanner.startDiscovery(mediums: [.ble]) { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let manager, self.manager === manager, error != nil else { return }
                self.delegate?.radioUnavailable(epoch: epoch)
            }
        }
        broadcaster.startAdvertising(using: advertisement, mediums: [.ble]) { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let manager, self.manager === manager, error != nil else { return }
                self.delegate?.radioUnavailable(epoch: epoch)
            }
        }
    }
    func stop() {
        scanner?.stopDiscovery(); broadcaster?.stopAdvertising()
        for endpoint in endpoints { manager?.disconnect(from: endpoint) }
        pending.removeAll(); endpoints.removeAll()
        // All callbacks retain and compare the exact SDK owner. Recreating it is
        // the epoch boundary required before any endpoint can be reused.
        scanner = nil; broadcaster = nil; manager = nil
    }
    func connect(endpoint: String, advertisement: Data, epoch: UInt64) {
        guard self.epoch == epoch, let manager, let scanner else { return }
        endpoints.insert(endpoint)
        scanner.requestConnection(to: endpoint, using: advertisement, mediums: [.ble]) { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let manager, self.manager === manager, error != nil else { return }
                self.delegate?.radioDisconnected(endpoint: endpoint, epoch: epoch)
            }
        }
    }
    func disconnect(endpoint: String) {
        endpoints.remove(endpoint)
        pending = pending.filter { $0.value.endpoint != endpoint }
        manager?.disconnect(from: endpoint)
    }
    func send(_ bytes: Data, endpoint: String, ticket: UInt64) throws {
        guard let manager else { throw SendFailure.unavailable }
        guard pending.values.filter({ $0.endpoint == endpoint }).count < 64 else { throw SendFailure.capacity }
        var payloadID = Int64.random(in: 1...Int64.max)
        while pending[payloadID] != nil { payloadID = Int64.random(in: 1...Int64.max) }
        pending[payloadID] = (ticket, endpoint)
        _ = manager.send(bytes, to: [endpoint], id: payloadID) { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let manager, self.manager === manager else { return }
                // This callback reports enqueue/attempt failure only. A nil
                // error does not establish that the payload finished sending.
                // Keep its ticket until didReceiveTransferUpdate succeeds.
                if error != nil { self.complete(payloadID, succeeded: false) }
            }
        }
    }
    private func complete(_ payloadID: Int64, succeeded: Bool) {
        guard let outgoing = pending.removeValue(forKey: payloadID) else { return }
        delegate?.radioSent(ticket: outgoing.ticket, succeeded: succeeded, endpoint: outgoing.endpoint, epoch: epoch)
    }
}
extension ProductNearbyRadio: DiscovererDelegate, AdvertiserDelegate, ConnectionManagerDelegate {
    func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
        guard scanner === discoverer else { return }
        delegate?.radioFound(endpoint: endpointID, advertisement: context, epoch: epoch)
    }
    func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
        guard scanner === discoverer else { return }; delegate?.radioLost(endpoint: endpointID, epoch: epoch)
    }
    func advertiser(_ advertiser: Advertiser, didReceiveConnectionRequestFrom endpointID: EndpointID, with context: Data, connectionRequestHandler: @escaping (Bool) -> Void) {
        guard broadcaster === advertiser else { connectionRequestHandler(false); return }
        let accepted = delegate?.radioRequested(endpoint: endpointID, advertisement: context, epoch: epoch) == true
        if accepted { endpoints.insert(endpointID) }
        connectionRequestHandler(accepted)
    }
    func connectionManager(_ connectionManager: ConnectionManager, didReceive verificationCode: String, from endpointID: EndpointID, verificationHandler: @escaping (Bool) -> Void) {
        guard manager === connectionManager else { verificationHandler(false); return }
        verificationHandler(delegate?.radioMayVerify(endpoint: endpointID, epoch: epoch) == true)
    }
    func connectionManager(_ connectionManager: ConnectionManager, didReceive data: Data, withID payloadID: PayloadID, from endpointID: EndpointID) {
        guard manager === connectionManager else { return }
        delegate?.radioReceived(data, endpoint: endpointID, epoch: epoch)
    }
    func connectionManager(_ connectionManager: ConnectionManager, didReceive stream: InputStream, withID payloadID: PayloadID, from endpointID: EndpointID, cancellationToken token: CancellationToken) {
        token.cancel()
        guard manager === connectionManager else { return }; delegate?.radioDisconnected(endpoint: endpointID, epoch: epoch)
    }
    func connectionManager(_ connectionManager: ConnectionManager, didStartReceivingResourceWithID payloadID: PayloadID, from endpointID: EndpointID, at localURL: URL, withName name: String, cancellationToken token: CancellationToken) {
        token.cancel()
        guard manager === connectionManager else { return }; delegate?.radioDisconnected(endpoint: endpointID, epoch: epoch)
    }
    func connectionManager(_ connectionManager: ConnectionManager, didReceiveTransferUpdate update: TransferUpdate, from endpointID: EndpointID, forPayload payloadID: PayloadID) {
        guard manager === connectionManager else { return }
        switch update { case .success: complete(payloadID, succeeded: true); case .failure, .canceled: complete(payloadID, succeeded: false); case .progress: break }
    }
    func connectionManager(_ connectionManager: ConnectionManager, didChangeTo state: ConnectionState, for endpointID: EndpointID) {
        guard manager === connectionManager else { return }
        switch state {
        case .connected: delegate?.radioConnected(endpoint: endpointID, epoch: epoch)
        case .rejected, .disconnected: delegate?.radioDisconnected(endpoint: endpointID, epoch: epoch)
        case .connecting: break
        }
    }
}
