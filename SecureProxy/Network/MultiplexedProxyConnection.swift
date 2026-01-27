// MultiplexedProxyConnection.swift
// 使用多路复用流的代理连接处理器

import Foundation
import Network

actor MultiplexedProxyConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private let config: ProxyConfig
    private let connectionManager: MultiplexedConnectionManager
    
    nonisolated let onLog: @Sendable (String) -> Void
    
    private var stream: Stream?
    private var isForwarding = false
    private var bytesSent: Int64 = 0
    private var bytesReceived: Int64 = 0
    
    init(
        id: UUID,
        clientConnection: NWConnection,
        config: ProxyConfig,
        connectionManager: MultiplexedConnectionManager,
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
    
    // MARK: - Remote Connection (使用多路复用流)
    
    func connectToRemote(host: String, port: Int) async throws {
        onLog("🔗 连接远程: \(host):\(port)")
        
        do {
            // 从连接管理器获取一个流（不是整个连接）
            let newStream = try await connectionManager.openStream(host: host, port: port)
            stream = newStream
            onLog("✅ 流 #\(newStream.id) 已建立")
        } catch {
            onLog("❌ 打开流失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Forwarding
    
    func startForwarding() async {
        guard let stream = stream else {
            onLog("⚠️ 没有流，无法转发")
            return
        }
        
        isForwarding = true
        
        // 创建双向转发任务
        async let clientToRemote: Void = forwardClientToRemote(stream: stream)
        async let remoteToClient: Void = forwardRemoteToClient(stream: stream)
        
        _ = await (clientToRemote, remoteToClient)
        
        isForwarding = false
        
        if bytesSent > 0 || bytesReceived > 0 {
            let sentMB = Double(bytesSent) / 1024 / 1024
            let recvMB = Double(bytesReceived) / 1024 / 1024
            onLog(String(format: "📊 流 #\(stream.id) 关闭 - 上传: %.2f MB, 下载: %.2f MB", sentMB, recvMB))
        }
    }
    
    private func forwardClientToRemote(stream: Stream) async {
        while isForwarding {
            do {
                let data = try await readFromClient()
                guard !data.isEmpty else { break }
                
                try await stream.send(data)
                bytesSent += Int64(data.count)
            } catch {
                break
            }
        }
    }
    
    private func forwardRemoteToClient(stream: Stream) async {
        while isForwarding {
            do {
                let data = try await stream.receive()
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
        
        if let stream = stream {
            await stream.close()
            self.stream = nil
        }
    }
}

// MARK: - Errors

enum ProxyError: LocalizedError {
    case insufficientData
    case lineTooLong
    case noData
    
    var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "接收到的数据不足"
        case .lineTooLong:
            return "请求行过长（超过 8KB）"
        case .noData:
            return "没有可用数据"
        }
    }
}
