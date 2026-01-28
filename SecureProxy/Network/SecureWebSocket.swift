// SecureWebSocket.swift
// 优化版 - 改进日志和错误处理
// ✅ 减少不必要的错误日志
// ✅ 优雅处理连接关闭

import Foundation
import CryptoKit

/// 稳定的 WebSocket 连接实现
actor SecureWebSocket {
    let id = UUID()
    private let config: ProxyConfig
    
    // WebSocket 相关
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sendKey: Data?
    private var recvKey: Data?
    private var isConnected = false
    
    // 连接管理
    private var reconnectAttempts = 0
    private var lastActivity = Date()
    private var keepaliveTimer: Task<Void, Never>?
    private var destroyed = false
    
    // 消息队列
    private var messageQueue: [Data] = []
    private var waitingForMessage: CheckedContinuation<Data, Error>?
    
    // 认证完成标志
    private var authCompleted = false
    
    // 连接状态锁，防止并发问题
    private var isConnecting = false
    
    // ✅ 新增：标记接收循环是否应该停止
    private var shouldStopReceiving = false
    
    // 配置常量
    private let maxRetries = 3
    private let connectTimeout: TimeInterval = 10.0
    private let keepaliveInterval: TimeInterval = 20.0
    private let idleTimeout: TimeInterval = 120.0
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // MARK: - 公开接口
    
    /// 连接到服务器（带重试）
    func connect() async throws {
        guard !destroyed else {
            throw WebSocketError.alreadyDestroyed
        }
        
        // 防止重复连接
        guard !isConnecting else {
            throw WebSocketError.connectionInProgress
        }
        
        isConnecting = true
        defer { isConnecting = false }
        
        for attempt in 0..<maxRetries {
            do {
                try await attemptConnect()
                reconnectAttempts = 0
                startKeepalive()
                print("✅ [WS \(shortId)] 连接成功")
                return
            } catch {
                if attempt < maxRetries - 1 {
                    let delay = min(1.0 * pow(2.0, Double(attempt)), 5.0)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    print("❌ [WS \(shortId)] 连接失败: \(error.localizedDescription)")
                    throw WebSocketError.connectionFailed("连接失败（已重试 \(maxRetries) 次）")
                }
            }
        }
    }
    
    /// 发送 CONNECT 请求
    func sendConnect(host: String, port: Int) async throws {
        guard isConnected && authCompleted, let sendKey = sendKey else {
            throw WebSocketError.notConnected
        }
        
        let message = "CONNECT \(host):\(port)"
        let plaintext = message.data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: plaintext)
        
        try await sendBinary(encrypted)
        updateActivity()
        
        // 等待 OK 响应（带超时）
        let response = try await recvWithTimeout(timeout: 10.0)
        
        guard let responseStr = String(data: response, encoding: .utf8),
              responseStr.hasPrefix("OK") else {
            throw WebSocketError.connectionRefused("服务器拒绝连接: \(host):\(port)")
        }
    }
    
    /// 发送数据
    func send(_ data: Data) async throws {
        guard isConnected && authCompleted, let sendKey = sendKey else {
            throw WebSocketError.notConnected
        }
        
        let encrypted = try encrypt(key: sendKey, plaintext: data)
        try await sendBinary(encrypted)
        updateActivity()
    }
    
    /// 接收数据
    func recv() async throws -> Data {
        guard isConnected else {
            throw WebSocketError.notConnected
        }
        
        // 如果队列有数据，直接返回
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }
        
        // 检查是否已经有等待者
        guard waitingForMessage == nil else {
            throw WebSocketError.alreadyWaiting
        }
        
        // 否则等待新数据
        return try await withCheckedThrowingContinuation { continuation in
            waitingForMessage = continuation
        }
    }
    
    /// 检查连接健康
    func isHealthy() -> Bool {
        guard isConnected && authCompleted && !destroyed else { return false }
        
        let now = Date()
        let idleDuration = now.timeIntervalSince(lastActivity)
        
        return idleDuration < idleTimeout
    }
    
    /// 关闭连接
    func close() {
        guard !destroyed else { return }
        
        destroyed = true
        shouldStopReceiving = true
        cleanup()
    }
    
    // MARK: - 内部实现
    
    /// 短 ID（用于日志）
    private var shortId: String {
        String(id.uuidString.prefix(8))
    }
    
    /// 尝试建立连接（单次）
    private func attemptConnect() async throws {
        guard !destroyed else {
            throw WebSocketError.alreadyDestroyed
        }
        
        // 清理旧连接
        cleanup()
        shouldStopReceiving = false
        
        // 构建 URL
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            throw WebSocketError.invalidURL
        }
        
        // 创建请求
        var request = URLRequest(url: url)
        request.setValue(config.sniHost, forHTTPHeaderField: "Host")
        request.setValue("SecureProxy-Swift/4.0", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Protocol-Version")
        request.timeoutInterval = connectTimeout
        
        // 创建 session
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = connectTimeout
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        
        let delegate = WebSocketDelegate(sniHost: config.sniHost, websocket: self)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        guard let session = session else {
            throw WebSocketError.notConnected
        }
        
        // 创建 WebSocket
        webSocketTask = session.webSocketTask(with: request)
        
        // 执行连接（带超时）
        try await performConnectionWithTimeout()
    }
    
    /// 执行连接（带超时）
    private func performConnectionWithTimeout() async throws {
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
        }
        
        let connectionTask = Task {
            try await performConnection()
        }
        
        do {
            try await connectionTask.value
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }
        
        // 检查是否超时
        if !timeoutTask.isCancelled {
            connectionTask.cancel()
            throw WebSocketError.operationTimeout
        }
    }
    
    /// 执行连接（内部方法）
    private func performConnection() async throws {
        // 启动 WebSocket
        webSocketTask?.resume()
        
        // 等待 open 事件（通过 ping 确认）
        try await waitForWebSocketOpen()
        
        // WebSocket 打开后立即进行密钥交换和认证
        try await setupKeys()
        
        // 认证成功
        isConnected = true
        authCompleted = true
        updateActivity()
        
        // 启动接收循环
        Task {
            await receiveLoop()
        }
    }
    
    /// 等待 WebSocket 打开
    private func waitForWebSocketOpen() async throws {
        // 发送 ping 来确认连接
        for attempt in 1...3 {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // 添加状态检查
                    guard let task = webSocketTask, !destroyed else {
                        continuation.resume(throwing: WebSocketError.notConnected)
                        return
                    }
                    
                    task.sendPing { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                return
            } catch {
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                } else {
                    throw WebSocketError.connectionFailed("WebSocket 打开失败")
                }
            }
        }
    }
    
    /// 密钥交换和认证
    private func setupKeys() async throws {
        // 1. 生成并发送客户端公钥（32 字节随机数）
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await sendRawBinary(clientPub)
        
        // 2. 接收服务器公钥（带超时）
        let serverPub = try await recvRawBinary(timeout: 10.0)
        guard serverPub.count == 32 else {
            throw WebSocketError.invalidServerKey
        }
        
        // 3. 派生密钥
        let salt = clientPub + serverPub
        let psk = hexToData(config.preSharedKey)
        guard psk.count == 32 else {
            throw WebSocketError.invalidPSK
        }
        
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        
        // 4. 发送认证挑战
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        try await sendRawBinary(challenge)
        
        // 5. 验证响应（带超时）
        let authResponse = try await recvRawBinary(timeout: 10.0)
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        
        guard timingSafeEqual(authResponse, expected) else {
            throw WebSocketError.authenticationFailed
        }
    }
    
    /// ✅ 改进：接收循环 - 优雅处理关闭
    private func receiveLoop() async {
        while isConnected && !destroyed && authCompleted && !shouldStopReceiving {
            do {
                guard let recvKey = recvKey else {
                    break
                }
                
                // 接收加密数据
                let encrypted = try await recvRawBinaryNoTimeout()
                
                // 解密
                let plaintext = try decrypt(key: recvKey, ciphertext: encrypted)
                updateActivity()
                
                // 放入队列或唤醒等待者
                if let continuation = waitingForMessage {
                    waitingForMessage = nil
                    continuation.resume(returning: plaintext)
                } else {
                    messageQueue.append(plaintext)
                }
                
            } catch {
                // ✅ 只在非正常关闭时才记录错误
                if !destroyed && !shouldStopReceiving {
                    // 检查是否是 "Socket is not connected" 错误
                    let errorMsg = error.localizedDescription
                    if !errorMsg.contains("Socket is not connected") && !errorMsg.contains("cancelled") {
                        print("⚠️ [WS \(shortId)] 接收异常: \(errorMsg)")
                    }
                }
                break
            }
        }
    }
    
    /// 保活机制
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        
        keepaliveTimer = Task {
            while !destroyed && isConnected && !shouldStopReceiving {
                try? await Task.sleep(nanoseconds: UInt64(keepaliveInterval * 1_000_000_000))
                
                if destroyed || !isConnected || shouldStopReceiving {
                    break
                }
                
                // 检查空闲时间
                let idleDuration = Date().timeIntervalSince(lastActivity)
                if idleDuration > idleTimeout {
                    close()
                    break
                }
                
                // 直接发送 ping，不使用 continuation
                webSocketTask?.sendPing { _ in }
            }
        }
    }
    
    // MARK: - 底层发送/接收
    
    /// 发送原始二进制数据（用于密钥交换）
    private func sendRawBinary(_ data: Data) async throws {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        let message = URLSessionWebSocketTask.Message.data(data)
        try await ws.send(message)
    }
    
    /// 发送加密后的二进制数据
    private func sendBinary(_ data: Data) async throws {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        let message = URLSessionWebSocketTask.Message.data(data)
        try await ws.send(message)
    }
    
    /// 接收原始二进制（带超时）
    private func recvRawBinary(timeout: TimeInterval) async throws -> Data {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        // 创建超时任务
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
        
        // 创建接收任务
        let receiveTask = Task { () -> Data in
            let message = try await ws.receive()
            switch message {
            case .data(let data):
                return data
            case .string(let text):
                return text.data(using: .utf8) ?? Data()
            @unknown default:
                throw WebSocketError.invalidFrame
            }
        }
        
        // 等待任一完成
        do {
            let result = try await receiveTask.value
            timeoutTask.cancel()
            return result
        } catch {
            if !timeoutTask.isCancelled {
                receiveTask.cancel()
                throw WebSocketError.receiveTimeout
            }
            throw error
        }
    }
    
    /// 接收原始二进制（无超时，用于接收循环）
    private func recvRawBinaryNoTimeout() async throws -> Data {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        let message = try await ws.receive()
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return text.data(using: .utf8) ?? Data()
        @unknown default:
            throw WebSocketError.invalidFrame
        }
    }
    
    /// 接收数据（带超时）- 用于 sendConnect
    private func recvWithTimeout(timeout: TimeInterval) async throws -> Data {
        guard isConnected else {
            throw WebSocketError.notConnected
        }
        
        // 如果队列有数据，直接返回
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }
        
        // 检查是否已经有等待者
        guard waitingForMessage == nil else {
            throw WebSocketError.alreadyWaiting
        }
        
        // 创建超时任务
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
        
        // 等待消息
        let receiveTask = Task { () -> Data in
            return try await withCheckedThrowingContinuation { continuation in
                waitingForMessage = continuation
            }
        }
        
        do {
            let result = try await receiveTask.value
            timeoutTask.cancel()
            return result
        } catch {
            if !timeoutTask.isCancelled {
                receiveTask.cancel()
                // 清理 continuation
                if let continuation = waitingForMessage {
                    waitingForMessage = nil
                    continuation.resume(throwing: WebSocketError.receiveTimeout)
                }
                throw WebSocketError.receiveTimeout
            }
            throw error
        }
    }
    
    /// 更新活动时间
    private func updateActivity() {
        lastActivity = Date()
    }
    
    /// 清理资源
    private func cleanup() {
        isConnected = false
        authCompleted = false
        
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        session?.invalidateAndCancel()
        session = nil
        
        sendKey = nil
        recvKey = nil
        
        messageQueue.removeAll()
        
        // 安全地清理 continuation
        if let continuation = waitingForMessage {
            waitingForMessage = nil
            continuation.resume(throwing: WebSocketError.connectionClosed)
        }
    }
    
    // MARK: - 加密工具
    
    @inline(__always)
    private func deriveKeys(sharedKey: Data, salt: Data) -> (sendKey: Data, recvKey: Data) {
        let info = "secure-proxy-v1".data(using: .utf8)!
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedKey),
            salt: salt,
            info: info,
            outputByteCount: 64
        )
        let keyData = derivedKey.withUnsafeBytes { Data($0) }
        return (Data(keyData.prefix(32)), Data(keyData.suffix(32)))
    }
    
    @inline(__always)
    private func encrypt(key: Data, plaintext: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        
        var result = Data(capacity: 12 + plaintext.count + 16)
        result.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }
    
    @inline(__always)
    private func decrypt(key: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 28 else {
            throw CryptoError.invalidDataLength
        }
        
        let symmetricKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: ciphertext.prefix(12))
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext.dropFirst(12).dropLast(16),
            tag: ciphertext.suffix(16)
        )
        
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
    @inline(__always)
    private func hmacSHA256(key: Data, message: Data) -> Data {
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(hmac)
    }
    
    @inline(__always)
    private func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var result: UInt8 = 0
        for i in 0..<lhs.count {
            result |= lhs[i] ^ rhs[i]
        }
        return result == 0
    }
    
    private func hexToData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
    
    // MARK: - Delegate 回调
    
    nonisolated func notifyConnectionClosed() {
        Task {
            await handleDelegateClose()
        }
    }
    
    private func handleDelegateClose() {
        if isConnected {
            shouldStopReceiving = true
            cleanup()
        }
    }
}

// MARK: - WebSocket Delegate

final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let sniHost: String
    private weak var websocket: SecureWebSocket?
    
    init(sniHost: String, websocket: SecureWebSocket) {
        self.sniHost = sniHost
        self.websocket = websocket
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // 静默，不记录
    }
    
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // 静默通知，不记录（正常关闭）
        websocket?.notifyConnectionClosed()
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            // 只记录非取消的错误
            let errorMsg = error.localizedDescription
            if !errorMsg.contains("cancelled") && !errorMsg.contains("Socket is not connected") {
                print("⚠️ [Delegate] 连接异常: \(errorMsg)")
            }
        }
        websocket?.notifyConnectionClosed()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - 错误定义

enum WebSocketError: LocalizedError {
    case notConnected
    case connectionClosed
    case connectionFailed(String)
    case connectionRefused(String)
    case connectionInProgress
    case alreadyWaiting
    case invalidURL
    case invalidServerKey
    case invalidPSK
    case authenticationFailed
    case invalidFrame
    case receiveTimeout
    case operationTimeout
    case alreadyDestroyed
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket 未连接"
        case .connectionClosed: return "WebSocket 连接已关闭"
        case .connectionFailed(let reason): return "连接失败: \(reason)"
        case .connectionRefused(let reason): return "连接被拒绝: \(reason)"
        case .connectionInProgress: return "连接正在进行中"
        case .alreadyWaiting: return "已有等待中的接收操作"
        case .invalidURL: return "无效的 URL"
        case .invalidServerKey: return "无效的服务器公钥"
        case .invalidPSK: return "无效的预共享密钥"
        case .authenticationFailed: return "认证失败"
        case .invalidFrame: return "无效的 WebSocket 帧"
        case .receiveTimeout: return "接收超时"
        case .operationTimeout: return "操作超时"
        case .alreadyDestroyed: return "WebSocket 已销毁"
        }
    }
}

enum CryptoError: Error {
    case invalidDataLength
    
    var localizedDescription: String {
        switch self {
        case .invalidDataLength:
            return "无效的数据长度"
        }
    }
}
