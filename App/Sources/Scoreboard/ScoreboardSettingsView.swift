import Speech
import SwiftUI
import TTLogCore

struct ScoreboardSettingsView: View {
    @ObservedObject var listener: SpeechListener
    let onChangeRole: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ScoreboardTheme.storageKey) private var themeRaw = ScoreboardTheme.simple.rawValue
    @AppStorage("sound.enabled") private var soundEnabled = true
    @AppStorage("sound.volume") private var volume = 0.3
    @AppStorage("voice.leftWord") private var leftWord = "ひだり"
    @AppStorage("voice.rightWord") private var rightWord = "みぎ"
    @AppStorage("voice.deadTime") private var deadTime = 1.5
    @AppStorage("voice.silenceMs") private var silenceMs = 600
    @AppStorage("voice.recordsAudio") private var recordsAudio = true
    @AppStorage("voice.taskHint") private var taskHint = SFSpeechRecognitionTaskHint.confirmation.rawValue
    @AppStorage(MicMode.storageKey) private var micMode = MicMode.standard.rawValue

    @State private var exportURL: URL?
    @State private var exportError: String?

    private var confusable: [(String, String)] {
        VoiceCommandMatcher.confusablePairs(callNames: [leftWord, rightWord].filter { !$0.isEmpty })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ScoreboardDesignPicker()
                    } label: {
                        HStack {
                            Label("デザイン", systemImage: "paintpalette")
                            Spacer()
                            Text((ScoreboardTheme(rawValue: themeRaw) ?? .simple).title)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("スコア表示")
                } footer: {
                    Text("この端末の表示にだけ反映されます。試合中も切り替えられます。")
                }
                Section {
                    HStack {
                        Text("画面の左")
                        TextField("ひらがな", text: $leftWord)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Text("画面の右")
                        TextField("ひらがな", text: $rightWord)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    ForEach(Array(confusable.enumerated()), id: \.offset) { _, pair in
                        Label("「\(pair.0)」と「\(pair.1)」は聞き間違えやすいかもしれません",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach([leftWord, rightWord].compactMap { ScoreOverlapNote.text(callName: $0) }, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("声での操作")
                } footer: {
                    Text("選手の呼び名でも点が入ります（「〇〇ポイント」「〇〇1点」なども可）。ほかに「戻して」「取り消し」（取り消し）と「次のゲーム」を受け付けます。言葉だけを単独で言ったときに反応します。")
                }
                Section("聞き取りの調整") {
                    Picker("マイクの処理", selection: $micMode) {
                        ForEach(MicMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    Text((MicMode(rawValue: micMode) ?? .standard).detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MicRouteRows(listener: listener)
                    Stepper(value: $silenceMs, in: 300...1500, step: 100) {
                        Text("発話の区切り（無音）: \(silenceMs) ミリ秒")
                    }
                    Stepper(value: $deadTime, in: 0.5...4.0, step: 0.5) {
                        Text("同じ操作を受け付けない時間: \(deadTime, specifier: "%.1f") 秒")
                    }
                    Picker("認識のモード", selection: $taskHint) {
                        Text("短い応答向け（confirmation）").tag(SFSpeechRecognitionTaskHint.confirmation.rawValue)
                        Text("検索語向け（search）").tag(SFSpeechRecognitionTaskHint.search.rawValue)
                        Text("口述向け（dictation）").tag(SFSpeechRecognitionTaskHint.dictation.rawValue)
                        Text("指定なし（unspecified）").tag(SFSpeechRecognitionTaskHint.unspecified.rawValue)
                    }
                    Text(listener.supportsOnDevice ? "この端末は端末内（オフライン）認識に対応しています" : "この端末は端末内認識に対応していません")
                        .foregroundStyle(listener.supportsOnDevice ? Color.secondary : Color.orange)
                }
                Section {
                    Toggle("発話ごとの音声を保存する", isOn: $recordsAudio)
                    Button("音声ログを書き出す") {
                        do { exportURL = try listener.store.exportArchive() } catch { exportError = error.localizedDescription }
                    }
                } header: {
                    Text("音声ログ（調整用）")
                } footer: {
                    Text("聞き取った言葉と音声を残します。会話もそのまま入るので、送る先に注意してください。")
                }
                Section("効果音") {
                    Toggle("効果音を鳴らす", isOn: $soundEnabled)
                    HStack {
                        Text("音量")
                        Slider(value: $volume, in: 0.05...1.0)
                    }
                }
                Section {
                    Button("役割を変える") {
                        dismiss()
                        onChangeRole()
                    }
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $exportURL) { url in ActivityView(items: [url]) }
            .alert("書き出せませんでした", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }
}
