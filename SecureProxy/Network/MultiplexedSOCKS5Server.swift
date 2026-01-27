// MultiplexedSOCKS5Server.swift
// 使用多路复用的 SOCKS5 服务器

import Foundation
import Network

actor MultiplexedSOCKS5Server {
    private let port: Int
    private let config: ProxyConfig
    private let connectionManager: MultiplexedConnectionManager
    private var listener: NWListener?
    private var connections: [UUID: MultiplexedProxyConnection] = [:]
    
    nonisolated let onLog: @Sendable (String) -> Void
    
    init(
        port: Int,
        config: ProxyConfig,
        connectionManager: MultiplexedConnectionManager,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        self.port = port
        self.config = config
        self.connectionManager = connectionManager
        self.onLog = onLog
    }
    
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task {
                await self?.handleListenerState(state)
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleNewConnection(connection)
            }
        }
        
        listener?.start(queue: .global())
        onLog("✅ SOCKS5 服务器启动: 127.0.0.1:\(port) (多路复用模式)")
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        
        for (_, connection) in connections {
            Task {
                await connection.close()
            }
        }
        connections.removeAll()
        
        onLog("🛑 SOCKS5 服务器已停止")
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            onLog("📡 SOCKS5 监听就绪")
        case .failed(let error):
            onLog("❌ SOCKS5 监听失败: \(error)")
        default:
            break
        }
    }
    
    private func handleNewConnection(_ nwConnection: NWConnection) async {
        let id = UUID()
        let connection = MultiplexedProxyConnection(
            id: id,
            clientConnection: nwConnection,
            config: config,
            connectionManager: connectionManager,
            onLog: onLog
        )
        
        connections[id] = connection
        
        do {
            try await handleSOCKS5(connection: connection)
        } catch {
            // 错误已记录
        }
        
        await connection.close()
        connections.removeValue(forKey: id)
    }
    
    private func handleSOCKS5(connection: MultiplexedProxyConnection) async throws {
        // 1. 握手
        let greeting = try await connection.readBytes(2)
        guard greeting[0] == 0x05 else {
            throw SOCKS5Error.invalidVersion
        }
        
        let nmethods = Int(greeting[1])
        _ = try await connection.readBytes(nmethods)
        
        try await connection.writeToClient(Data([0x05, 0x00]))
        
        // 2. 读取请求
        let request = try await connection.readBytes(4)
        let cmd = request[1]
        let addrType = request[3]
        
        guard cmd == 0x01 else {
            try await connection.writeToClient(Data([0x05, 0x07]))
            throw SOCKS5Error.unsupportedCommand
        }
        
        // 3. 解析目标地址
        let (host, port) = try await parseAddress(connection: connection, addrType: addrType)
        
        // 4. 连接到远程（打开一个流）
        try await connection.connectToRemote(host: host, port: port)
        
        // 5. 发送成功响应
        let response = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        try await connection.writeToClient(response)
        
        // 6. 开始双向转发
        await connection.startForwarding()
    }
    
    private func parseAddress(connection: MultiplexedProxyConnection, addrType: UInt8) async throws -> (String, Int) {
        switch addrType {
        case 0x01: // IPv4
            let addr = try await connection.readBytes(4)
            let host = addr.map { String($0) }.joined(separator: ".")
            let portData = try await connection.readBytes(2)
            let port = Int(portData[0]) << 8 | Int(portData[1])
            return (host, port)
            
        case 0x03: // Domain
            let len = try await connection.readBytes(1)
            let domain = try await connection.readBytes(Int(len[0]))
            let host = String(data: domain, encoding: .utf8) ?? ""
            let portData = try await connection.readBytes(2)
            let port = Int(portData[0]) << 8 | Int(portData[1])
            return (host, port)
            
        case 0x04: // IPv6
            let addr = try await connection.readBytes(16)
            let host = addr.map { String(format: "%02x", $0) }.joined(separator: ":")
            let portData = try await connection.readBytes(2)
            let port = Int(portData[0]) << 8 | Int(portData[1])
            return (host, port)
            
        default:
            throw SOCKS5Error.unsupportedAddressType
        }
    }
}

// MARK: - Errors

enum SOCKS5Error: Error {
    case invalidVersion
    case unsupportedCommand
    case unsupportedAddressType
    
    var localizedDescription: String {
        switch self {
        case .invalidVersion:
            return "Invalid SOCKS version"
        case .unsupportedCommand:
            return "Unsupported SOCKS command"
        case .unsupportedAddressType:
            return "Unsupported address type"
        }
    }
}
