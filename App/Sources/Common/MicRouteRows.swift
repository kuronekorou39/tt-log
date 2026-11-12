import SwiftUI

/// いま使っているマイクと、効果音がどこから出ているか。設定画面に出す。
struct MicRouteRows: View {
    @ObservedObject var listener: SpeechListener

    var body: some View {
        LabeledContent("使っているマイク", value: listener.inputName.isEmpty ? "—" : listener.inputName)
        if listener.outputIsExternal {
            Label("効果音は「\(listener.outputName)」から出ています", systemImage: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
