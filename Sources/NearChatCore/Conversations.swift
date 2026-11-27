import Foundation

extension ChatEntry {
    public var conversationID: String {
        if let group { return "g:" + group.groupID.uuidString }
        if isPublic { return "*" }
        return outgoing ? recipient : sender.id
    }
    var isUnread: Bool { !outgoing && readAt == nil && packetDigest != nil }
}
public struct ConversationSummary: Identifiable {
    public let id: String
    public var lastMessage: ChatEntry
    public var unreadCount: Int
    public var messageCount: Int
    public var activityOrder: Int64
}
struct ConversationIndex {
    struct Item { let conversation: String; let order: Int64; let unread: Bool }
    var items: [UUID: Item] = [:]
    var members: [String: Set<UUID>] = [:]
    var summaries: [String: ConversationSummary] = [:]
    private var unread: [String: Int] = [:]
    private var dirty: Set<String> = []
    mutating func update(_ id: UUID, entry: ChatEntry?, order: Int64 = 0) {
        if let old = items.removeValue(forKey: id) {
            members[old.conversation]?.remove(id)
            unread[old.conversation, default: 0] -= old.unread ? 1 : 0
            dirty.insert(old.conversation)
        }
        guard let entry else { return }
        let chat = entry.conversationID
        items[id] = Item(conversation: chat, order: order, unread: entry.isUnread)
        members[chat, default: []].insert(id)
        unread[chat, default: 0] += entry.isUnread ? 1 : 0
        dirty.insert(chat)
        if summaries[chat].map({ order >= $0.activityOrder }) ?? true {
            summaries[chat] = ConversationSummary(id: chat, lastMessage: entry,
                unreadCount: unread[chat, default: 0], messageCount: members[chat]?.count ?? 0, activityOrder: order)
        }
    }
    mutating func refresh(load: (UUID) throws -> ChatEntry?) throws {
        for chat in Array(dirty) {
            guard let ids = members[chat], !ids.isEmpty else {
                summaries.removeValue(forKey: chat); members.removeValue(forKey: chat)
                unread.removeValue(forKey: chat); dirty.remove(chat); continue
            }
            guard let latest = ids.max(by: { (items[$0]?.order ?? 0) < (items[$1]?.order ?? 0) }),
                  let info = items[latest] else { throw MeshStorageError.corrupt }
            let entry: ChatEntry
            if let known = summaries[chat], known.lastMessage.id == latest { entry = known.lastMessage }
            else { guard let loaded = try load(latest) else { throw MeshStorageError.corrupt }; entry = loaded }
            summaries[chat] = ConversationSummary(id: chat, lastMessage: entry,
                unreadCount: unread[chat, default: 0], messageCount: ids.count, activityOrder: info.order)
            dirty.remove(chat)
        }
    }
    func ids(in chat: String, limit: Int) -> [UUID] {
        Array((members[chat] ?? []).sorted { (items[$0]?.order ?? 0) < (items[$1]?.order ?? 0) }.suffix(max(0, limit)))
    }
}
extension MeshStore {
    public func conversationSummaries() throws -> [ConversationSummary] {
        if own.historyNeedsReload {
            conversationIndex = ConversationIndex()
            for row in try own.recordInfo() where row.space == "history" {
                guard let entry = try own.decode(ChatEntry.self, space: "history", id: row.id) else { throw MeshStorageError.corrupt }
                conversationIndex.update(entry.id, entry: entry, order: row.order)
            }
        } else {
            for key in own.historyChanges {
                guard let id = UUID(uuidString: key) else { throw MeshStorageError.corrupt }
                let row = try own.row(space: "history", id: key)
                let entry = try row.map { try JSONDecoder().decode(ChatEntry.self, from: $0.data) }
                conversationIndex.update(id, entry: entry, order: row?.order ?? 0)
            }
        }
        try conversationIndex.refresh { try self.entry($0) }
        own.historyChanges.removeAll(); own.historyNeedsReload = false
        return try conversationIndex.summaries.values.sorted { $0.activityOrder > $1.activityOrder }.map {
            var summary = $0; summary.lastMessage = try validatedHistoryEntry(summary.lastMessage); return summary
        }
    }
    public func history(conversationID: String, limit: Int = MeshEngine.historyLimit) throws -> [ChatEntry] {
        _ = try conversationSummaries()
        return try conversationIndex.ids(in: conversationID, limit: limit).map {
            guard let value = try entry($0) else { throw MeshStorageError.corrupt }; return try validatedHistoryEntry(value)
        }
    }
}
