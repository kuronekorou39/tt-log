import SwiftData
import SwiftUI

@main
struct TTLogApp: App {
    /// README のキャプチャ用（起動引数 `-demo <画面>`）。ふだんは nil。
    private let demo: DemoScreen?
    private let demoContainer: ModelContainer?

    init() {
        let demo = DemoScreen.current
        self.demo = demo
        demoContainer = demo.map { Demo.makeContainer($0) }
    }

    var body: some Scene {
        WindowGroup {
            if let demo, let demoContainer {
                DemoView(screen: demo).modelContainer(demoContainer)
            } else {
                RootView()
            }
        }
        .modelContainer(for: [PlayerRecord.self, SessionRecord.self])
    }
}

/// この端末の役割。1つのアプリで、スコアボード（iPad）とカメラ（iPhone）を切り替える。
enum AppRole: String, CaseIterable {
    case scoreboard
    case camera
    case voiceTest

    var title: String {
        switch self {
        case .scoreboard: return "スコアボード"
        case .camera: return "カメラ"
        case .voiceTest: return "音声テスト"
        }
    }

    var detail: String {
        switch self {
        case .scoreboard: return "点数の表示と記録"
        case .camera: return "録画と振り返り"
        case .voiceTest: return "音声認識の聞き取りを試す"
        }
    }

    var systemImage: String {
        switch self {
        case .scoreboard: return "rectangle.split.2x1"
        case .camera: return "video"
        case .voiceTest: return "waveform"
        }
    }
}

struct RootView: View {
    @AppStorage("app.role") private var roleRaw = ""

    var body: some View {
        Group {
            switch AppRole(rawValue: roleRaw) {
            case .scoreboard: ScoreboardView(onChangeRole: { roleRaw = "" })
            case .camera: CameraView(onChangeRole: { roleRaw = "" })
            case .voiceTest:
                NavigationStack {
                    VoiceTestView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("役割を変える") { roleRaw = "" }
                            }
                        }
                }
            case nil: RolePickerView(roleRaw: $roleRaw)
            }
        }
    }
}

struct RolePickerView: View {
    @Binding var roleRaw: String

    var body: some View {
        VStack(spacing: 24) {
            Text("この端末の役割を選んでください")
                .font(.title2.bold())
            HStack(spacing: 20) {
                ForEach(AppRole.allCases, id: \.self) { role in
                    Button {
                        roleRaw = role.rawValue
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: role.systemImage)
                                .font(.system(size: 44))
                            Text(role.title)
                                .font(.title3.bold())
                            Text(role.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .frame(maxWidth: 280, minHeight: 220)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("あとで変えられます")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
