//
//  HeartbeatService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGatewayAPI

final internal class HeartbeatService: @unchecked Sendable {
    let deviceProvider: DeviceProvider
    var gateway: any DeviceGatewayAPI { deviceProvider.gateway }
    let proxyServer: UsbmuxdProxyServer
    let endpoint: DeviceEndpoint
    private let sleepNs = MinimuxerConstants.heartbeatInterval * 1_000_000
    private var lastErrorDescription: String?

    init(deviceProvider: DeviceProvider, proxyServer: UsbmuxdProxyServer, endpoint: DeviceEndpoint) {
        self.deviceProvider = deviceProvider
        self.proxyServer = proxyServer
        self.endpoint = endpoint
    }

    private actor MutableState {
        var running = false
        private var task: Task<Void, Never>?
        private var lastSuccess: Date?
        private var successfulIP: String?

        func start(_ loop: @escaping @Sendable () async -> Void) {
            guard task == nil else { return }
            running = true
            task = Task.detached {
                await loop()
                await self.terminate()
            }
        }

        func requestStop() -> Task<Void, Never>? {
            running = false
            invalidate()
            task?.cancel()
            return task
        }

        func invalidate() {
            lastSuccess = nil
            successfulIP = nil
        }

        func succeeded(ip: String) {
            guard running else { return }
            lastSuccess = Date()
            successfulIP = ip
        }

        func isReady(ip: String) -> Bool {
            guard running, successfulIP == ip, let lastSuccess else { return false }
            return Date().timeIntervalSince(lastSuccess) < 30
        }

        private func terminate() {
            running = false
            task = nil
            invalidate()
        }
    }

    private let state = MutableState()

    // The workaround was reproduced with idevice's direct Lockdown transport.
    // Other backends and Remote Pairing keep their existing service behavior.
    private var needsHeartbeat: Bool {
        gateway.pairingFileType == .lockdown && !gateway.requiresUsbmuxd
    }

    func start() async {
        guard needsHeartbeat else { return }
        await state.start { [weak self] in
            await self?.heartbeatLoop()
        }
    }

    func stop() async {
        let task = await state.requestStop()
        // The gateway owns native handles; drain its current exchange before
        // stop/restart can free pairing data or replace the gateway.
        await task?.value
    }

    func invalidateReadiness() async {
        await state.invalidate()
    }

    func waitUntilReady(timeout: TimeInterval = 5) async throws {
        guard needsHeartbeat else { return }
        await start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let ip = try? await endpoint.ip(), await state.isReady(ip: ip) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw MinimuxerError.noDevice("Lockdown heartbeat did not become ready before opening a device service")
    }

    private func heartbeatLoop() async {
        var currentInterval = MinimuxerConstants.heartbeatInterval
        while await state.running && !Task.isCancelled {
            guard needsHeartbeat else { break }
            do {
                let ip = try await endpoint.ip()
                guard NetworkUtils.testTCP(ip: ip, port: gateway.servicePort) else {
                    throw MinimuxerError.noDevice("Lockdown endpoint is not reachable")
                }
                currentInterval = try await gateway.performHeartbeat(interval: currentInterval)
                if !Task.isCancelled {
                    await state.succeeded(ip: ip)
                    lastErrorDescription = nil
                }
            } catch {
                await state.invalidate()
                if Task.isCancelled { break }
                let description = String(describing: error)
                if description != lastErrorDescription {
                    debugLog("[minimuxer] heartbeat-task: \(description)")
                    lastErrorDescription = description
                }
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
    }
}
