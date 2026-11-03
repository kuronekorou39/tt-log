import Foundation
import Network
import TTLogCore
import UIKit

/// スコアボード側の待ち受け（WebSocket サーバー）。カメラ端末に状態を送る。
/// 形式は docs/protocol.md。
@MainActor
final class PeerServer: ObservableObject {
    @Published private(set) var statusMessage = "停止中"
    /// つながっているカメラ端末の名前。
    @Published private(set) var cameraNames: [String] = []

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var names: [ObjectIdentifier: String] = [:]
    private var latest = ScoreboardSnapshot.idle(sentAt: Date().epochMilliseconds)

    func start() {
        guard listener == nil else { return }
        do {
            let params = Self.parameters()
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: PeerProtocol.port)!)
            l.service = NWListener.Service(name: UIDevice.current.name, type: PeerProtocol.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            statusMessage = "待ち受けできません: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        names.removeAll()
        updateNames()
        statusMessage = "停止中"
    }

    /// 最新の状態を全カメラに送る。
    func broadcast(_ snapshot: ScoreboardSnapshot) {
        latest = snapshot
        for c in connections.values { send(.state(snapshot), to: c) }
    }

    /// WebSocket の設定（クライアント側も同じものを使う）。
    nonisolated static func parameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    nonisolated static func send(_ message: PeerMessage, to connection: NWConnection) {
        guard let data = try? PeerCodec.encode(message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: -

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            statusMessage = "待ち受け中"
        case .failed(let error):
            statusMessage = "待ち受けに失敗: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
            // 少し待って作り直す
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.start()
            }
        case .cancelled:
            statusMessage = "停止中"
        default:
            break
        }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(.hello(PeerHello(role: .scoreboard, deviceName: UIDevice.current.name)), to: c)
                    self.send(.state(self.latest), to: c)
                case .failed, .cancelled:
                    self.drop(c)
                default:
                    break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, let message = try? PeerCodec.decode(data) {
                    self.handle(message, from: c)
                }
                if error == nil, self.connections[ObjectIdentifier(c)] != nil {
                    self.receive(on: c)
                } else {
                    self.drop(c)
                }
            }
        }
    }

    private func handle(_ message: PeerMessage, from c: NWConnection) {
        switch message {
        case .hello(let h):
            names[ObjectIdentifier(c)] = h.deviceName
            updateNames()
        case .ping(let sentAt):
            send(.pong(pingSentAt: sentAt, receivedAt: Date().epochMilliseconds), to: c)
        case .state, .pong:
            break
        }
    }

    private func drop(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        guard connections[id] != nil else { return }
        connections[id] = nil
        names[id] = nil
        c.cancel()
        updateNames()
    }

    private func updateNames() {
        cameraNames = connections.keys.map { names[$0] ?? "カメラ" }.sorted()
    }

    private func send(_ message: PeerMessage, to c: NWConnection) {
        Self.send(message, to: c)
    }
}

enum NetworkInfo {
    /// この端末の IPv4 アドレス（Wi-Fi・テザリング）。手入力でつなぐときに画面に出す。
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
