import SwiftData
import SwiftUI
import TTLogCore

/// 新しい記録を始める。登録済みの選手から2人を選ぶ。
struct NewSessionView: View {
    let onStart: ([PlayerRecord], MatchConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<PlayerRecord> { !$0.isHidden }, sort: \PlayerRecord.createdAt)
    private var players: [PlayerRecord]

    @AppStorage("newSession.player0") private var player0Raw = ""
    @AppStorage("newSession.player1") private var player1Raw = ""
    @AppStorage("newSession.bestOf") private var bestOf = 0 // 0 = 1ゲームずつ続ける
    @State private var firstServer = 0
    @State private var firstLeft = 0
    @State private var showPlayers = false

    private var player0: PlayerRecord? { players.first { $0.id.uuidString == player0Raw } }
    private var player1: PlayerRecord? { players.first { $0.id.uuidString == player1Raw } }
    private var canStart: Bool {
        guard let player0, let player1 else { return false }
        return player0.id != player1.id
    }

    var body: some View {
        NavigationStack {
            Form {
                if players.count < 2 {
                    Section {
                        Text("選手を2人以上登録してください。")
                        Button("選手を登録する") { showPlayers = true }
                    }
                }
                Section("選手") {
                    Picker("選手1", selection: $player0Raw) {
                        Text("選んでください").tag("")
                        ForEach(players) { Text($0.name).tag($0.id.uuidString) }
                    }
                    Picker("選手2", selection: $player1Raw) {
                        Text("選んでください").tag("")
                        ForEach(players) { Text($0.name).tag($0.id.uuidString) }
                    }
                    if let player0, let player1, player0.id == player1.id {
                        Text("別の選手を選んでください").foregroundStyle(.orange)
                    }
                }
                Section("形式") {
                    Picker("形式", selection: $bestOf) {
                        Text("1ゲームずつ続ける").tag(0)
                        Text("3ゲームマッチ").tag(3)
                        Text("5ゲームマッチ").tag(5)
                        Text("7ゲームマッチ").tag(7)
                    }
                    .pickerStyle(.segmented)
                }
                Section("第1ゲーム") {
                    Picker("最初のサーブ", selection: $firstServer) {
                        Text(player0?.name ?? "選手1").tag(0)
                        Text(player1?.name ?? "選手2").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Picker("画面の左側", selection: $firstLeft) {
                        Text(player0?.name ?? "選手1").tag(0)
                        Text(player1?.name ?? "選手2").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("新しい記録")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("始める") {
                        guard let player0, let player1 else { return }
                        let format: MatchFormat = bestOf == 0 ? .continuous : .bestOf(bestOf)
                        onStart([player0, player1], MatchConfig(format: format, firstServer: firstServer, firstLeft: firstLeft))
                        dismiss()
                    }
                    .disabled(!canStart)
                }
            }
            .sheet(isPresented: $showPlayers) {
                NavigationStack { PlayersView() }
            }
        }
    }
}

/// 選手の登録・編集。何人でも登録できる。
struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PlayerRecord.createdAt) private var players: [PlayerRecord]
    @Query private var sessions: [SessionRecord]

    @State private var newName = ""
    @State private var newCallName = ""
    @State private var showHidden = false

    var body: some View {
        Form {
            Section("追加") {
                HStack {
                    TextField("表示名", text: $newName)
                    TextField("呼び名（ひらがな・任意）", text: $newCallName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("追加") {
                        context.insert(PlayerRecord(name: newName.trimmingCharacters(in: .whitespaces),
                                                    callName: newCallName.trimmingCharacters(in: .whitespaces)))
                        try? context.save()
                        newName = ""
                        newCallName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                ForEach(players.filter { showHidden || !$0.isHidden }) { p in
                    PlayerRow(player: p)
                        .swipeActions {
                            if hasSessions(p) {
                                Button(p.isHidden ? "表示" : "隠す") {
                                    p.isHidden.toggle()
                                    try? context.save()
                                }
                            } else {
                                Button("削除", role: .destructive) {
                                    context.delete(p)
                                    try? context.save()
                                }
                            }
                        }
                }
                Toggle("隠した選手も表示する", isOn: $showHidden)
            } header: {
                Text("登録済み")
            } footer: {
                Text("記録がある選手は削除できないので「隠す」にします。名前を変えても過去の記録はつながったままです。呼び名は、設定で「選手の呼び名」モードにしたときに使います。")
            }
        }
        .navigationTitle("選手")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { dismiss() }
            }
        }
    }

    private func hasSessions(_ p: PlayerRecord) -> Bool {
        sessions.contains { $0.playerIDs.contains(p.id) }
    }
}

private struct PlayerRow: View {
    @Bindable var player: PlayerRecord
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack {
            TextField("表示名", text: $player.name)
            TextField("呼び名", text: $player.callName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.secondary)
            if player.isHidden {
                Text("隠し中").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onSubmit { try? context.save() }
    }
}

/// これまでの記録。選ぶと結果（スコア推移・得点の一覧・共有）を見られる。
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    @State private var deleting: SessionRecord?

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("まだ記録がありません。").foregroundStyle(.secondary)
            }
            ForEach(sessions) { s in
                NavigationLink {
                    SessionDetailView(session: s)
                } label: {
                    let log = s.log
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.startedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.headline)
                            if s.endedAt == nil {
                                Text("記録中").font(.caption).padding(.horizontal, 6).background(.green.opacity(0.2), in: Capsule())
                            }
                        }
                        Text(log.summary(names: s.playerNames))
                        Text(log.config.format.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if s.endedAt != nil {
                        Button("削除", role: .destructive) { deleting = s }
                    }
                }
            }
        }
        .navigationTitle("履歴")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .confirmationDialog("この記録を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let deleting { context.delete(deleting); try? context.save() }
                deleting = nil
            }
        }
    }
}
