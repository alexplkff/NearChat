import Foundation
import NearChatCore

/// Standalone controlled peer. It sends only to the explicitly supplied public fingerprint.
@main
struct NetworkProbe {
    static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "lan"
        let identity = try MeshIdentity(name: "NearChat QA Mac")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearChatQA-" + UUID().uuidString)
        let store = try MeshStore(directory: root, identity: identity)
        let engine = try MeshEngine(identity: identity, store: store)
        let lan = LANTransport(nodeID: identity.card.id)
        let ble = BLETransport()
        var fingerprint: String?
        var messageID: UUID?
        var requested = false
        var reported: Set<String> = []
        var ticks = 0
        let token = "NearChat QA " + mode.uppercased() + " " + UUID().uuidString
        func output(_ line: String) { print(line); fflush(stdout) }
        engine.onTransmit = { link, data in
            if link.hasPrefix("lan-") { lan.send(data, on: link) } else { ble.send(data, on: link) }
        }
        lan.onOpen = { engine.linkOpened(id: $0, transport: $1) }
        ble.onOpen = { engine.linkOpened(id: $0, transport: $1) }
        lan.onClose = { engine.linkClosed(id: $0) }; ble.onClose = { engine.linkClosed(id: $0) }
        let receive: (Data, String) -> Void = { data, link in
            guard let packet = try? MeshPacket.decode(data, now: Date()),
                  packet.body.kind == .presence || (packet.body.recipient == identity.card.id &&
                    packet.body.sender.fingerprint == fingerprint) else { return }
            engine.receive(data, from: link)
        }
        lan.onFrame = receive; ble.onFrame = receive
        lan.onStatus = { output("TRANSPORT " + $0) }; ble.onStatus = { output("TRANSPORT " + $0) }
        engine.onChange = {
            if messageID == nil, let fingerprint,
               let peer = engine.peers.values.first(where: { $0.card.fingerprint == fingerprint }) {
                guard engine.canSendDirect(to: peer.id) else {
                    if !requested {
                        requested = true
                        do { try engine.requestContact(to: peer.id); output("QA_CONSENT_REQUIRED Accept the request on iPhone") }
                        catch { output("QA_ERROR " + error.localizedDescription) }
                    }
                    return
                }
                // Mark before sending: MeshEngine invokes onChange synchronously.
                messageID = UUID()
                do { messageID = try engine.send(text: token, to: peer.id); output("QA_SENT " + token) }
                catch { messageID = nil; output("QA_ERROR " + error.localizedDescription) }
            }
            if let messageID, let entry = engine.messages.first(where: { $0.id == messageID }),
               reported.insert(entry.state.rawValue).inserted {
                output("QA_STATE " + entry.state.title)
            }
        }
        engine.beginNetworking()
        if mode == "ble" { ble.start() } else { lan.start() }
        output("QA_READY mode=" + mode + " macFingerprint=" + identity.card.fingerprint)
        output("Send the target iPhone's 16-character fingerprint on stdin. Type stop to finish.")
        DispatchQueue.global().async {
            while let input = readLine() {
                DispatchQueue.main.async {
                    let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if value == "stop" {
                        lan.stop(); ble.stop(); engine.endNetworking()
                        try? FileManager.default.removeItem(at: root)
                        exit(0)
                    }
                    if value.count == 16 && value.allSatisfy({ $0.isHexDigit }) {
                        fingerprint = value; output("QA_TARGET_SET"); engine.tick()
                    }
                }
            }
        }
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            ticks += 1; engine.tick()
            if ticks % 5 == 0 { engine.announce() }
        }
        RunLoop.main.run()
    }
}
