import SwiftUI

/// いま使っているマイクと、効果音がどこから出ているか。設定画面に出す。
struct MicRouteRows: View {
    @ObservedObject var listener: SpeechListener

    var body: some View {
        LabeledContent("使っているマイク", value: listener.inputName.isEmpty ? "—" : listener.inputName)
        Text("DJI Mic などの受信機やヘッドセットをつなぐと、自動でそちらを使います。聞き取り中に抜き差ししても続きます。")
            .font(.caption)
            .foregroundStyle(.secondary)
        if listener.outputIsExternal {
            Label("効果音は「\(listener.outputName)」から出ています", systemImage: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
