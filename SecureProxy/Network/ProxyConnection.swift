// ProxyConnection.swift
// 修复版本 - 增强错误处理和日志

import Foundation
import Network

actor OptimizedProxyConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private let config: ProxyConfig
    private let connectionManager: OptimizedConnectionManager
    
    nonisolated let onLog: @Sendable (String) -> Void
    
    private var remoteWebSocket: SecureWebSocket?
    private var isForwarding = false
    private var bytesSent: Int64 = 0
    private var bytesReceived: Int64 = 0
    
    init(
        id: UUID,
        clientConnection: NWConnection,
        config: ProxyConfig,
        connectionManager: OptimizedConnectionManager,
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
    
    // MARK: - Remote Connection (使用连接池)
    
    func connectToRemote(host: String, port: Int) async throws {
        onLog("🔗 开始连接远程服务器: \(host):\(port)")
        
        // 从连接池获取连接
        let ws: SecureWebSocket
        do {
            ws = try await connectionManager.acquire()
            onLog("✅ 从连接池获取连接成功: \(ws.id)")
        } catch {
            onLog("❌ 从连接池获取连接失败: \(error.localizedDescription)")
            throw error
        }
        
        do {
            try await ws.sendConnect(host: host, port: port)
            remoteWebSocket = ws
            onLog("✅ 远程连接建立成功: \(host):\(port)")
        } catch {
            // 🔧 关键修复：sendConnect 失败时，连接已不可用
            onLog("❌ 远程连接失败: \(error.localizedDescription)")
            
            // 详细的错误信息
            if let wsError = error as? WebSocketError {
                onLog("🔍 WebSocket 错误详情: \(wsError.errorDescription ?? "未知错误")")
            } else if let nsError = error as NSError? {
                onLog("🔍 系统错误详情: 域=\(nsError.domain), 代码=\(nsError.code), 描述=\(nsError.localizedDescription)")
            }
            
            // 🔧 立即关闭并释放连接（让连接池知道这个连接已损坏）
            onLog("🔴 关闭失败的连接: \(ws.id)")
            await ws.close()  // 先关闭
            await connectionManager.release(ws)  // 再释放（release 会检测到不健康并移除）
            
            throw error
        }
    }
    
    // MARK: - Forwarding
    
    func startForwarding() async {
        guard let ws = remoteWebSocket else {
            onLog("⚠️ 没有远程连接，无法开始转发")
            return
        }
        
        isForwarding = true
        onLog("🔄 开始双向数据转发")
        
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
                // onLog("⚠️ 客户端->远程转发中断: \(error.localizedDescription)")
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
                // onLog("⚠️ 远程->客户端转发中断: \(error.localizedDescription)")
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
            await connectionManager.release(ws)
            remoteWebSocket = nil
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
