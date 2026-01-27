// SOCKS5Server.swift
// 使用连接池的 SOCKS5 服务器
// ✅ 模拟 client.js 的稳定实现

import Foundation
import Network

actor SOCKS5Server {
    private let port: Int
    private let config: ProxyConfig
    private let connectionManager: ConnectionManager
    private var listener: NWListener?
    private var connections: [UUID: ProxyConnection] = [:]
    
    nonisolated let onLog: @Sendable (String) -> Void
    
    init(
        port: Int,
        config: ProxyConfig,
        connectionManager: ConnectionManager,
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
        onLog("✅ SOCKS5 服务器启动: 127.0.0.1:\(port)")
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
        let connection = ProxyConnection(
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
    
    private func handleSOCKS5(connection: ProxyConnection) async throws {
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
        
        // 4. 连接到远程
        try await connection.connectToRemote(host: host, port: port)
        
        // 5. 发送成功响应
        let response = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        try await connection.writeToClient(response)
        
        // 6. 开始双向转发
        await connection.startForwarding()
    }
    
    private func parseAddress(connection: ProxyConnection, addrType: UInt8) async throws -> (String, Int) {
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

// MARK: - HTTP 代理服务器

actor HTTPProxyServer {
    private let port: Int
    private let config: ProxyConfig
    private let connectionManager: ConnectionManager
    private var listener: NWListener?
    private var connections: [UUID: ProxyConnection] = [:]
    
    nonisolated let onLog: @Sendable (String) -> Void
    
    init(
        port: Int,
        config: ProxyConfig,
        connectionManager: ConnectionManager,
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
        onLog("✅ HTTP 代理服务器启动: 127.0.0.1:\(port)")
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
        
        onLog("🛑 HTTP 代理服务器已停止")
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            onLog("📡 HTTP 监听就绪")
        case .failed(let error):
            onLog("❌ HTTP 监听失败: \(error)")
        default:
            break
        }
    }
    
    private func handleNewConnection(_ nwConnection: NWConnection) async {
        let id = UUID()
        let connection = ProxyConnection(
            id: id,
            clientConnection: nwConnection,
            config: config,
            connectionManager: connectionManager,
            onLog: onLog
        )
        
        connections[id] = connection
        
        do {
            try await handleHTTPConnect(connection: connection)
        } catch {
            // 错误已记录
        }
        
        await connection.close()
        connections.removeValue(forKey: id)
    }
    
    private func handleHTTPConnect(connection: ProxyConnection) async throws {
        // 读取请求行
        let requestLine = try await connection.readLine()
        
        // 解析 CONNECT 请求
        guard requestLine.starts(with: "CONNECT ") else {
            let response = "HTTP/1.1 405 Method Not Allowed\r\n\r\n"
            try await connection.writeToClient(response.data(using: .utf8)!)
            throw HTTPProxyError.methodNotAllowed
        }
        
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw HTTPProxyError.invalidRequest
        }
        
        let hostPort = String(parts[1])
        let components = hostPort.split(separator: ":")
        
        let host: String
        let port: Int
        
        if components.count == 2 {
            host = String(components[0])
            port = Int(components[1]) ?? 443
        } else {
            host = hostPort
            port = 443
        }
        
        // 跳过请求头
        while true {
            let line = try await connection.readLine()
            if line.isEmpty || line == "\r\n" {
                break
            }
        }
        
        // 连接到远程
        try await connection.connectToRemote(host: host, port: port)
        
        // 发送成功响应
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        try await connection.writeToClient(response.data(using: .utf8)!)
        
        // 开始双向转发
        await connection.startForwarding()
    }
}

// MARK: - 代理连接处理器

actor ProxyConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private let config: ProxyConfig
    private let connectionManager: ConnectionManager
    
    nonisolated let onLog: @Sendable (String) -> Void
    
    private var ws: SecureWebSocket?
    private var isForwarding = false
    private var bytesSent: Int64 = 0
    private var bytesReceived: Int64 = 0
    
    init(
        id: UUID,
        clientConnection: NWConnection,
        config: ProxyConfig,
        connectionManager: ConnectionManager,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        self.id = id
        self.clientConnection = clientConnection
        self.config = config
        self.connectionManager = connectionManager
        self.onLog = onLog
        
        clientConnection.start(queue: .global())
    }
    
    // MARK: - Client Operations
    
    func readBytes(_ count: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            clientConnection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = data, data.count == count else {
                    continuation.resume(throwing: ProxyError.insufficientData)
                    return
                }
                
                continuation.resume(returning: data)
            }
        }
    }
    
    func readLine() async throws -> String {
        var buffer = Data()
        
        while true {
            let byte = try await readBytes(1)
            buffer.append(byte)
            
            if buffer.count >= 2 {
                let lastTwo = buffer.suffix(2)
                if lastTwo == Data([0x0D, 0x0A]) {
                    break
                }
            }
            
            if buffer.count > 8192 {
                throw ProxyError.lineTooLong
            }
        }
        
        return String(data: buffer, encoding: .utf8) ?? ""
    }
    
    func writeToClient(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            clientConnection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
    
    // MARK: - Remote Connection
    
    func connectToRemote(host: String, port: Int) async throws {
        onLog("🔗 [\(id.uuidString.prefix(6))] 连接: \(host):\(port)")
        
        do {
            // 从池中获取连接
            let websocket = try await connectionManager.acquire()
            ws = websocket
            
            // 发送 CONNECT
            try await websocket.sendConnect(host: host, port: port)
            
            onLog("✅ [\(id.uuidString.prefix(6))] 已连接")
        } catch {
            onLog("❌ [\(id.uuidString.prefix(6))] 连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Forwarding
    
    func startForwarding() async {
        guard let ws = ws else {
            onLog("⚠️ [\(id.uuidString.prefix(6))] 没有 WebSocket，无法转发")
            return
        }
        
        isForwarding = true
        
        // 创建双向转发任务
        async let clientToRemote: Void = forwardClientToRemote(ws: ws)
        async let remoteToClient: Void = forwardRemoteToClient(ws: ws)
        
        _ = await (clientToRemote, remoteToClient)
        
        isForwarding = false
        
        if bytesSent > 0 || bytesReceived > 0 {
            let sentMB = Double(bytesSent) / 1024 / 1024
            let recvMB = Double(bytesReceived) / 1024 / 1024
            onLog(String(format: "📊 [\(id.uuidString.prefix(6))] 上传: %.2f MB, 下载: %.2f MB", sentMB, recvMB))
        }
    }
    
    private func forwardClientToRemote(ws: SecureWebSocket) async {
        while isForwarding {
            do {
                let data = try await readFromClient()
                guard !data.isEmpty else { break }
                
                try await ws.send(data)
                bytesSent += Int64(data.count)
            } catch {
                break
            }
        }
    }
    
    private func forwardRemoteToClient(ws: SecureWebSocket) async {
        while isForwarding {
            do {
                let data = try await ws.recv()
                guard !data.isEmpty else { break }
                
                try await writeToClient(data)
                bytesReceived += Int64(data.count)
            } catch {
                break
            }
        }
    }
    
    private func readFromClient() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let data = data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: ProxyError.noData)
                }
            }
        }
    }
    
    // MARK: - Close
    
    func close() async {
        isForwarding = false
        
        clientConnection.cancel()
        
        if let ws = ws {
            await connectionManager.release(ws)
            self.ws = nil
        }
    }
}

// MARK: - 错误定义

enum SOCKS5Error: Error {
    case invalidVersion
    case unsupportedCommand
    case unsupportedAddressType
}

enum HTTPProxyError: Error {
    case methodNotAllowed
    case invalidRequest
}

enum ProxyError: LocalizedError {
    case insufficientData
    case lineTooLong
    case noData
}
