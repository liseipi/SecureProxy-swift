// HTTPProxyServer.swift
import Foundation
import Network

actor HTTPProxyServer {
    private let port: Int
    private let config: ProxyConfig
    private var listener: NWListener?
    private var connections: [UUID: ProxyConnection] = [:]
    
    // 使用 nonisolated 的日志闭包，避免数据竞争
    nonisolated let onLog: @Sendable (String) -> Void
    
    init(port: Int, config: ProxyConfig, onLog: @escaping @Sendable (String) -> Void) {
        self.port = port
        self.config = config
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
            onLog: onLog
        )
        
        connections[id] = connection
        
        do {
            try await handleHTTPConnect(connection: connection)
        } catch {
            onLog("❌ HTTP 错误: \(error.localizedDescription)")
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
        
        onLog("🔗 HTTP CONNECT: \(host):\(port)")
        
        // 跳过请求头
        while true {
            let line = try await connection.readLine()
            if line.isEmpty || line == "\r\n" {
                break
            }
        }
        
        // 连接到远程服务器
        try await connection.connectToRemote(host: host, port: port)
        
        // 发送成功响应
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        try await connection.writeToClient(response.data(using: .utf8)!)
        
        // 开始双向转发
        await connection.startForwarding()
    }
}

// MARK: - Errors

enum HTTPProxyError: Error {
    case methodNotAllowed
    case invalidRequest
    
    var localizedDescription: String {
        switch self {
        case .methodNotAllowed:
            return "Method not allowed"
        case .invalidRequest:
            return "Invalid HTTP request"
        }
    }
}
