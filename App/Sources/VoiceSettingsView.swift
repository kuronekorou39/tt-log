import SwiftUI
import TTLogCore

/// 試作用の設定。選手2人の名前と呼び名、音声・効果音の調整。
struct VoiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("player0.name") private var name0 = ""
    @AppStorage("player0.callName") private var callName0 = ""
    @AppStorage("player1.name") private var name1 = ""
    @AppStorage("player1.callName") private var callName1 = ""
    @AppStorage("voice.deadTime") private var deadTime = 1.5
    @AppStorage("voice.silenceMs") private var silenceMs = 600
    @AppStorage("sound.volume") private var volume = 0.3
    @AppStorage("sound.enabled") private var soundEnabled = true

    private var confusable: [(String, String)] {
        VoiceCommandMatcher.confusablePairs(callNames: [callName0, callName1].filter { !$0.isEmpty })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("選手（左＝A、右＝B）") {
                    playerRow(label: "A", name: $name0, callName: $callName0)
                    playerRow(label: "B", name: $name1, callName: $callName1)
                    ForEach(Array(confusable.enumerated()), id: \.offset) { _, pair in
                        Label("「\(pair.0)」と「\(pair.1)」は聞き間違えやすいかもしれません",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("「\(callName0.isEmpty ? "（Aの呼び名）" : callName0)」「\(callName1.isEmpty ? "（Bの呼び名）" : callName1)」「戻して」「次のゲーム」")
                } header: {
                    Text("受け付ける言葉")
                } footer: {
                    Text("言葉だけを単独で言ったときに反応します。会話の中に出てきた名前には反応しません。")
                }
                Section("音声") {
                    Stepper(value: $silenceMs, in: 300...1500, step: 100) {
                        Text("発話の区切り（無音）: \(silenceMs) ミリ秒")
                    }
                    Stepper(value: $deadTime, in: 0.5...4.0, step: 0.5) {
                        Text("同じ操作を受け付けない時間: \(deadTime, specifier: "%.1f") 秒")
                    }
                }
                Section("効果音") {
                    Toggle("効果音を鳴らす", isOn: $soundEnabled)
                    HStack {
                        Text("音量")
                        Slider(value: $volume, in: 0.05...1.0)
                    }
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func playerRow(label: String, name: Binding<String>, callName: Binding<String>) -> some View {
        HStack {
            Text(label).bold().frame(width: 24)
            TextField("表示名", text: name)
            TextField("呼び名（ひらがな）", text: callName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
