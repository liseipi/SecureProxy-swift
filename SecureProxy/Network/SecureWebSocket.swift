// SecureWebSocket.swift
// 简化日志版本 - 极简输出

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
    
    // 连接状态锁
    private var isConnecting = false
    
    // 标记接收循环是否应该停止
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
                // 简化：连接成功不输出
                return
            } catch {
                if attempt < maxRetries - 1 {
                    let delay = min(1.0 * pow(2.0, Double(attempt)), 5.0)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    // 只在最终失败时输出
                    print("❌ WebSocket 连接失败")
                    throw WebSocketError.connectionFailed("连接失败")
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
        
        // 等待 OK 响应
        let response = try await recvWithTimeout(timeout: 10.0)
        
        guard let responseStr = String(data: response, encoding: .utf8),
              responseStr.hasPrefix("OK") else {
            throw WebSocketError.connectionRefused("拒绝连接")
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
        
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }
        
        guard waitingForMessage == nil else {
            throw WebSocketError.alreadyWaiting
        }
        
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
    
    private var shortId: String {
        String(id.uuidString.prefix(8))
    }
    
    /// 尝试建立连接
    private func attemptConnect() async throws {
        guard !destroyed else {
            throw WebSocketError.alreadyDestroyed
        }
        
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
        
        webSocketTask = session.webSocketTask(with: request)
        
        try await performConnectionWithTimeout()
    }
    
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
        
        if !timeoutTask.isCancelled {
            connectionTask.cancel()
            throw WebSocketError.operationTimeout
        }
    }
    
    private func performConnection() async throws {
        webSocketTask?.resume()
        
        try await waitForWebSocketOpen()
        
        try await setupKeys()
        
        isConnected = true
        authCompleted = true
        updateActivity()
        
        Task {
            await receiveLoop()
        }
    }
    
    private func waitForWebSocketOpen() async throws {
        for attempt in 1...3 {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                    try await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    throw WebSocketError.connectionFailed("WebSocket 打开失败")
                }
            }
        }
    }
    
    private func setupKeys() async throws {
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await sendRawBinary(clientPub)
        
        let serverPub = try await recvRawBinary(timeout: 10.0)
        guard serverPub.count == 32 else {
            throw WebSocketError.invalidServerKey
        }
        
        let salt = clientPub + serverPub
        let psk = hexToData(config.preSharedKey)
        guard psk.count == 32 else {
            throw WebSocketError.invalidPSK
        }
        
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        try await sendRawBinary(challenge)
        
        let authResponse = try await recvRawBinary(timeout: 10.0)
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        
        guard timingSafeEqual(authResponse, expected) else {
            throw WebSocketError.authenticationFailed
        }
    }
    
    /// 接收循环 - 完全静默
    private func receiveLoop() async {
        while isConnected && !destroyed && authCompleted && !shouldStopReceiving {
            do {
                guard let recvKey = recvKey else {
                    break
                }
                
                let encrypted = try await recvRawBinaryNoTimeout()
                let plaintext = try decrypt(key: recvKey, ciphertext: encrypted)
                updateActivity()
                
                if let continuation = waitingForMessage {
                    waitingForMessage = nil
                    continuation.resume(returning: plaintext)
                } else {
                    messageQueue.append(plaintext)
                }
                
            } catch {
                // 完全静默，除非是真正的错误
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
                
                let idleDuration = Date().timeIntervalSince(lastActivity)
                if idleDuration > idleTimeout {
                    close()
                    break
                }
                
                webSocketTask?.sendPing { _ in }
            }
        }
    }
    
    // MARK: - 底层发送/接收
    
    private func sendRawBinary(_ data: Data) async throws {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        let message = URLSessionWebSocketTask.Message.data(data)
        try await ws.send(message)
    }
    
    private func sendBinary(_ data: Data) async throws {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        let message = URLSessionWebSocketTask.Message.data(data)
        try await ws.send(message)
    }
    
    private func recvRawBinary(timeout: TimeInterval) async throws -> Data {
        guard let ws = webSocketTask, !destroyed else {
            throw WebSocketError.notConnected
        }
        
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
        
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
    
    private func recvWithTimeout(timeout: TimeInterval) async throws -> Data {
        guard isConnected else {
            throw WebSocketError.notConnected
        }
        
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }
        
        guard waitingForMessage == nil else {
            throw WebSocketError.alreadyWaiting
        }
        
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
        
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
                if let continuation = waitingForMessage {
                    waitingForMessage = nil
                    continuation.resume(throwing: WebSocketError.receiveTimeout)
                }
                throw WebSocketError.receiveTimeout
            }
            throw error
        }
    }
    
    private func updateActivity() {
        lastActivity = Date()
    }
    
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
        // 静默
    }
    
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // 静默
        websocket?.notifyConnectionClosed()
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // 只记录真正的错误
        if let error = error {
            let errorMsg = error.localizedDescription
            if !errorMsg.contains("cancelled") && !errorMsg.contains("Socket is not connected") {
                // 可以在这里输出，但保持简洁
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
        case .connectionClosed: return "连接已关闭"
        case .connectionFailed(let reason): return "连接失败: \(reason)"
        case .connectionRefused(let reason): return "连接被拒绝: \(reason)"
        case .connectionInProgress: return "连接中"
        case .alreadyWaiting: return "等待中"
        case .invalidURL: return "无效 URL"
        case .invalidServerKey: return "无效服务器密钥"
        case .invalidPSK: return "无效 PSK"
        case .authenticationFailed: return "认证失败"
        case .invalidFrame: return "无效帧"
        case .receiveTimeout: return "接收超时"
        case .operationTimeout: return "操作超时"
        case .alreadyDestroyed: return "已销毁"
        }
    }
}

enum CryptoError: Error {
    case invalidDataLength
    
    var localizedDescription: String {
        return "数据长度无效"
    }
}
