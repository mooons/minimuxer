// Runs against the actual Minimuxer types without requiring XCTest or an iPad.
import Foundation
import Network
import DeviceGatewayAPI
import MinimuxerCommon
// The standalone runner compiles the production sources into this module.

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

private final class UnusedEMProxy: EMProxyAPI, @unchecked Sendable {
    func start(host: String, port: UInt16) async throws { fatalError() }
    func setHandshakeClient(host: String, port: UInt16, enabled: Bool) { fatalError() }
    func stop() async throws { fatalError() }
}

private final class CheckGateway: DeviceGatewayAPI, @unchecked Sendable {
    let requiresUsbmuxd = false
    let desiredProtocol: PairingProtocol
    let port: UInt16
    private let lock = NSLock()
    private var mode = PairingProtocol.unknown
    private var probes: [PairingProtocol] = []
    private var beatAllowed = false
    private var beats = 0
    private var entered = false
    private var profiles = 0

    init(protocolType: PairingProtocol, port: UInt16) {
        desiredProtocol = protocolType
        self.port = port
    }

    var pairingFileType: PairingProtocol { lock.withLock { mode } }
    var pairingFileData: Data? { Data() }
    var pairingDataDict: [String: any Sendable]? { [:] }
    var probedUnknown: Bool { lock.withLock { probes.contains(.unknown) } }
    var heartbeatEntered: Bool { lock.withLock { entered } }
    var profileCalls: Int { lock.withLock { profiles } }

    func allowHeartbeat() { lock.withLock { beatAllowed = true } }
    func resetHeartbeat() { lock.withLock { beatAllowed = false; beats = 0; entered = false } }
    func getPort(for protocolType: PairingProtocol) -> UInt16 {
        lock.withLock { probes.append(protocolType) }
        return protocolType == .unknown ? 1 : port
    }
    func setPort(_ port: UInt16, for protocolType: PairingProtocol) {}
    func setDeviceEndpointIp(_ ip: String?) {}
    func setLogging(_ enabled: Bool) {}
    func start(pairingFileContent: String, preferred: PairingProtocol?) async throws {
        lock.withLock { mode = desiredProtocol }
    }
    func stop() async throws { lock.withLock { mode = .unknown } }
    func fetchUDID() async throws -> String { "synthetic-test-device" }
    func getLockdownValue(key: String) async throws -> String { "17.7.11" }
    func isDDIMounted() async throws -> Bool { true }
    func performHeartbeat(interval: UInt64) async throws -> UInt64 {
        lock.withLock { entered = true }
        while !lock.withLock({ beatAllowed }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        lock.withLock { beats += 1 }
        return 1000
    }
    func installProvisioningProfile(profile: Data) async throws {
        try lock.withLock {
            profiles += 1
            if mode == .lockdown && beats == 0 {
                throw CheckFailure(description: "profile install: connection reset before first heartbeat")
            }
        }
    }
    // Other services must not be invoked by these checks.
    func mountDeveloperImage(image: Data, signature: Data) async throws { fatalError() }
    func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws { fatalError() }
    func removeProvisioningProfile(id: String) async throws { fatalError() }
    func dumpProfiles(docsPath: String) async throws -> String { fatalError() }
    func removeApp(bundleId: String) async throws { fatalError() }
    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws { fatalError() }
    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws { fatalError() }
    func installIpa(bundleId: String) async throws { fatalError() }
    func installAppBundle(bundleId: String, appName: String) async throws { fatalError() }
    func wipeContainer(identifier: String) async throws { fatalError() }
    func debugApp(appId: String) async throws { fatalError() }
    func debugProcess(pid: UInt32) async throws { fatalError() }
    func startWirelessPair(hostName: String, hostModel: String, outPath: String,
                           resolveFileName: (@Sendable (String, String) -> String)?,
                           onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
                           onPin: @escaping @Sendable (String) -> Void) async throws -> PairedDeviceRecord { fatalError() }
    func triggerWirelessPair(targetIp: String, targetPort: UInt16, hostName: String, hostModel: String,
                             outPath: String, resolveFileName: (@Sendable (String, String) -> String)?,
                             onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void) async throws -> PairedDeviceRecord { fatalError() }
    func afcListDirectory(bundleId: String, path: String) async throws -> [String] { fatalError() }
    func afcReadFile(bundleId: String, path: String) async throws -> Data { fatalError() }
    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64) { fatalError() }
}

private struct Fixture {
    let core: MinimuxerImpl
    let gateway: CheckGateway
    let heartbeat: HeartbeatService
    let endpoint: DeviceEndpoint
    let network: NetworkObserverService
    let listener: NWListener

    static func make(_ protocolType: PairingProtocol) async throws -> Fixture {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let gateway = CheckGateway(protocolType: protocolType, port: listener.port!.rawValue)
        let provider = DeviceProvider(gateway: gateway)
        let endpoint = DeviceEndpoint(deviceProvider: provider)
        let proxy = UsbmuxdProxyServer(deviceProvider: provider)
        let manager = DeviceConnectionManager(deviceProvider: provider)
        let network = NetworkObserverService(connectionManager: manager, endpoint: endpoint, proxyServer: proxy)
        let heartbeat = HeartbeatService(deviceProvider: provider, proxyServer: proxy, endpoint: endpoint)
        let core = MinimuxerImpl(deviceProvider: provider, network: network, emproxy: UnusedEMProxy(),
                                wirelessPair: WirelessPairService(deviceProvider: provider),
                                mounter: Mounter(deviceProvider: provider, proxyServer: proxy, endpoint: endpoint),
                                proxyServer: proxy, endpoint: endpoint, connectionManager: manager, heartbeat: heartbeat)
        await core.bindConnectionConfig(ConnectionConfigBinding(
            setTunnelIfaceIp: { _ in }, setTunnelPeerIp: { _ in }, setTunnelPeerSubnetMask: { _ in },
            setTunnelPeerReachable: { _ in }, setTunnelIfaceSubnetMask: { _ in },
            getRemoteServerIp: { "127.0.0.1" }, setRemoteReachable: { _ in },
            getOverrideTunnelPeerIp: { "" }, setOverrideTunnelPeerReachable: { _ in },
            getConnectionMode: { .remoteServer }, resolveServicePort: nil))
        return Fixture(core: core, gateway: gateway, heartbeat: heartbeat, endpoint: endpoint,
                       network: network, listener: listener)
    }

    func close() async throws {
        await heartbeat.stop()
        try await core.stop()
        await network.stop()
        listener.cancel()
    }
}

@main
private struct LockdownRegressionCheck {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let selected = CommandLine.arguments.dropFirst().first
        if selected == nil || selected == "startup" {
            let f = try await Fixture.make(.lockdown)
            try await f.core.start(pairingFile: "synthetic", mountPath: NSTemporaryDirectory(), preferred: .lockdown)
            let ip = try? await f.endpoint.ip()
            try expect(!f.gateway.probedUnknown, "startup probed a port before loading the pairing protocol")
            try expect(ip == "127.0.0.1", "startup did not re-evaluate the endpoint after gateway initialization")
            try await f.close()
            print("PASS: pairing protocol loaded before endpoint probes")
        }
        if selected == nil || selected == "heartbeat" {
            let f = try await Fixture.make(.lockdown)
            try await f.gateway.start(pairingFileContent: "synthetic", preferred: .lockdown)
            await f.endpoint.update("127.0.0.1")
            // Repeat across stop/start to catch stale readiness surviving a restart.
            for expectedProfiles in 1...2 {
                f.gateway.resetHeartbeat()
                await f.heartbeat.start()
                let deadline = Date().addingTimeInterval(2)
                while !f.gateway.heartbeatEntered && Date() < deadline {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                try expect(f.gateway.heartbeatEntered, "heartbeat loop did not start")
                let refresh = Task { try await f.core.installProvisioningProfile(profile: Data([1])) }
                try await Task.sleep(nanoseconds: 50_000_000)
                try expect(f.gateway.profileCalls == expectedProfiles - 1,
                           "profile service ran before a successful heartbeat")
                f.gateway.allowHeartbeat()
                try await refresh.value
                try expect(f.gateway.profileCalls == expectedProfiles, "ready profile service did not run")
                await f.heartbeat.stop()
            }
            try await f.close()
            print("PASS: profile operations wait for heartbeat, including after restart")
        }
        if selected == nil || selected == "remote-pairing" {
            let f = try await Fixture.make(.rppairing)
            try await f.gateway.start(pairingFileContent: "synthetic", preferred: .rppairing)
            await f.endpoint.update("127.0.0.1")
            try await f.core.installProvisioningProfile(profile: Data([1]))
            try expect(!f.gateway.heartbeatEntered, "Remote Pairing unexpectedly started a Lockdown heartbeat")
            try await f.close()
            print("PASS: Remote Pairing bypasses the Lockdown heartbeat")
        }
    }
}
