import SwiftUI
import NearChatCore

struct LabView: View {
    @ObservedObject var model: LabModel
    private enum Field: Hashable { case nickname, message, historyBudget, relayBudget }
    @FocusState private var focusedField: Field?
    @State private var retryID: UUID?
    @State private var showGroupCreator = false
    @State private var showGroupDetails = false
    @State private var newGroupName = ""
    @State private var newGroupLimit = 32
    @State private var editedGroupLimit = 32
    @State private var confirmGroupExit = false
    @State private var excludedGroupPeer: String?
    @State private var showRequests = false
    @State private var showPeerDetails = false
    @State private var verification: PeerSecurityInfo?
    @State private var showDiagnostics = false
    @State private var search = ""
    @State private var followsLatest = true
    @State private var scrollingByHand = false
    @State private var visibleIDs: Set<UUID> = []
    private var covered: Bool {
        showRequests || showPeerDetails || showGroupCreator || showGroupDetails ||
        model.pendingHistoryCleanup != nil || model.pendingStorageResize != nil || retryID != nil || model.failure != nil
    }
    var body: some View {
        VStack(spacing: 0) {
          NavigationStack {
            Group {
                switch model.tab {
                case 0: network
                case 1: chats
                case 2: diagnostics
                default: storageSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.engine.historyCleanupSuggested {
                    HStack(alignment: .top) {
                        Text("На устройстве мало места. Можно очистить старейшие сообщения.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button("Рассчитать очистку") { focusedField = nil; model.requestHistoryCleanup() }
                            .font(.caption).disabled(model.engine.storageLimits == nil)
                    }.padding(10).background(.regularMaterial)
                    .accessibilityIdentifier("device-space-warning")
                }
                if let warning = model.engine.storageWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(.regularMaterial).accessibilityIdentifier("storage-warning")
                }
            }
            .onChange(of: model.tab) { _, _ in focusedField = nil; model.setVisibleMessages([]) }
            .navigationTitle(model.tab == 1 ? "Чаты" : model.tab == 0 ? "Рядом" : "Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $model.chatIsOpen) {
                chat.id(model.selectedPeer)
                    .navigationTitle(model.currentChatTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                focusedField = nil
                                if let group = model.selectedGroup { editedGroupLimit = group.memberLimit; showGroupDetails = true }
                                else { showPeerDetails = true }
                            } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("О чате")
                        }
                    }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.tab == 1 && !model.chatIsOpen {
                        Menu {
                            Button("Найти собеседника", systemImage: "person.badge.plus") { model.tab = 0 }
                            Button("Создать группу", systemImage: "person.2.badge.plus") {
                                newGroupName = ""; newGroupLimit = 32; showGroupCreator = true
                            }
                        } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Новый чат")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Скрыть клавиатуру") { focusedField = nil }
                }
            }
            .sheet(isPresented: $showRequests) { requests }
            .sheet(isPresented: $showPeerDetails) { peerDetails }
            .sheet(isPresented: $showDiagnostics) {
                NavigationStack { diagnostics.navigationTitle("Диагностика").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showDiagnostics = false } } }
                }
            }
            .onChange(of: covered) { _, value in model.setReadingSuspended(value) }
            .sheet(isPresented: $showGroupCreator) { groupCreator }
            .sheet(isPresented: $showGroupDetails) { groupDetails }
            .sheet(item: $model.pendingHistoryCleanup) { plan in historyCleanupConfirmation(plan) }
            .sheet(item: $model.pendingStorageResize) { plan in
                resizeConfirmation(plan)
            }
            .confirmationDialog("Повторить сообщение?", isPresented: Binding(
                get: { retryID != nil }, set: { if !$0 { retryID = nil } }), titleVisibility: .visible) {
                Button("Повтор") { if let id = retryID { model.retry(id) }; retryID = nil }
                Button("Отмена", role: .cancel) { retryID = nil }
            } message: {
                Text("Будет отправлено новое сообщение. Если первое всё же дошло, собеседник увидит оба.")
            }
            .alert("NearChat", isPresented: Binding(get: { model.failure != nil && !showGroupCreator && !showGroupDetails && !showRequests && !showPeerDetails && model.pendingHistoryCleanup == nil }, set: { if !$0 { model.failure = nil } })) {
                Button("Понятно") { model.failure = nil }
            } message: { Text(model.failure ?? "") }
          }
          navigationBar
        }
    }
    private var navigationBar: some View {
        HStack(spacing: 6) {
            navigationButton("Чаты", symbol: "bubble.left.and.bubble.right", index: 1)
            navigationButton("Рядом", symbol: "point.3.connected.trianglepath.dotted", index: 0)
            navigationButton("Настройки", symbol: "gearshape", index: 3)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
    private func navigationButton(_ title: String, symbol: String, index: Int) -> some View {
        let unread = index == 1 ? model.engine.unreadCount : 0
        return Button {
            focusedField = nil
            model.tab = index
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .foregroundStyle(.white).padding(.horizontal, 4)
                                .frame(minWidth: 17, minHeight: 17).background(.red, in: Capsule())
                                .offset(x: 12, y: -7).accessibilityHidden(true)
                        }
                    }
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .foregroundStyle(model.tab == index ? Color.teal : Color.secondary)
            .background(model.tab == index ? Color.teal.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(index)")
        .accessibilityLabel(title)
        .accessibilityValue((model.tab == index ? "Выбрано" : "") +
            (unread > 0 ? (model.tab == index ? ". " : "") + "Непрочитанных: \(unread)" : ""))
    }
    private var connection: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(model.running ? .teal : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.connectionTitle).font(.subheadline.weight(.medium))
                Text(model.running ? "Участников поблизости: \(model.peers.count)" : "Включите связь для обмена сообщениями")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(model.running ? "Выключить" : "Включить") { model.running ? model.stop() : model.start() }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered)
        }.padding(.vertical, 5)
    }
    private var chats: some View {
        List {
            Section { connection }
            let count = model.incomingContacts.count + model.groupRequestCount
            if count > 0 || !model.groupInvitations.isEmpty {
                Section {
                    Button { focusedField = nil; showRequests = true } label: {
                        HStack {
                            Label("Запросы и приглашения", systemImage: "tray")
                            Spacer()
                            if count > 0 { Text("\(count)").font(.caption.bold()).padding(6).background(.teal.opacity(0.15), in: Capsule()) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                let rows = model.chatRows.filter {
                    search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.fingerprint?.localizedCaseInsensitiveContains(search) ?? false)
                }
                ForEach(rows) { row in
                    Button { focusedField = nil; model.openChat(row.id) } label: { chatRow(row) }
                        .buttonStyle(.plain).accessibilityIdentifier("chat-" + row.id)
                }
                if rows.isEmpty { ContentUnavailableView.search(text: search) }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Имя или метка собеседника")
    }
    private func chatRow(_ row: ChatListRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbol).font(.system(size: 21)).foregroundStyle(.teal)
                .frame(width: 46, height: 46).background(.teal.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    if let last = row.summary?.lastMessage { Text(last.date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(row.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .top) {
                    Text(row.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    if row.unread > 0 {
                        Text(row.unread > 99 ? "99+" : "\(row.unread)").font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.teal, in: Capsule())
                            .accessibilityLabel("Непрочитанных: \(row.unread)")
                    } else if let last = row.summary?.lastMessage, last.outgoing {
                        if last.state == .delivered || last.state == .read {
                            Text(last.state.title).font(.caption2).foregroundStyle(.secondary)
                        } else if last.state != .local {
                            Image(systemName: last.state == .failed ? "exclamationmark.circle" : "clock")
                                .font(.caption2).foregroundStyle(last.state == .failed ? .orange : .secondary)
                                .accessibilityLabel(last.state.title)
                        }
                    }
                }
            }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
    private var network: some View {
        List {
            Section { connection }
            Section {
                if model.peers.isEmpty {
                    ContentUnavailableView(model.running ? "Пока никого рядом" : "Связь выключена",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text(model.running ? "Откройте NearChat на другом устройстве и включите связь." : "Включите связь на обоих устройствах."))
                        .listRowBackground(Color.clear)
                }
                ForEach(model.peers) { peer in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(peer.card.name).font(.headline)
                            Text("Метка " + peer.card.fingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text(peer.hops == 1 ? "Рядом" : "Доступен через участников").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Написать") { model.openChat(peer.id) }.buttonStyle(.bordered)
                    }.padding(.vertical, 5)
                }
            } header: { Text("Участники · \(model.peers.count)") }
            let unknown = model.engine.nearbyClosedGroupIDs.filter { id in !model.groups.contains { $0.id == id } }
            if !unknown.isEmpty {
                Section("Закрытые группы поблизости") {
                    ForEach(unknown, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Закрытая группа", systemImage: "lock.bubble")
                            Text(id.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
    private var requests: some View {
        NavigationStack {
            List {
                if model.incomingContacts.isEmpty && model.groupInvitations.isEmpty {
                    ContentUnavailableView("Новых запросов нет", systemImage: "tray")
                }
                if !model.incomingContacts.isEmpty {
                    Section("Запросы на общение") {
                        ForEach(model.incomingContacts) { contact in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(contact.peer.name).font(.headline)
                                Text(contact.peer.fingerprint).font(.caption.monospaced())
                                HStack {
                                    Button("Принять") { if model.decideContact(contact, accept: true) { showRequests = false; model.openChat(contact.id) } }.buttonStyle(.borderedProminent)
                                    Button("Отклонить") { model.decideContact(contact, accept: false) }.buttonStyle(.bordered)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if !model.groupInvitations.isEmpty {
                    Section("Приглашения в группы") {
                        ForEach(model.groupInvitations) { flow in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(flow.invitation.body.name).font(.headline)
                                Text("От: " + flow.invitation.body.inviter.peer.name).font(.caption)
                                Text(flow.invitation.body.inviter.peer.fingerprint).font(.caption2.monospaced())
                                Text(flow.status).font(.caption).foregroundStyle(.secondary)
                                if flow.phase == .offered {
                                    HStack {
                                        Button("Принять") { model.acceptGroup(flow) }.buttonStyle(.borderedProminent)
                                        Button("Отклонить") { model.declineGroup(flow) }.buttonStyle(.bordered)
                                    }
                                }
                                if [.waiting, .unconfirmed, .cancelPending].contains(flow.phase) {
                                    Button(flow.phase == .cancelPending ? "Повторить отмену" : "Отменить вступление", role: .destructive) { model.cancelGroup(flow) }.buttonStyle(.bordered)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
            }.navigationTitle("Запросы").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showRequests = false } } }
        }
    }
    private var peerDetails: some View {
        NavigationStack {
            Form {
                if model.selectedPeer == "*" {
                    Section("Общий чат") { Text("Сообщения получают все доступные участники. История хранится на вашем устройстве.") }
                } else if let contact = model.engine.contact(for: model.selectedPeer) {
                    Section(contact.peer.name) { contactControls(contact) }
                    if let info = model.engine.securityInfo(for: model.selectedPeer) {
                        Section("Безопасность") { securityControls(info) }
                    }
                }
                if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
            }.navigationTitle("О чате").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showPeerDetails = false } } }
                .sheet(item: $verification) { keyVerification($0) }
        }
    }
    private var chat: some View {
        VStack(spacing: 0) {
            if model.selectedPeer != "*", model.selectedGroup == nil,
               let info = model.engine.securityInfo(for: model.selectedPeer) {
                HStack(spacing: 8) {
                    Image(systemName: info.status == .verified ? "checkmark.shield.fill" : "exclamationmark.shield")
                    Text(info.status == .changed ? "Ключ изменился · нужна повторная проверка" :
                        info.status == .verified ? "Ключи проверены" : "Ключи не проверены лично")
                    Spacer(minLength: 4)
                    Button("Проверить") { focusedField = nil; showPeerDetails = true }
                }.font(.caption).foregroundStyle(info.status == .changed ? Color.orange : Color.secondary).padding(8)
            }
            if let group = model.selectedGroup, !group.canSend(as: model.engine.identity.card.id) {
                Text(group.isClosed ? "Группа завершена · история только для чтения" : "Вы больше не участвуете · история только для чтения")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            } else if model.selectedPeer != "*", model.selectedGroup == nil,
                      let contact = model.engine.contact(for: model.selectedPeer), contact.phase != .accepted {
                VStack(alignment: .leading, spacing: 5) {
                    Text(contact.status).font(.caption)
                    if contact.incomingRequestID != nil {
                        HStack {
                            Button("Принять") { model.decideContact(contact, accept: true) }
                            Button("Отклонить") { model.decideContact(contact, accept: false) }
                        }
                    } else if contact.canRequest || contact.phase == .outgoing {
                        Button(contact.phase == .outgoing ? "Повторить запрос" : "Запросить общение") { model.requestContact() }.disabled(!model.running)
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.teal.opacity(0.06))
            }
            if !model.running {
                HStack {
                    Text("Связь выключена").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Включить") { model.start() }.font(.caption.weight(.semibold))
                }.padding(.horizontal).padding(.vertical, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if model.currentChatMessageCount > model.visibleMessages.count {
                            Button("Загрузить предыдущие") { model.engine.loadEarlierMessages() }
                                .font(.caption).padding(8)
                        }
                        if model.visibleMessages.isEmpty {
                            ContentUnavailableView("Сообщений пока нет", systemImage: "bubble.left",
                                description: Text("Здесь появится ваша переписка."))
                        }
                        ForEach(model.visibleMessages) { entry in messageBubble(entry).id(entry.id) }
                        Color.clear.frame(height: 1).id("chat-bottom").accessibilityHidden(true)
                    }.scrollTargetLayout().padding(12)
                }
                .accessibilityIdentifier("chat-history")
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { ids in
                    visibleIDs = Set(ids)
                    model.setVisibleMessages(visibleIDs)
                    if scrollingByHand { followsLatest = model.visibleMessages.last.map { visibleIDs.contains($0.id) } ?? true }
                }
                .onScrollPhaseChange { _, phase in
                    scrollingByHand = phase == .tracking || phase == .interacting || phase == .decelerating
                    if scrollingByHand { followsLatest = model.visibleMessages.last.map { visibleIDs.contains($0.id) } ?? true }
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, _ in
                    if followsLatest { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .task(id: model.selectedPeer) {
                    followsLatest = true
                    await Task.yield()
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
                .onChange(of: model.visibleMessages.last?.id) { _, _ in
                    if followsLatest || model.visibleMessages.last?.outgoing == true {
                        followsLatest = true
                        withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        Button {
                            followsLatest = true
                            withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        } label: { Label("К последнему", systemImage: "arrow.down") }
                            .font(.caption.weight(.semibold)).buttonStyle(.borderedProminent).padding(12)
                            .accessibilityIdentifier("latest-message")
                    }
                }
                .onDisappear { model.setVisibleMessages([]) }
                .scrollDismissesKeyboard(.interactively)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField(model.selectedGroup?.canSend(as: model.engine.identity.card.id) == false ? "История только для чтения" : "Сообщение", text: $model.draft, axis: .vertical).lineLimit(1...4)
                    .disabled(model.selectedGroup?.canSend(as: model.engine.identity.card.id) == false)
                    .focused($focusedField, equals: .message).accessibilityIdentifier("message-input")
                    .padding(10).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button { followsLatest = true; model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }.disabled(!model.canSend).accessibilityLabel("Отправить сообщение")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if model.draft.count >= 900 || model.draft.utf8.count > 3600 {
                Text("\(model.draft.count)/1000 символов · \(model.draft.utf8.count)/4096 байт")
                    .font(.caption2).foregroundStyle(model.draft.count > 1000 || model.draft.utf8.count > 4096 ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 5)
            }
        }
    }
    private func messageBubble(_ entry: ChatEntry) -> some View {
        HStack(alignment: .bottom, spacing: 36) {
            if entry.outgoing { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 5) {
                if !entry.outgoing && (entry.isPublic || entry.group != nil) {
                    Text(entry.sender.name + " · " + String(entry.sender.fingerprint.prefix(6))).font(.caption.weight(.semibold)).foregroundStyle(.teal)
                }
                Text(entry.text).textSelection(.enabled).frame(minWidth: 30, alignment: .leading)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(entry.date, format: .dateTime.hour().minute())
                    if entry.outgoing { Text(entry.state.title).foregroundStyle(entry.state == .failed ? .orange : .secondary) }
                }.font(.caption2).foregroundStyle(.secondary)
                if entry.isSaved == false { Label("Пока не сохранено", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
                if entry.outgoing && entry.state == .failed {
                    Button("Повтор") { retryID = entry.id }.font(.caption).disabled(!model.running || model.engine.memoryBufferFull)
                }
            }.padding(11).background(entry.outgoing ? Color.teal.opacity(0.13) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 17))
            if !entry.outgoing { Spacer(minLength: 0) }
        }.accessibilityElement(children: .contain)
    }
    private var groupCreator: some View {
        NavigationStack {
            Form {
                Section("Новая закрытая группа") {
                    TextField("Название", text: $newGroupName)
                    if newGroupName.count > 64 || newGroupName.utf8.count > 256 {
                        Text("Слишком длинное название — сократите его.").font(.caption).foregroundStyle(.red)
                    }
                    Stepper("Лимит участников: \(newGroupLimit)", value: $newGroupLimit, in: 1...32)
                    Text("Создатель входит в лимит. Название видят участники и приглашённые.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Создать") {
                    if model.createGroup(name: newGroupName, limit: newGroupLimit) { showGroupCreator = false }
                }.disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    newGroupName.count > 64 || newGroupName.utf8.count > 256 || model.engine.storageLimits == nil)
                if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
            }
            .navigationTitle("Создать группу").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { showGroupCreator = false } } }
        }
    }
    private var groupDetails: some View {
        NavigationStack {
            Form {
                if let group = model.selectedGroup {
                    let creator = group.creator.id == model.engine.identity.card.id
                    let active = group.canSend(as: model.engine.identity.card.id)
                    Section(group.name) {
                        Text(group.id.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
                        LabeledContent("Создатель", value: group.creator.name)
                        Text(group.creator.fingerprint).font(.caption.monospaced())
                        if !active { Text("История доступна только для чтения").foregroundStyle(.secondary) }
                    }
                    Section("Участники · \(group.members.count)/\(group.memberLimit)") {
                        ForEach(group.members) { member in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(member.peer.name + (member.id == group.creator.id ? " · создатель" : ""))
                                    Text(member.peer.fingerprint).font(.caption2.monospaced())
                                }
                                Spacer()
                                if member.id != model.engine.identity.card.id,
                                   let info = model.engine.securityInfo(for: member.id) {
                                    Button { verification = info } label: {
                                        Image(systemName: info.status == .verified ? "checkmark.shield" : "shield")
                                    }.accessibilityLabel("Проверить ключи: " + member.peer.name)
                                }
                                if creator && active && member.id != group.creator.id {
                                    Button("Исключить", role: .destructive) { excludedGroupPeer = member.id }.font(.caption)
                                }
                            }
                        }
                    }
                    if active {
                        Section("Пригласить") {
                            let candidates = model.engine.knownParticipants.filter { $0.id != model.engine.identity.card.id && group.member($0.id) == nil }
                            ForEach(candidates, id: \.id) { peer in
                                Button { model.inviteGroup(group, peer: peer) } label: {
                                    VStack(alignment: .leading) {
                                        Text(peer.name)
                                        Text(peer.fingerprint).font(.caption2.monospaced())
                                    }
                                }
                            }
                            if candidates.isEmpty { Text("Нет известных участников для приглашения").foregroundStyle(.secondary) }
                            Text("Согласие приглашённого обязательно. Новое вступление подтверждается приложением создателя при доступной связи.").font(.caption).foregroundStyle(.secondary)
                        }
                        if creator {
                            Section("Лимит участников") {
                                Stepper("Не более \(editedGroupLimit)", value: $editedGroupLimit, in: max(1, group.members.count)...32)
                                Button("Применить лимит") { model.changeGroupLimit(group, limit: editedGroupLimit) }
                            }
                            let excluded = model.engine.groupReturnCandidates(group.id)
                            if !excluded.isEmpty {
                                Section("Возвращение исключённых") {
                                    ForEach(excluded, id: \.id) { peer in
                                        Button("Разрешить возвращение: " + peer.name) { model.allowGroupReturn(group, peer: peer) }
                                    }
                                    Text("После разрешения отправьте новое приглашение.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Button(creator ? "Завершить группу" : "Выйти из группы", role: .destructive) { confirmGroupExit = true }
                        }
                    }
                    if let failure = model.failure { Section { Text(failure).foregroundStyle(.orange) } }
                }
            }
            .navigationTitle("Группа").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showGroupDetails = false } } }
            .sheet(item: $verification) { keyVerification($0) }
            .confirmationDialog("Прекратить участие?", isPresented: $confirmGroupExit, titleVisibility: .visible) {
                Button("Подтвердить", role: .destructive) { if let group = model.selectedGroup { model.leaveGroup(group) }; showGroupDetails = false }
                Button("Отмена", role: .cancel) {}
            } message: { Text("История сохранится для чтения. Выход создателя завершит группу для всех после получения события.") }
            .confirmationDialog("Исключить участника?", isPresented: Binding(get: { excludedGroupPeer != nil }, set: { if !$0 { excludedGroupPeer = nil } }), titleVisibility: .visible) {
                Button("Исключить", role: .destructive) {
                    if let peer = excludedGroupPeer, let group = model.selectedGroup { model.excludeGroup(group, peerID: peer) }
                    excludedGroupPeer = nil
                }
                Button("Отмена", role: .cancel) { excludedGroupPeer = nil }
            } message: { Text("Для возвращения потребуется ваше разрешение и новое приглашение.") }
        }
    }
    private func securityControls(_ info: PeerSecurityInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(info.status == .verified ? "Ключи проверены лично" : info.status == .changed ? "Ключ изменился" : "Ключи не проверены лично",
                systemImage: info.status == .verified ? "checkmark.shield" : "exclamationmark.shield")
                .foregroundStyle(info.status == .changed ? Color.orange : Color.primary)
            Text("Имя и согласие на переписку не подтверждают личность. Сверьте код на экранах обоих устройств или по заранее доверенному каналу.")
                .font(.caption).foregroundStyle(.secondary)
            Button(info.status == .verified ? "Сверить код ещё раз" : "Проверить ключи") { verification = info }
                .accessibilityIdentifier("verify-peer-keys")
            if model.engine.peers[info.peer.id]?.supportsForwardSecrecy == false {
                Text("Для защищённого общения обновите NearChat на устройстве собеседника.").font(.caption).foregroundStyle(.orange)
            } else {
                Text(model.engine.channelReady(to: info.peer.id) ? "Защищённый сеанс готов" : "Ожидание защищённого сеанса")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func keyVerification(_ snapshot: PeerSecurityInfo) -> some View {
        let current = model.engine.securityInfo(for: snapshot.peer.id)
        let changed = current?.fingerprint != snapshot.fingerprint
        let groups = stride(from: 0, to: snapshot.safetyCode.count, by: 4).map { offset in
            let first = snapshot.safetyCode.index(snapshot.safetyCode.startIndex, offsetBy: offset)
            let last = snapshot.safetyCode.index(first, offsetBy: 4)
            return String(snapshot.safetyCode[first..<last])
        }
        return NavigationStack {
            Form {
                Section("Сверьте код с «\(snapshot.peer.name)»") {
                    Text("Оба участника открывают «О чате → Проверить ключи». Коды должны полностью совпасть. Сверяйте их лично или по каналу, которому уже доверяете.")
                    Text(groups.joined(separator: " ")).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("peer-safety-code")
                    if changed {
                        Text("Ключ изменился, пока был открыт экран. Закройте его и начните сверку заново.").foregroundStyle(.orange)
                    }
                    Button("Коды совпадают — отметить проверенным") {
                        if model.verifyPeer(snapshot) { verification = nil }
                    }.disabled(changed).accessibilityIdentifier("confirm-peer-verification")
                    Text("Подтверждение сохраняется только на вашем устройстве и относится к этим ключам.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Полные отпечатки ключей") {
                    Text("Ваш: " + model.engine.identity.card.keyFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Собеседника: " + snapshot.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
            }.navigationTitle("Проверка ключей").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { verification = nil } } }
        }
    }
    private func contactControls(_ contact: DirectContact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(contact.peer.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
            Text(contact.status).font(.caption).foregroundStyle(.secondary)
            if !contact.supportsContacts && contact.phase != .blocked {
                Text("Для личного общения обновите NearChat на устройстве собеседника.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if contact.incomingRequestID != nil {
                    Button("Принять") { model.decideContact(contact, accept: true) }
                    Button("Отклонить") { model.decideContact(contact, accept: false) }
                } else if contact.canRequest {
                    Button("Запросить общение") { model.requestContact() }.disabled(!model.running)
                } else if contact.phase == .outgoing {
                    Button("Повторить передачу запроса") { model.requestContact() }.disabled(!model.running)
                }
                Spacer(minLength: 0)
                Button(contact.phase == .blocked ? "Разблокировать" : "Заблокировать") { model.blockContact(contact) }
            }.font(.caption).buttonStyle(.bordered)
        }.padding(.horizontal).padding(.vertical, 8)
    }
    private func storageAmount(_ bytes: Int64, limit: Int64?) -> String {
        let used = String(format: "%.2f", Double(bytes) / 1_000_000)
        return "\(used) / \((limit ?? 0) / 1_000_000) МБ"
    }
    private var storageSettings: some View {
        Form {
            Section("Профиль") {
                HStack {
                    TextField("Ваше имя", text: $model.name).textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .nickname).onSubmit { model.applyName(); focusedField = nil }
                    Button("Сохранить") { model.applyName(); focusedField = nil }
                }
                LabeledContent("Метка", value: model.engine.identity.card.fingerprint)
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("Имя и ключи сохраняются на этом устройстве. Сверьте метки лично, чтобы убедиться, с кем общаетесь.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Связь") {
                connection
                Toggle("Общая Wi-Fi-сеть", isOn: Binding(get: { model.useLAN }, set: model.setLAN))
                Toggle("Bluetooth LE", isOn: Binding(get: { model.useBLE }, set: model.setBLE))
                Button("Диагностика") { focusedField = nil; showDiagnostics = true }
            }
            if let free = model.engine.deviceFreeBytes {
                Section("Место на устройстве") {
                    LabeledContent("Доступно примерно", value: String(format: "%.1f МБ", Double(free) / 1_000_000))
                    if model.engine.historyCleanupSuggested {
                        Button("Рассчитать очистку старой истории") { focusedField = nil; model.requestHistoryCleanup() }
                            .disabled(model.engine.storageLimits == nil)
                    }
                }
            }
            Section {
                LabeledContent("Лимит, МБ") {
                    TextField("100", text: $model.historyBudgetMB).keyboardType(.numberPad)
                        .focused($focusedField, equals: .historyBudget)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 140)
                        .accessibilityIdentifier("history-budget-mb")
                }
                if let usage = model.engine.storageUsage {
                    LabeledContent("Занято", value: storageAmount(usage.historyFiles, limit: model.engine.storageLimits?.historyBytes))
                }
                Button("Применить лимит истории") {
                    focusedField = nil; model.requestStorageResize(.history)
                }.disabled(model.engine.storageLimits == nil)
            } header: { Text("История переписки") } footer: {
                Text("Общий лимит всех чатов, от 1 МБ. Новые записи вытесняют старейшие. При уменьшении с удалением сначала появится расчёт очистки.")
            }
            Section {
                LabeledContent("Лимит, МБ") {
                    TextField("5", text: $model.relayBudgetMB).keyboardType(.numberPad)
                        .focused($focusedField, equals: .relayBudget)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 140)
                        .accessibilityIdentifier("relay-budget-mb")
                }
                if let usage = model.engine.storageUsage {
                    LabeledContent("Занято", value: storageAmount(usage.relayFiles, limit: model.engine.storageLimits?.relayBytes))
                }
                Button("Применить лимит ретрансляции") {
                    focusedField = nil; model.requestStorageResize(.relay)
                }.disabled(model.engine.storageLimits == nil)
            } header: { Text("Буфер ретрансляции") } footer: {
                Text("От 5 МБ. Хранит чужие зашифрованные сообщения и квитанции. Уменьшение с очисткой может прервать их доставку.")
            }
            if let note = model.storageNote { Section { Text(note).font(.callout) } }
            Section {
                Text("Лимиты включают служебные данные и место для записи. Доступный объём текста будет меньше выбранного лимита.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.engine.storageLimits == nil {
                    Text("Настройки станут доступны после восстановления хранилища.").foregroundStyle(.orange)
                }
            }
        }
    }
    private func historyCleanupConfirmation(_ plan: HistoryCleanupPlan) -> some View {
        NavigationStack {
            Form {
                if let result = model.historyCleanupResult {
                    Section("Очистка завершена") {
                        LabeledContent("Удалено сообщений", value: "\(result.removedMessages)")
                        LabeledContent("Прекращено задач", value: "\(result.canceledTasks)")
                        LabeledContent("Освобождено в файле", value: String(format: "%.2f МБ", Double(result.freedFileBytes) / 1_000_000))
                        Text("Лимит истории сохранён. Остаток доступного места на устройстве обновится автоматически.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Нехватка места на устройстве") {
                        if let available = plan.availableDeviceBytes {
                            LabeledContent("Доступно примерно", value: String(format: "%.2f МБ", Double(available) / 1_000_000))
                        }
                        LabeledContent("Старейших сообщений", value: "\(plan.removedMessages)")
                        LabeledContent("Задач будет прекращено", value: "\(plan.canceledTasks)")
                        Text("Выбрана небольшая порция старейшей истории из всех чатов. Фактически освобождённый объём будет показан после очистки.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("Будут удалены только указанные старейшие сообщения и их локальные задачи отправки. Копии на других устройствах не отзываются. Группы, блокировки и выбранный лимит хранилища сохранятся.")
                        Text("Без подтверждения эта очистка не выполняется.")
                    }
                    if let failure = model.cleanupFailure { Section { Text(failure).foregroundStyle(.orange) } }
                    Section {
                        Button("Подтвердить очистку", role: .destructive) { model.confirmHistoryCleanup() }
                            .accessibilityIdentifier("confirm-history-cleanup")
                    }
                }
            }
            .navigationTitle("Освободить место").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(model.historyCleanupResult == nil ? "Отмена" : "Готово") { model.closeHistoryCleanup() }
            } }
        }
    }
    private func resizeConfirmation(_ plan: StorageResizePlan) -> some View {
        NavigationStack {
            Form {
                Section(plan.area.title) {
                    LabeledContent("Прежний лимит", value: "\(plan.previousLimit / 1_000_000) МБ")
                    LabeledContent("Новый лимит", value: "\(plan.newLimit / 1_000_000) МБ")
                    LabeledContent("Освободится", value: String(format: "%.2f МБ", Double(plan.bytesToFree) / 1_000_000))
                    if plan.area == .history { LabeledContent("Сообщений к удалению", value: "\(plan.removedMessages)") }
                    LabeledContent("Задач будет отменено", value: "\(plan.canceledTasks)")
                }
                Section {
                    Text(plan.area == .history ?
                        "Будут удалены старейшие записи всех чатов и связанные исходящие задачи. Копии на других устройствах этим не отзываются." :
                        "Старейшие хранимые конверты будут удалены. Доставка чужих сообщений может прерваться. Приложение по возможности уведомит отправителей.")
                    Text("Отмена сохранит прежний лимит и данные.")
                }
                if let note = model.storageNote { Section { Text(note).foregroundStyle(.orange) } }
                Section { Button("Уменьшить и очистить", role: .destructive) { model.confirmStorageResize() } }
            }
            .navigationTitle("Подтвердить очистку").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { model.cancelStorageResize() } }
            }
        }
        .interactiveDismissDisabled()
    }
    private var diagnostics: some View {
        List {
            Section("Хранилище") {
                if let usage = model.engine.storageUsage {
                    LabeledContent("История и исходящие", value: storageAmount(usage.historyFiles, limit: model.engine.storageLimits?.historyBytes))
                    LabeledContent("Ретрансляция и квитанции", value: storageAmount(usage.relayFiles, limit: model.engine.storageLimits?.relayBytes))
                    LabeledContent("Исходящих задач", value: "\(usage.outgoingTasks)")
                    LabeledContent("Задач ретрансляции", value: "\(usage.relayTasks)")
                } else { Text("Постоянное хранилище недоступно").foregroundStyle(.orange) }
                if let warning = model.engine.relayWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            }
            Section("Счётчики текущего процесса") {
                LabeledContent("Связей транспорта", value: "\(model.engine.links.count)")
                LabeledContent("Входящих пакетов", value: "\(model.engine.counters.received)")
                LabeledContent("Ретрансляций", value: "\(model.engine.counters.forwarded)")
                LabeledContent("Дубликатов", value: "\(model.engine.counters.duplicates)")
                LabeledContent("Отклонено", value: "\(model.engine.counters.rejected)")
                Button("Отправить объявление сейчас") { model.engine.announce() }.disabled(!model.running)
            }
            Section {
                ForEach(model.directPeerIDs, id: \.self) { id in
                    Toggle("Прямой путь: \(model.peerName(id))", isOn: Binding(
                        get: { !model.engine.excludedDirectPeers.contains(id) },
                        set: { model.engine.excludeDirectPeer(id, excluded: !$0) }))
                }
                if model.directPeerIDs.isEmpty { Text("Прямых соседей нет").foregroundStyle(.secondary) }
            } header: { Text("Исключение путей для теста А—Б—В") } footer: {
                Text("Отключите путь А↔В на обоих устройствах. Это фильтр пакетов приложения, а не отключение физического радиоканала.")
            }
            Section("Связи") {
                ForEach(model.engine.links.values.sorted(by: { $0.id < $1.id })) { link in
                    VStack(alignment: .leading) {
                        Text(link.transport)
                        Text(link.peerID.map(model.peerName) ?? "Ожидание объявления")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("События · без текста сообщений") {
                ForEach(Array(model.engine.events.enumerated().reversed()), id: \.offset) { event in
                    Text(event.element).font(.caption.monospaced())
                }
            }
        }
    }
}
