import Foundation
import Network
import NearChatCore

final class LANTransport {
    var onOpen: ((String, String) -> Void)?
    var onClose: ((String) -> Void)?
    var onFrame: ((Data, String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let serviceType = "_nearchat._tcp"
    private let serviceName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var decoders: [String: FrameDecoder] = [:]
    private var outboundNames: [String: String] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var ready: Set<String> = []
    private var queuedBytes: [String: Int] = [:]
    private var running = false
    private var generation = UUID()

    init(nodeID: String) { serviceName = "nc-" + nodeID.prefix(24) }
    private func parameters() -> NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = false // LAN mode is intentionally independent of BLE/AWDL.
        p.prohibitedInterfaceTypes = [.cellular]
        return p
    }
    func start() {
        guard !running else { return }
        running = true; generation = UUID()
        let epoch = generation
        do {
            let listener = try NWListener(using: parameters())
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.running, self.generation == epoch else { connection.cancel(); return }
                self.attach(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.running, self.generation == epoch else { return }
                switch state {
                case .ready: self.onStatus?("Wi-Fi/LAN: обнаружение включено")
                case .failed(let error): self.onStatus?("LAN listener: \(error.localizedDescription)"); self.stop()
                default: break
                }
            }
            self.listener = listener; listener.start(queue: .main)
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters())
            browser.stateUpdateHandler = { [weak self] state in
                guard let self, self.running, self.generation == epoch else { return }
                if case .failed(let error) = state { self.onStatus?("Bonjour: \(error.localizedDescription)") }
                if case .waiting(let error) = state { self.onStatus?("Bonjour ожидает: \(error.localizedDescription)") }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self, self.running, self.generation == epoch else { return }
                var current: [String: NWEndpoint] = [:]
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint, name != self.serviceName {
                        current[name] = result.endpoint
                    }
                }
                self.endpoints = current
                for (name, endpoint) in current { self.connect(name: name, endpoint: endpoint) }
            }
            self.browser = browser; browser.start(queue: .main)
        } catch { running = false; onStatus?("LAN: \(error.localizedDescription)") }
    }
    func stop() {
        running = false; generation = UUID()
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil; endpoints.removeAll()
        for id in Array(connections.keys) { detach(id) }
        onStatus?("Wi-Fi/LAN: остановлен")
    }
    func send(_ data: Data, on link: String) {
        guard let connection = connections[link], ready.contains(link) else { return }
        let framed = FrameDecoder.frame(data)
        let count = (queuedBytes[link] ?? 0) + framed.count
        guard count <= 262_144 else { onStatus?("LAN: очередь переполнена, связь закрыта"); detach(link); return }
        queuedBytes[link] = count
        connection.send(content: framed, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connections[link] === connection else { return }
            self.queuedBytes[link] = max(0, (self.queuedBytes[link] ?? 0) - framed.count)
            if error != nil { self.detach(link) }
        })
    }
    private func connect(name: String, endpoint: NWEndpoint) {
        // Stable ordering produces one TCP connection per pair, not two simultaneous dials.
        guard running, name > serviceName, !outboundNames.values.contains(name), connections.count < 16 else { return }
        let connection = NWConnection(to: endpoint, using: parameters())
        attach(connection, name: name)
    }
    private func attach(_ connection: NWConnection, name: String? = nil) {
        guard running, connections.count < 16 else { connection.cancel(); return }
        let id = "lan-" + UUID().uuidString
        connections[id] = connection; decoders[id] = FrameDecoder()
        outboundNames[id] = name
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connections[id] === connection else { return }
            switch state {
            case .ready:
                guard !self.ready.contains(id) else { return }
                self.ready.insert(id); self.onOpen?(id, "Wi-Fi/LAN"); self.receive(id)
            case .failed, .cancelled: self.detach(id)
            case .waiting(let error): self.onStatus?("LAN ожидает: \(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: .main)
    }
    private func receive(_ id: String) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connections[id] === connection else { return }
            if let data, !data.isEmpty {
                do {
                    var decoder = self.decoders[id] ?? FrameDecoder()
                    let frames = try decoder.append(data); self.decoders[id] = decoder
                    for frame in frames { self.onFrame?(frame, id) }
                } catch { self.detach(id); return }
            }
            if complete || error != nil { self.detach(id) } else { self.receive(id) }
        }
    }
    private func detach(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        let name = outboundNames.removeValue(forKey: id)
        connection.stateUpdateHandler = nil; connection.cancel()
        decoders.removeValue(forKey: id); queuedBytes.removeValue(forKey: id)
        if ready.remove(id) != nil { onClose?(id) }
        let epoch = generation
        if let name, running {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.running, self.generation == epoch, let endpoint = self.endpoints[name] else { return }
                self.connect(name: name, endpoint: endpoint)
            }
        }
    }
}
