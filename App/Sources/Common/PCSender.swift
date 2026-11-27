import CryptoKit
import Foundation
import Network
import Security
import SwiftUI
import UIKit

/// PC の受け取り窓口（tools/receiver）へ送るファイルの一式。
struct PCSendJob {
    struct Item {
        let path: String
        let url: URL
        let size: Int64
    }

    let sessionId: String
    /// "camera" か "scoreboard"
    let role: String
    let items: [Item]
    /// カメラがスコアボードと同じ側か。カメラ端末から送るときだけ。
    let cameraSameSide: Bool?

    static func item(_ path: String, _ url: URL) -> Item? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 ? Item(path: path, url: url, size: Int64(size)) : nil
    }

    /// カメラ端末：index.json と、ゲームごとの録画。
    @MainActor
    static func camera(library: CameraLibrary, index: CameraSessionIndex, sameSide: Bool) throws -> PCSendJob {
        let folder = library.folder(of: index)
        guard let head = item("index.json", folder.appendingPathComponent("index.json")) else {
            throw PCSendError.message("記録を読めません")
        }
        let clips = index.clips.filter { $0.gameIndex != nil }.compactMap { item($0.file, library.url(of: $0, in: index)) }
        guard !clips.isEmpty else { throw PCSendError.message("録画がありません") }
        return PCSendJob(sessionId: index.id.uppercased(), role: "camera", items: [head] + clips, cameraSameSide: sameSide)
    }

    /// スコアボード：記録と、その時間帯の声の録音。
    @MainActor
    static func scoreboard(session: SessionRecord) throws -> PCSendJob {
        let id = session.id.uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-send-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 記録の中身（時刻の数値など）を変えないよう、logData はそのままつなぐ
        let head = try JSONSerialization.data(withJSONObject: ["id": id, "playerNames": session.playerNames])
        var json = Data(head.dropLast())
        json.append(Data(",\"log\":".utf8))
        json.append(session.logData)
        json.append(Data("}".utf8))
        let sessionFile = dir.appendingPathComponent("session.json")
        try json.write(to: sessionFile)
        guard let sessionItem = item("session.json", sessionFile) else { throw PCSendError.message("記録を読めません") }

        var items = [sessionItem]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let voice = docs.appendingPathComponent("VoiceLogs", isDirectory: true)
        let log = voice.appendingPathComponent("log.tsv")
        if FileManager.default.fileExists(atPath: log.path) {
            // 送っている間に追記されても大きさが変わらないよう、写しを送る
            let copy = dir.appendingPathComponent("log.tsv")
            try FileManager.default.copyItem(at: log, to: copy)
            if let i = item("voice/log.tsv", copy) { items.append(i) }
            let margin: TimeInterval = 5 * 60
            let from = session.startedAt.addingTimeInterval(-margin)
            let to = (session.endedAt ?? Date()).addingTimeInterval(margin)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let audio = voice.appendingPathComponent("audio", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "wav" {
                guard let at = stamp.date(from: f.deletingPathExtension().lastPathComponent), at >= from, at <= to else { continue }
                if let i = item("voice/audio/\(f.lastPathComponent)", f) { items.append(i) }
            }
        }
        return PCSendJob(sessionId: id, role: "scoreboard", items: items, cameraSameSide: nil)
    }
}

enum PCSendError: LocalizedError {
    case message(String)
    case unpaired

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .unpaired: return "PCとつなぎ直してください"
        }
    }
}

/// PC とつないだときの鍵。端末のキーチェーンに置く。
private enum PCToken {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.rou39.ttlog.pc",
        kSecAttrAccount as String: "token",
    ]

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// 同じ Wi-Fi の PC を Bonjour で探し、IPv4 のアドレスを返す。
@MainActor
private final class PCFinder {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<String, Error>?

    func find(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            let b = NWBrowser(for: .bonjour(type: PCSender.serviceType, domain: nil), using: NWParameters())
            b.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated {
                    guard let self, self.connection == nil, let endpoint = results.first?.endpoint else { return }
                    self.resolve(endpoint)
                }
            }
            b.start(queue: .main)
            browser = b
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(.failure(PCSendError.message("PCが見つかりません"))) }
            }
        }
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint, case let .ipv4(address) = host {
                        let ip = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
                        self.finish(.success("\(ip):\(port.rawValue)"))
                    } else {
                        self.finish(.failure(PCSendError.message("PCが見つかりません")))
                    }
                case .failed:
                    self.finish(.failure(PCSendError.message("PCに接続できません")))
                default:
                    break
                }
            }
        }
        c.start(queue: .main)
        connection = c
    }

    private func finish(_ result: Result<String, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        browser?.cancel()
        connection?.cancel()
        c.resume(with: result)
    }
}

/// 記録を PC へ送る。途中で切れても、もう一度押せば続きから送る。
@MainActor
final class PCSender: ObservableObject {
    enum Phase: Equatable {
        case idle
        case finding
        case sending(Double)
        case waitingOther
        case processing(String)
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .finding, .sending: return true
            default: return false
            }
        }
    }

    static let shared = PCSender()
    nonisolated static let serviceType = "_ttlog-recv._tcp"
    private static let port = 52741
    private static let chunkSize = 8 * 1024 * 1024
    private static let retries = 3
    private static let pollSeconds: UInt64 = 5
    private static let hostKey = "pc.host"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeSession: String?
    @Published private(set) var isPaired = PCToken.load() != nil
    /// 「PCとつなぐ」を出しているか。出す部品が作り直されても閉じないよう、ここで持つ。
    @Published var showsPairing = false
    /// つないだあとに続ける送信。
    var afterPairing: (@MainActor () -> Void)?

    private var task: Task<Void, Never>?
    private var host: String? {
        get { UserDefaults.standard.string(forKey: Self.hostKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hostKey) }
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    func phase(for sessionId: String) -> Phase {
        activeSession == sessionId.uppercased() ? phase : .idle
    }

    func pair(code: String, address: String) async throws {
        let typed = address.trimmingCharacters(in: .whitespaces)
        let target: String
        if typed.isEmpty {
            target = try await PCFinder().find(timeout: 8)
        } else {
            target = typed.contains(":") ? typed : "\(typed):\(Self.port)"
        }
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "device": UIDevice.current.name])
        let (data, status) = try await call("POST", "/v1/pair", host: target, token: nil, body: body)
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw PCSendError.message("コードが違います")
        }
        PCToken.save(token)
        host = target
        isPaired = true
    }

    func send(_ job: PCSendJob) {
        guard !phase.isBusy else { return }
        task?.cancel()
        activeSession = job.sessionId
        phase = .finding
        UIApplication.shared.isIdleTimerDisabled = true  // 送っている間は画面を消さない
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(job)
            } catch is CancellationError {
                self.phase = .idle
            } catch PCSendError.unpaired {
                PCToken.clear()
                self.isPaired = false
                self.phase = .failed(PCSendError.unpaired.localizedDescription)
            } catch {
                self.phase = .failed((error as? PCSendError)?.localizedDescription ?? "PCに接続できません")
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: -

    private func run(_ job: PCSendJob) async throws {
        guard let token = PCToken.load() else { throw PCSendError.unpaired }
        let target = try await reachableHost(token: token)
        let base = "/v1/sessions/\(job.sessionId)/\(job.role)"

        // 記録は直されても大きさが同じことがあるので、中身のハッシュも伝える
        let files: [[String: Any]] = job.items.map { item in
            var entry: [String: Any] = ["path": item.path, "size": item.size]
            if item.path.hasSuffix(".json") || item.path.hasSuffix(".tsv"), let content = try? Data(contentsOf: item.url) {
                entry["sha256"] = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            }
            return entry
        }
        var manifest: [String: Any] = ["files": files]
        if let same = job.cameraSameSide { manifest["cameraSameSide"] = same }
        let (data, status) = try await call("POST", "\(base)/manifest", host: target, token: token,
                                            body: try JSONSerialization.data(withJSONObject: manifest))
        try check(status, data)
        let offsets = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["offsets"] as? [String: Int64] ?? [:]

        let total = max(1, job.items.reduce(Int64(0)) { $0 + $1.size })
        var done = job.items.reduce(Int64(0)) { $0 + (offsets[$1.path] ?? 0) }
        phase = .sending(Double(done) / Double(total))
        for item in job.items {
            let start = offsets[item.path] ?? 0
            guard start < item.size else { continue }
            var last = start
            try await upload(item, from: start, base: base, host: target, token: token) { at in
                done += at - last
                last = at
                self.phase = .sending(Double(done) / Double(total))
            }
        }
        let (finish, code) = try await call("POST", "\(base)/complete", host: target, token: token, body: Data("{}".utf8))
        try check(code, finish)
        UIApplication.shared.isIdleTimerDisabled = false
        try await follow(sessionId: job.sessionId, host: target, token: token)
    }

    private func reachableHost(token: String) async throws -> String {
        if let saved = host, let (_, status) = try? await call("GET", "/v1/ping", host: saved, token: token, timeout: 4) {
            if status == 401 { throw PCSendError.unpaired }
            if status == 200 { return saved }
        }
        let found = try await PCFinder().find(timeout: 8)
        let (_, status) = try await call("GET", "/v1/ping", host: found, token: token, timeout: 4)
        if status == 401 { throw PCSendError.unpaired }
        guard status == 200 else { throw PCSendError.message("PCに接続できません") }
        host = found
        return found
    }

    private func upload(_ item: PCSendJob.Item, from start: Int64, base: String, host: String, token: String,
                        progress: (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: item.url)
        defer { try? handle.close() }
        var at = start
        while at < item.size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(at))
            let chunk = try autoreleasepool { try handle.read(upToCount: Self.chunkSize) } ?? Data()
            guard !chunk.isEmpty else { throw PCSendError.message("ファイルを読めません") }
            let digest = SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined()
            at = try await put(chunk, digest: digest, item: item, offset: at, base: base, host: host, token: token)
            progress(at)
        }
    }

    /// 1かたまり送って、PC に届いたバイト数を返す。通信が切れたら少し待ってやり直す。
    private func put(_ chunk: Data, digest: String, item: PCSendJob.Item, offset: Int64,
                     base: String, host: String, token: String) async throws -> Int64 {
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "path", value: item.path),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "size", value: String(item.size)),
        ]
        for attempt in 0... {
            try Task.checkCancellation()
            do {
                let (data, status) = try await call("PUT", "\(base)/file?\(query.percentEncodedQuery ?? "")", host: host, token: token,
                                                    body: chunk, headers: ["X-SHA256": digest])
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                // 再送で PC のほうが先に進んでいるときは、そこから続ける
                if status == 200 || status == 409, let received = json?["received"] as? Int64 { return received }
                if status == 422, attempt < Self.retries { continue }
                try check(status, data)
                throw PCSendError.message("送信に失敗しました")
            } catch let error as URLError where attempt < Self.retries {
                _ = error
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
            }
        }
        throw PCSendError.message("送信に失敗しました")
    }

    /// 送ったあと、PC の処理が終わるまで様子を見る。
    private func follow(sessionId: String, host: String, token: String) async throws {
        while true {
            try Task.checkCancellation()
            if let (data, status) = try? await call("GET", "/v1/sessions/\(sessionId)/status", host: host, token: token, timeout: 10),
               status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let message = json["message"] as? String ?? ""
                switch json["state"] as? String {
                case "queued", "processing":
                    phase = .processing(message.isEmpty ? "処理待ち" : message)
                case "done":
                    phase = .done
                    return
                case "failed":
                    phase = .failed(message.isEmpty ? "処理に失敗しました" : message)
                    return
                default:
                    phase = .waitingOther
                }
            }
            try await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
        }
    }

    private func check(_ status: Int, _ data: Data) throws {
        if status == 200 { return }
        if status == 401 { throw PCSendError.unpaired }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        throw PCSendError.message(json?["error"] as? String ?? "送信に失敗しました")
    }

    private func call(_ method: String, _ path: String, host: String, token: String?, body: Data? = nil,
                      headers: [String: String] = [:], timeout: TimeInterval = 60) async throws -> (Data, Int) {
        guard let url = URL(string: "http://\(host)\(path)") else { throw PCSendError.message("PCのアドレスが正しくありません") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil, headers.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// 結果の画面に置く「PCへ送る」。
struct PCSendSection: View {
    let sessionId: String
    /// カメラ端末では、送るときにカメラの位置を選ぶ。
    let asksCameraSide: Bool
    let makeJob: @MainActor (_ cameraSameSide: Bool) throws -> PCSendJob

    @ObservedObject private var sender = PCSender.shared
    @AppStorage("pc.cameraSameSide") private var cameraSameSide = false
    @State private var buildError: String?

    var body: some View {
        let phase = sender.phase(for: sessionId)
        Section("PC") {
            if asksCameraSide {
                Picker("カメラ", selection: $cameraSameSide) {
                    Text("向かい側").tag(false)
                    Text("スコアボード側").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(phase.isBusy)
            }
            statusRow(phase)
            if phase.isBusy {
                Button("止める", role: .cancel) { sender.cancel() }
            } else {
                Button {
                    start()
                } label: {
                    Label("PCへ送る", systemImage: "laptopcomputer.and.arrow.down")
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ phase: PCSender.Phase) -> some View {
        if let buildError {
            Text(buildError).foregroundStyle(.red)
        }
        switch phase {
        case .idle:
            EmptyView()
        case .finding:
            HStack { ProgressView(); Text("接続中") }
        case .sending(let p):
            ProgressView(value: p) { Text("送信中 \(Int(p * 100))%").monospacedDigit() }
        case .waitingOther:
            Label("もう1台を待っています", systemImage: "clock")
        case .processing(let m):
            HStack { ProgressView(); Text(m) }
        case .done:
            Label("完了", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @MainActor
    private func start() {
        guard sender.isPaired else {
            sender.afterPairing = { start() }
            sender.showsPairing = true
            return
        }
        do {
            buildError = nil
            sender.send(try makeJob(cameraSameSide))
        } catch {
            buildError = error.localizedDescription
        }
    }
}

extension View {
    /// 「PCへ送る」を置いた画面に付ける。「PCとつなぐ」はここから出す。
    /// List の行（PCSendSection）に付けると、iPhone では行が作り直されたときにすぐ閉じてしまう。
    func pcPairSheet() -> some View { modifier(PCPairSheet()) }
}

private struct PCPairSheet: ViewModifier {
    @ObservedObject private var sender = PCSender.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $sender.showsPairing) {
            PCPairView {
                let next = sender.afterPairing
                sender.afterPairing = nil
                next?()
            }
        }
    }
}

private struct PCPairView: View {
    let onPaired: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var address = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6桁のコード", text: $code)
                        .keyboardType(.numberPad)
                    TextField("PCのアドレス（空で自動）", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("PCとつなぐ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("つなぐ") { pair() }
                            .disabled(code.count != 6)
                    }
                }
            }
        }
    }

    @MainActor
    private func pair() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await PCSender.shared.pair(code: code, address: address)
                dismiss()
                onPaired()
            } catch {
                self.error = (error as? PCSendError)?.localizedDescription ?? "PCに接続できません"
            }
        }
    }
}
