// ProxyConnection.swift
import Foundation
import Network

actor ProxyConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private let config: ProxyConfig
    
    // 使用 nonisolated 的日志闭包
    nonisolated let onLog: @Sendable (String) -> Void
    
    private var remoteWebSocket: SecureWebSocket?
    private var isForwarding = false
    private var bytesSent: Int64 = 0
    private var bytesReceived: Int64 = 0
    
    init(
        id: UUID,
        clientConnection: NWConnection,
        config: ProxyConfig,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        self.id = id
        self.clientConnection = clientConnection
        self.config = config
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
            
            // 检查是否为行尾
            if buffer.count >= 2 {
                let lastTwo = buffer.suffix(2)
                if lastTwo == Data([0x0D, 0x0A]) { // \r\n
                    break
                }
            }
            
            // 防止无限读取
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
        let ws = SecureWebSocket(config: config)
        
        do {
            try await ws.connect()
            try await ws.sendConnect(host: host, port: port)
            remoteWebSocket = ws
            onLog("✅ 远程连接建立: \(host):\(port)")
        } catch {
            onLog("❌ 远程连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Forwarding
    
    func startForwarding() async {
        guard let ws = remoteWebSocket else {
            return
        }
        
        isForwarding = true
        
        // 创建双向转发任务
        async let clientToRemote: Void = forwardClientToRemote(ws: ws)
        async let remoteToClient: Void = forwardRemoteToClient(ws: ws)
        
        // 等待任一方向完成
        _ = await (clientToRemote, remoteToClient)
        
        isForwarding = false
        
        if bytesSent > 0 || bytesReceived > 0 {
            let sentMB = Double(bytesSent) / 1024 / 1024
            let recvMB = Double(bytesReceived) / 1024 / 1024
            onLog(String(format: "📊 连接关闭 - 上传: %.2f MB, 下载: %.2f MB", sentMB, recvMB))
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
        
        if let ws = remoteWebSocket {
            await ws.close()
            remoteWebSocket = nil
        }
    }
}

// MARK: - Errors

enum ProxyError: Error {
    case insufficientData
    case lineTooLong
    case noData
    
    var localizedDescription: String {
        switch self {
        case .insufficientData:
            return "Insufficient data received"
        case .lineTooLong:
            return "Line too long"
        case .noData:
            return "No data available"
        }
    }
}
