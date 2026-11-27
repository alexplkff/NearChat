import Foundation
import Combine
import SwiftUI
import NearChatCore

struct ChatListRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let preview: String
    let symbol: String
    let fingerprint: String?
    let summary: ConversationSummary?
    let archived: Bool
    var unread: Int { summary?.unreadCount ?? 0 }
}

final class LabModel: ObservableObject {
    @Published var revision = 0
    @Published var running = false
    @Published var useLAN = true
    @Published var useBLE = true
    @Published var name: String
    @Published var selectedPeer = "*" {
        willSet { if newValue != selectedPeer { drafts[selectedPeer] = draft } }
        didSet {
            visibleMessageIDs = []
            if oldValue != selectedPeer { draft = drafts[selectedPeer] ?? "" }
            if chatIsOpen { engine.openConversation(selectedPeer) }
        }
    }
    @Published var chatIsOpen = false {
        didSet {
            guard chatIsOpen != oldValue else { return }
            visibleMessageIDs = []
            if !chatIsOpen { drafts[selectedPeer] = draft }
            engine.openConversation(chatIsOpen ? selectedPeer : nil)
        }
    }
    @Published var draft = ""
    @Published var failure: String?
    @Published var phase = "Остановлен"
    @Published var tab = 1 {
        didSet { if tab != 1 && chatIsOpen { chatIsOpen = false } }
    }
    @Published var historyBudgetMB = "100"
    @Published var relayBudgetMB = "5"
    @Published var storageNote: String?
    @Published var pendingHistoryCleanup: HistoryCleanupPlan?
    @Published var historyCleanupResult: HistoryCleanupResult?
    @Published var cleanupFailure: String?
    @Published var pendingStorageResize: StorageResizePlan?
    let engine: MeshEngine
    private let lan: LANTransport
    private let ble = BLETransport()
    private var drafts: [String: String] = [:]
    private var readingSuspended = false
    private var visibleMessageIDs: Set<UUID> = []
    private var appActive = true
    private var storageSettingsLoaded = false
    private var timer: Timer?
    private var seconds = 0
    private var persistentIdentity = false
    private let isPreview: Bool
    private var knownNames: [String: String] = [:]

    init(previewEngine: MeshEngine? = nil) {
        isPreview = previewEngine != nil
        let name = previewEngine?.identity.name ?? UserDefaults.standard.string(forKey: "nickname") ?? "Участник-\(Int.random(in: 100...999))"
        self.name = name
        let identity: MeshIdentity
        var identityError: String?
        var historyError: String?
        var restoredEngine: MeshEngine?
        if let previewEngine {
            identity = previewEngine.identity; restoredEngine = previewEngine
        } else {
            do {
                identity = try IdentityStore().load(name: name)
                persistentIdentity = true
                UserDefaults.standard.set(name, forKey: "nickname")
            }
            catch {
                // Fresh CryptoKit keys take no external input; the throwing path only decodes supplied key data.
                identity = try! MeshIdentity(name: name)
                identityError = "Постоянная идентичность недоступна; используется временная: \(error.localizedDescription)"
            }
            if identityError == nil {
                do {
                    restoredEngine = try MeshEngine(identity: identity, store: Self.openStore(identity: identity))
                } catch {
                    historyError = "Не удалось открыть хранилище; исходные файлы сохранены: \(error.localizedDescription)"
                }
            }
        }
        if let restoredEngine { engine = restoredEngine }
        else {
            let history = identityError == nil ? (try? Self.legacyStore(identity: identity).load()) ?? [] : []
            engine = MeshEngine(identity: identity, history: history)
        }
        if let limits = engine.storageLimits {
            historyBudgetMB = String(limits.historyBytes / 1_000_000)
            relayBudgetMB = String(limits.relayBytes / 1_000_000)
            storageSettingsLoaded = true
        }
        lan = LANTransport(nodeID: identity.card.id)
        rememberNames()
        engine.onChange = { [weak self] in
            guard let self else { return }
            self.rememberNames()
            if !self.storageSettingsLoaded, let limits = self.engine.storageLimits {
                if self.historyBudgetMB == "100" { self.historyBudgetMB = String(limits.historyBytes / 1_000_000) }
                if self.relayBudgetMB == "5" { self.relayBudgetMB = String(limits.relayBytes / 1_000_000) }
                self.storageSettingsLoaded = true
            }
            self.revision &+= 1
        }
        if identityError == nil && !isPreview {
            engine.onRecoverStorage = { [weak self] in
                guard let self else { return nil }
                return try? Self.openStore(identity: self.engine.identity)
            }
        }
        engine.onTransmit = { [weak self] link, data in
            guard let self else { return }
            if link.hasPrefix("lan-") { self.lan.send(data, on: link) } else { self.ble.send(data, on: link) }
        }
        lan.onOpen = { [weak self] id, transport in
            guard let self, self.running else { return }
            self.engine.linkOpened(id: id, transport: transport)
        }
        ble.onOpen = { [weak self] id, transport in
            guard let self, self.running else { return }
            self.engine.linkOpened(id: id, transport: transport)
        }
        lan.onClose = { [weak self] in self?.engine.linkClosed(id: $0) }
        ble.onClose = { [weak self] in self?.engine.linkClosed(id: $0) }
        lan.onFrame = { [weak self] in self?.engine.receive($0, from: $1) }
        ble.onFrame = { [weak self] in self?.engine.receive($0, from: $1) }
        lan.onStatus = { [weak self] in self?.engine.note($0) }
        ble.onStatus = { [weak self] in self?.engine.note($0) }
        if let identityError { failure = identityError; engine.note(identityError) }
        if let historyError { failure = historyError; engine.note(historyError) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.engine.tick(); self.seconds += 1
            if self.running && self.seconds % 5 == 0 { self.engine.announce() }
            self.markVisibleMessagesRead()
        }
    }
    deinit { timer?.invalidate() }

    private func rememberNames() {
        var names: [String: String] = [:]
        for message in engine.messages {
            names[message.sender.id] = message.sender.name
            if let name = message.recipientName { names[message.recipient] = name }
        }
        for peer in engine.peers.values { names[peer.id] = peer.card.name }
        knownNames = names
    }
    private static func storageDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("NearChat", isDirectory: true)
    }
    private static func legacyStore(identity: MeshIdentity) throws -> HistoryStore {
        HistoryStore(fileURL: try storageDirectory().appendingPathComponent("history-v1.sealed"), identity: identity)
    }
    private static func openStore(identity: MeshIdentity) throws -> MeshStore {
        let directory = try storageDirectory()
        let legacyURL = directory.appendingPathComponent("history-v1.sealed")
        // Read and validate the old archive before touching migration state.
        let legacy = try legacyStore(identity: identity).load()
        let store = try MeshStore(directory: directory, identity: identity)
        try store.importLegacy(legacy)
        _ = try store.history()
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try FileManager.default.removeItem(at: legacyURL)
        }
        return store
    }
    func requestHistoryCleanup() {
        historyCleanupResult = nil; cleanupFailure = nil
        do { pendingHistoryCleanup = try engine.prepareHistoryCleanup() }
        catch { failure = error.localizedDescription }
    }
    func confirmHistoryCleanup() {
        guard let plan = pendingHistoryCleanup, historyCleanupResult == nil else { return }
        do { historyCleanupResult = try engine.applyHistoryCleanup(plan, confirmed: true); cleanupFailure = nil }
        catch MeshStorageError.resizeChanged {
            do {
                pendingHistoryCleanup = try engine.prepareHistoryCleanup()
                cleanupFailure = "История изменилась. Проверьте новый расчёт и подтвердите его заново."
            } catch { cleanupFailure = error.localizedDescription }
        } catch {
            cleanupFailure = "Очистку не удалось завершить: \(error.localizedDescription). Для безопасной записи может потребоваться освободить немного места в другом приложении."
        }
    }
    func closeHistoryCleanup() { pendingHistoryCleanup = nil; historyCleanupResult = nil; cleanupFailure = nil }
    func requestStorageResize(_ area: MeshStorageArea) {
        storageNote = nil
        do {
            let text = area == .history ? historyBudgetMB : relayBudgetMB
            guard let megabytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  megabytes >= area.minimumMegabytes, megabytes <= Int64(Int32.max) else {
                throw MeshStorageError.invalidBudget
            }
            let plan = try engine.prepareStorageResize(area, to: megabytes * 1_000_000)
            if plan.requiresConfirmation { pendingStorageResize = plan }
            else { try applyStorageResize(plan, confirmed: false) }
        } catch { storageNote = error.localizedDescription }
    }
    func confirmStorageResize() {
        guard let plan = pendingStorageResize else { return }
        do { try applyStorageResize(plan, confirmed: true) }
        catch MeshStorageError.resizeChanged {
            do {
                pendingStorageResize = try engine.prepareStorageResize(plan.area, to: plan.newLimit)
                storageNote = "Данные изменились. Проверьте новый расчёт перед очисткой."
            } catch { storageNote = error.localizedDescription }
        } catch { storageNote = error.localizedDescription }
    }
    func cancelStorageResize() { pendingStorageResize = nil; storageNote = nil }
    private func applyStorageResize(_ plan: StorageResizePlan, confirmed: Bool) throws {
        try engine.applyStorageResize(plan, confirmed: confirmed)
        if plan.area == .history { historyBudgetMB = String(plan.newLimit / 1_000_000) }
        else { relayBudgetMB = String(plan.newLimit / 1_000_000) }
        pendingStorageResize = nil
        storageNote = "Лимит «\(plan.area.title)» сохранён."
    }
    func setVisibleMessages(_ ids: Set<UUID>) {
        visibleMessageIDs = ids
        markVisibleMessagesRead()
    }
    private func markVisibleMessagesRead() {
        guard appActive, tab == 1, chatIsOpen, !readingSuspended else { return }
        for id in visibleMessageIDs.intersection(Set(visibleMessages.map(\.id))) { engine.markRead(id) }
    }
    func openChat(_ id: String) {
        selectedPeer = id; tab = 1; chatIsOpen = true
    }
    func setReadingSuspended(_ value: Bool) {
        readingSuspended = value
        if !value { markVisibleMessagesRead() }
    }
    var chatRows: [ChatListRow] {
        let summaries = Dictionary(uniqueKeysWithValues: engine.conversations.map { ($0.id, $0) })
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ("g:" + $0.id.uuidString, $0) })
        let contacts = Dictionary(uniqueKeysWithValues: engine.directContacts.map { ($0.id, $0) })
        let cards = Dictionary(uniqueKeysWithValues: engine.knownParticipants.map { ($0.id, $0) })
        let ids = Set(summaries.keys).union(groupMap.keys).union(contacts.keys).union(["*"])
        return ids.map { id in
            let summary = summaries[id]
            let last = summary?.lastMessage
            let group = groupMap[id]
            let contact = contacts[id]
            let card = cards[id] ?? (last?.outgoing == false ? last?.sender : nil)
            let title = id == "*" ? "Общий чат" : group?.name ?? card?.name ?? last?.recipientName ?? String(id.prefix(8))
            let fingerprint = id == "*" || group != nil ? nil : card?.fingerprint ?? String(id.prefix(16))
            let archived = group.map { !$0.canSend(as: engine.identity.card.id) } ?? false
            let detail: String
            if id == "*" { detail = "Для всех доступных участников" }
            else if let group {
                detail = group.isClosed ? "Завершена · история" : (archived ? "Участие прекращено · история" : "Группа · \(group.members.count)/\(group.memberLimit)")
            } else { detail = "Метка \(fingerprint ?? "")" }
            let preview: String
            if let last {
                preview = (last.outgoing ? "Вы: " : (id == "*" || group != nil ? last.sender.name + ": " : "")) + last.text.replacingOccurrences(of: "\n", with: " ")
            } else { preview = contact?.status ?? (archived ? "Сохранённых сообщений пока нет" : "Сообщений пока нет") }
            return ChatListRow(id: id, title: title, detail: detail, preview: preview,
                symbol: id == "*" ? "bubble.left.and.bubble.right.fill" : (group != nil ? "person.2.fill" : "person.fill"),
                fingerprint: fingerprint, summary: summary, archived: archived)
        }.sorted {
            if $0.id == "*" || $1.id == "*" { return $0.id == "*" && $1.id != "*" }
            let left = $0.summary?.activityOrder ?? 0, right = $1.summary?.activityOrder ?? 0
            if left != right { return left > right }
            if $0.title != $1.title { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
    var currentChatTitle: String { chatRows.first { $0.id == selectedPeer }?.title ?? peerName(selectedPeer) }
    var currentChatUnread: Int { engine.conversations.first { $0.id == selectedPeer }?.unreadCount ?? 0 }
    var currentChatMessageCount: Int { engine.conversations.first { $0.id == selectedPeer }?.messageCount ?? 0 }
    var connectionTitle: String { running ? ((useLAN || useBLE) ? "Связь включена" : "Способы связи выключены") : "Связь выключена" }
    func retry(_ id: UUID) {
        do { _ = try engine.retry(id) }
        catch { failure = error.localizedDescription }
    }
    var peers: [MeshPeer] { engine.peers.values.sorted { $0.card.name < $1.card.name } }
    var directPeerIDs: [String] { Set(engine.links.values.compactMap(\.peerID)).sorted() }
    var canSend: Bool {
        running && !engine.memoryBufferFull && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draft.count <= 1000 && draft.utf8.count <= 4096 &&
            (selectedGroup.map { $0.canSend(as: engine.identity.card.id) } ??
                (selectedPeer == "*" ? !peers.isEmpty : engine.canSendDirect(to: selectedPeer)))
    }
    var visibleMessages: [ChatEntry] {
        engine.messages.filter { entry in
            if let group = selectedGroup { return entry.group?.groupID == group.id }
            if selectedPeer == "*" { return entry.isPublic }
            return entry.group == nil && !entry.isPublic && (entry.outgoing ? entry.recipient == selectedPeer : entry.sender.id == selectedPeer)
        }
    }
    var selectedGroup: ClosedGroup? {
        guard selectedPeer.hasPrefix("g:"), let id = UUID(uuidString: String(selectedPeer.dropFirst(2))) else { return nil }
        return engine.closedGroups.first { $0.id == id }
    }
    var groups: [ClosedGroup] {
        engine.closedGroups.filter { group in
            group.creator.id == engine.identity.card.id || engine.groupEvents(group.id).contains { event in
                if case .joined(let consent) = event.body.change { return consent.body.invitation.body.invitee.id == engine.identity.card.id }; return false
            }
        }
    }
    var groupInvitations: [GroupInvitationState] { engine.groupInvitations.filter { !$0.outgoing } }
    var groupRequestCount: Int { groupInvitations.filter { [.verifying, .offered, .waiting, .unconfirmed, .cancelPending].contains($0.phase) }.count }
    @discardableResult func createGroup(name: String, limit: Int) -> Bool {
        do {
            let id = try engine.createClosedGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), memberLimit: limit)
            openChat("g:" + id.uuidString); return true
        } catch { failure = error.localizedDescription; return false }
    }
    func acceptGroup(_ flow: GroupInvitationState) { performGroup { try engine.acceptGroupInvitation(flow.id) } }
    func declineGroup(_ flow: GroupInvitationState) { performGroup { try engine.declineGroupInvitation(flow.id) } }
    func cancelGroup(_ flow: GroupInvitationState) { performGroup { try engine.cancelGroupJoin(flow.id) } }
    func inviteGroup(_ group: ClosedGroup, peer: PeerCard) { performGroup { try engine.inviteToGroup(group.id, peerID: peer.id) } }
    func changeGroupLimit(_ group: ClosedGroup, limit: Int) { performGroup { try engine.setGroupMemberLimit(limit, groupID: group.id) } }
    func excludeGroup(_ group: ClosedGroup, peerID: String) { performGroup { try engine.excludeGroupMember(peerID, groupID: group.id) } }
    func allowGroupReturn(_ group: ClosedGroup, peer: PeerCard) { performGroup { try engine.permitGroupReturn(peer.id, groupID: group.id) } }
    func leaveGroup(_ group: ClosedGroup) { performGroup { try engine.leaveClosedGroup(group.id) } }
    private func performGroup<T>(_ action: () throws -> T) {
        do { _ = try action() } catch { failure = error.localizedDescription }
    }
    var incomingContacts: [DirectContact] { engine.directContacts.filter { $0.incomingRequestID != nil } }
    @discardableResult func verifyPeer(_ info: PeerSecurityInfo) -> Bool {
        do { try engine.verifyPeer(info.peer.id, safetyCode: info.safetyCode); return true }
        catch { failure = error.localizedDescription; return false }
    }
    func requestContact() {
        do { try engine.requestContact(to: selectedPeer) }
        catch { failure = error.localizedDescription }
    }
    @discardableResult func decideContact(_ contact: DirectContact, accept: Bool) -> Bool {
        guard let requestID = contact.incomingRequestID else { return false }
        do { try engine.respondToContact(from: contact.id, requestID: requestID, accept: accept); return true }
        catch { failure = error.localizedDescription; return false }
    }
    func blockContact(_ contact: DirectContact) {
        do { try engine.setContactBlocked(contact.id, blocked: contact.phase != .blocked) }
        catch { failure = error.localizedDescription }
    }
    func peerName(_ id: String) -> String {
        if id.hasPrefix("g:"), let uuid = UUID(uuidString: String(id.dropFirst(2))) {
            return engine.closedGroups.first { $0.id == uuid }?.name ?? "Группа"
        }
        if id == "*" { return "Общий чат" }
        if id == engine.identity.card.id { return "Вы" }
        return engine.knownParticipants.first(where: { $0.id == id })?.name ?? knownNames[id] ?? String(id.prefix(8))
    }
    func start() {
        guard !isPreview else { failure = "Тестовая сборка: радиосвязь выключена"; return }
        guard !running else { return }
        guard useLAN || useBLE else { failure = "Включите хотя бы один способ связи"; return }
        running = true; phase = "Активен"; seconds = 0
        engine.beginNetworking()
        applyName()
        if useLAN { lan.start() }
        if useBLE { ble.start() }
        engine.note("Сеанс начат")
    }
    func stop() {
        running = false; lan.stop(); ble.stop(); engine.endNetworking(); phase = "Остановлен"
        engine.note("Сеанс остановлен")
    }
    func setLAN(_ value: Bool) { useLAN = value; if running { value ? lan.start() : lan.stop() } }
    func setBLE(_ value: Bool) { useBLE = value; if running { value ? ble.start() : ble.stop() } }
    func applyName() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        if name.isEmpty { name = "Участник" }
        if persistentIdentity { UserDefaults.standard.set(name, forKey: "nickname") }
        engine.rename(name)
    }
    func send() {
        guard canSend else { return }
        do {
            if let group = selectedGroup { try engine.sendToGroup(text: draft, groupID: group.id) }
            else if selectedPeer == "*" {
                try engine.broadcast(text: draft)
            } else { try engine.send(text: draft, to: selectedPeer) }
            draft = ""; drafts.removeValue(forKey: selectedPeer)
        } catch { failure = error.localizedDescription }
    }
    func sceneChanged(_ scene: ScenePhase) {
        appActive = scene == .active
        if appActive { engine.tick(); markVisibleMessagesRead() }
        guard running else { return }
        switch scene {
        case .active:
            phase = "Активен"; engine.tick()
            // TCP connections can be invalid after suspension. Recreate LAN discovery on return.
            if useLAN { lan.stop(); lan.start() }
            engine.announce(); engine.note("Приложение активно")
        case .background: phase = "Фон"; engine.note("Уход в фон; доступность не гарантирована")
        case .inactive: phase = "Неактивен"
        @unknown default: break
        }
    }
}

#if DEBUG
/// Isolated simulator data. Never opens the installation Keychain or a user's history.
private final class UXClock { var time = Date().addingTimeInterval(-600) }
enum UXFixture {
    static func make() throws -> MeshEngine {
        let clock = UXClock()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearChat-UX-" + UUID().uuidString)
        let identity = try MeshIdentity(name: "Александр")
        let store = try MeshStore(directory: root, identity: identity)
        let owner = try MeshEngine(identity: identity, store: store, clock: { clock.time })
        func peer(_ name: String, folder: String) throws -> MeshEngine {
            let identity = try MeshIdentity(name: name)
            let store = try MeshStore(directory: root.appendingPathComponent(folder), identity: identity)
            return try MeshEngine(identity: identity, store: store, clock: { clock.time })
        }
        let old = try peer("Саша", folder: "old")
        let recent = try peer("Саша", folder: "recent")
        let guest = try peer("Анна", folder: "guest")
        let nodes = [owner, old, recent, guest]
        var queue: [(Int, Int, Data)] = []
        for (index, node) in nodes.enumerated() {
            node.onTransmit = { link, data in if let target = Int(link) { queue.append((index, target, data)) } }
        }
        func drain() throws {
            var count = 0
            while !queue.isEmpty {
                count += 1
                guard count < 20000 else { throw CocoaError(.coderInvalidValue) }
                let (from, to, data) = queue.removeFirst()
                nodes[to].receive(data, from: String(from))
            }
        }
        for index in 1..<nodes.count {
            owner.linkOpened(id: String(index), transport: "fixture")
            nodes[index].linkOpened(id: "0", transport: "fixture")
        }
        try drain()
        for peer in [old, recent] {
            try owner.requestContact(to: peer.identity.card.id); try drain()
            guard let request = peer.contact(for: identity.card.id)?.incomingRequestID else { throw CocoaError(.coderInvalidValue) }
            try peer.respondToContact(from: identity.card.id, requestID: request, accept: true); try drain()
        }
        _ = try old.send(text: "Начало истории", to: identity.card.id); try drain()
        guard let oldTemplate = owner.messages.last else { throw CocoaError(.coderInvalidValue) }
        _ = try recent.send(text: "Начало новой переписки", to: identity.card.id); try drain()
        guard let recentTemplate = owner.messages.last else { throw CocoaError(.coderInvalidValue) }
        func historical(_ template: ChatEntry, text: String, outgoing: Bool) throws -> ChatEntry {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as! [String: Any]
            object["id"] = UUID().uuidString; object["text"] = text
            object.removeValue(forKey: "packetDigest"); object.removeValue(forKey: "readAt")
            object["outgoing"] = outgoing
            if outgoing {
                object["sender"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity.card))
                object["recipient"] = template.sender.id; object["recipientName"] = template.sender.name
                object["state"] = DeliveryState.delivered.rawValue
            }
            return try JSONDecoder().decode(ChatEntry.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var history: [ChatEntry] = []
        for index in 1...80 {
            history.append(try historical(oldTemplate,
                text: "История • \(index). Встречаемся у входа, буду через несколько минут.", outgoing: index % 2 != 0))
        }
        for index in 1...205 {
            history.append(try historical(recentTemplate, text: "Новая переписка • \(index)", outgoing: false))
        }
        try store.importLegacy(history)
        let team = try owner.createClosedGroup(name: "Команда")
        _ = try owner.sendToGroup(text: "План на завтра: собираемся в 10:00.", groupID: team)
        let archive = try owner.createClosedGroup(name: "Архив поездки")
        _ = try owner.sendToGroup(text: "Фото не нужны — здесь общаемся текстом.", groupID: archive)
        try owner.leaveClosedGroup(archive)
        try guest.requestContact(to: identity.card.id); try drain()
        let invitation = try guest.createClosedGroup(name: "Встреча друзей")
        _ = try guest.inviteToGroup(invitation, peerID: identity.card.id); try drain()
        for node in nodes { node.endNetworking(); node.onTransmit = nil }
        clock.time = Date()
        return owner
    }
}
#endif
