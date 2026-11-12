import Foundation
import Network
import TTLogCore
import UIKit

/// カメラ側の接続（WebSocket クライアント）。スコアボードを Bonjour で探してつなぎ、状態を受け取る。
/// 切れたら自動でつなぎ直す。
@MainActor
final class PeerClient: ObservableObject {
    enum Status: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "未接続"
            case .searching: return "スコアボードを探しています"
            case .connecting(let n): return "\(n) に接続中"
            case .connected(let n): return "\(n) と接続中"
            case .failed(let m): return "接続できません（\(m)）"
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .idle
    /// 最後に受け取ったスコアボードの状態。切れても最後のものを残す。
    @Published private(set) var snapshot: ScoreboardSnapshot?
    /// スコアボードの時計 − この端末の時計（ミリ秒）。
    @Published private(set) var clockOffsetMs: Double?

    private(set) var clock = ClockSync()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var manualHost: String?
    private var wantsRunning = false

    private static let pingInterval: TimeInterval = 5

    /// - Parameter manualHost: Bonjour で見つからないときに使う、スコアボードの IP アドレス。空なら自動で探す。
    func start(manualHost: String?) {
        wantsRunning = true
        let host = manualHost?.trimmingCharacters(in: .whitespaces) ?? ""
        self.manualHost = host.isEmpty ? nil : host
        connectOrBrowse()
    }

    func stop() {
        wantsRunning = false
        reconnectTask?.cancel()
        teardown()
        status = .idle
    }

    /// スコアボードの時刻を、この端末の時刻に直す。
    func localDate(fromRemote ms: Double) -> Date {
        Date(epochMilliseconds: clock.toLocal(ms))
    }

    /// 録画の状態をスコアボードに送る。つながっていなければ何もしない。
    func send(_ status: CameraStatus) {
        guard let connection, self.status.isConnected else { return }
        PeerServer.send(.cameraStatus(status), to: connection)
    }

    // MARK: -

    private func connectOrBrowse() {
        teardown()
        if let host = manualHost {
            connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: PeerProtocol.port)!), label: host)
            return
        }
        status = .searching
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: PeerProtocol.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.connection == nil, let result = results.first else { return }
                var label = "スコアボード"
                if case let .service(name, _, _, _) = result.endpoint { label = name }
                self.browser?.cancel()
                self.browser = nil
                self.connect(to: result.endpoint, label: label)
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state {
                    self?.status = .failed(error.localizedDescription)
                    self?.scheduleReconnect()
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func connect(to endpoint: NWEndpoint, label: String) {
        status = .connecting(label)
        let c = NWConnection(to: endpoint, using: PeerServer.parameters())
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.connection === c else { return }
                switch state {
                case .ready:
                    self.status = .connected(label)
                    PeerServer.send(.hello(PeerHello(role: .camera, deviceName: UIDevice.current.name)), to: c)
                    self.startPings()
                case .failed(let error), .waiting(let error):
                    self.status = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                default:
                    break
                }
            }
        }
        connection = c
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === c else { return }
                if let data, let message = try? PeerCodec.decode(data) {
                    self.handle(message)
                }
                if error == nil {
                    self.receive(on: c)
                } else {
                    self.status = .failed(error?.localizedDescription ?? "切断")
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: PeerMessage) {
        switch message {
        case .state(let s):
            snapshot = s
        case .pong(let sentAt, let remoteAt):
            clock.add(sentAt: sentAt, remoteAt: remoteAt, receivedAt: Date().epochMilliseconds)
            clockOffsetMs = clock.offset
        case .hello, .ping, .cameraStatus:
            break
        }
    }

    private func startPings() {
        pingTimer?.invalidate()
        // つないだ直後は何度か測って、ずれをすぐ求める
        Task { [weak self] in
            for _ in 0..<5 {
                self?.ping()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping() }
        }
    }

    private func ping() {
        guard let connection, status.isConnected else { return }
        PeerServer.send(.ping(sentAt: Date().epochMilliseconds), to: connection)
    }

    private func scheduleReconnect() {
        guard wantsRunning else { return }
        teardown()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.wantsRunning else { return }
            self.connectOrBrowse()
        }
    }

    private func teardown() {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
    }
}
