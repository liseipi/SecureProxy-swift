// SecureWebSocket.swift
// 完全重构 - 模拟 client.js 的稳定连接实现
// ✅ 修复连接不稳定问题

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
        
        for attempt in 0..<maxRetries {
            do {
                try await attemptConnect()
                reconnectAttempts = 0
                startKeepalive()
                print("✅ [WS \(id)] 连接成功")
                return
            } catch {
                print("⚠️ [WS \(id)] 连接尝试 \(attempt + 1)/\(maxRetries) 失败: \(error.localizedDescription)")
                
                if attempt < maxRetries - 1 {
                    let delay = min(1.0 * pow(2.0, Double(attempt)), 5.0)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw WebSocketError.connectionFailed("连接失败（已重试 \(maxRetries) 次）")
                }
            }
        }
    }
    
    /// 发送 CONNECT 请求
    func sendConnect(host: String, port: Int) async throws {
        guard isConnected, let sendKey = sendKey else {
            throw WebSocketError.notConnected
        }
        
        let message = "CONNECT \(host):\(port)"
        let plaintext = message.data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: plaintext)
        
        try await send(encrypted)
        updateActivity()
        
        // 等待 OK 响应
        let response = try await recv()
        guard let responseStr = String(data: response, encoding: .utf8),
              responseStr.hasPrefix("OK") else {
            throw WebSocketError.connectionRefused("服务器拒绝连接: \(host):\(port)")
        }
        
        print("✅ [WS \(id)] CONNECT \(host):\(port) 成功")
    }
    
    /// 发送数据
    func send(_ data: Data) async throws {
        guard isConnected, let ws = webSocketTask, let sendKey = sendKey else {
            throw WebSocketError.notConnected
        }
        
        let encrypted = try encrypt(key: sendKey, plaintext: data)
        let message = URLSessionWebSocketTask.Message.data(encrypted)
        
        try await ws.send(message)
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
        
        // 否则等待新数据
        return try await withCheckedThrowingContinuation { continuation in
            waitingForMessage = continuation
        }
    }
    
    /// 检查连接健康
    func isHealthy() -> Bool {
        guard isConnected else { return false }
        
        let now = Date()
        let idleDuration = now.timeIntervalSince(lastActivity)
        
        return idleDuration < idleTimeout
    }
    
    /// 关闭连接
    func close() {
        guard !destroyed else { return }
        
        destroyed = true
        isConnected = false
        
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
        
        print("🔴 [WS \(id)] 已关闭")
    }
    
    // MARK: - 内部实现
    
    /// 尝试建立连接（单次）
    private func attemptConnect() async throws {
        guard !destroyed else {
            throw WebSocketError.alreadyDestroyed
        }
        
        // 清理旧连接
        if webSocketTask != nil || session != nil {
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            session?.invalidateAndCancel()
            session = nil
        }
        
        // 构建 URL
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            throw WebSocketError.invalidURL
        }
        
        print("🔗 [WS \(id)] 正在连接: \(url.absoluteString)")
        if useCDN {
            print("🌐 [WS \(id)] CDN 模式 - SNI: \(config.sniHost), IP: \(actualHost)")
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
        webSocketTask?.resume()
        
        // ✅ 关键：等待 WebSocket 真正打开
        try await waitForWebSocketOpen()
        
        // ✅ WebSocket 打开后再进行密钥交换
        try await setupKeys()
        
        isConnected = true
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
                try await webSocketTask?.sendPing { error in
                    if let error = error {
                        print("⚠️ [WS \(self.id)] Ping 失败: \(error)")
                    }
                }
                print("✅ [WS \(id)] WebSocket 已打开")
                return
            } catch {
                if attempt < 3 {
                    print("⚠️ [WS \(id)] Ping 尝试 \(attempt)/3 失败，重试...")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    throw WebSocketError.connectionFailed("WebSocket 打开失败")
                }
            }
        }
    }
    
    /// 密钥交换和认证
    private func setupKeys() async throws {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        print("🔐 [WS \(id)] 开始密钥交换...")
        
        // 1. 生成并发送客户端公钥
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await ws.send(.data(clientPub))
        print("📤 [WS \(id)] 已发送客户端公钥")
        
        // 2. 接收服务器公钥
        let serverPub = try await recvBinaryWithTimeout(timeout: 10.0)
        guard serverPub.count == 32 else {
            throw WebSocketError.invalidServerKey
        }
        print("📥 [WS \(id)] 已接收服务器公钥")
        
        // 3. 派生密钥
        let salt = clientPub + serverPub
        let psk = hexToData(config.preSharedKey)
        guard psk.count == 32 else {
            throw WebSocketError.invalidPSK
        }
        
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        print("🔑 [WS \(id)] 密钥派生完成")
        
        // 4. 发送认证挑战
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        try await ws.send(.data(challenge))
        print("📤 [WS \(id)] 已发送认证挑战")
        
        // 5. 验证响应
        let authResponse = try await recvBinaryWithTimeout(timeout: 10.0)
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        
        guard timingSafeEqual(authResponse, expected) else {
            throw WebSocketError.authenticationFailed
        }
        
        print("✅ [WS \(id)] 认证成功")
    }
    
    /// 接收循环（核心）
    private func receiveLoop() async {
        print("🔄 [WS \(id)] 接收循环启动")
        
        while isConnected && !destroyed {
            do {
                guard let recvKey = recvKey else {
                    print("⚠️ [WS \(id)] 接收密钥未设置")
                    break
                }
                
                // ✅ 关键：使用无限超时，让 WebSocket 自然等待
                let encrypted = try await recvBinaryNoTimeout()
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
                if isConnected && !destroyed {
                    print("❌ [WS \(id)] 接收错误: \(error.localizedDescription)")
                }
                break
            }
        }
        
        print("🔴 [WS \(id)] 接收循环结束")
    }
    
    /// 保活机制
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        
        keepaliveTimer = Task {
            while !destroyed && isConnected {
                try? await Task.sleep(nanoseconds: UInt64(keepaliveInterval * 1_000_000_000))
                
                if destroyed || !isConnected {
                    break
                }
                
                // 检查空闲时间
                let idleDuration = Date().timeIntervalSince(lastActivity)
                if idleDuration > idleTimeout {
                    print("⚠️ [WS \(id)] 空闲超时，关闭连接")
                    close()
                    break
                }
                
                // 发送 ping
                do {
                    try await webSocketTask?.sendPing { error in
                        if let error = error {
//                            print("⚠️ [WS \(id)] Keepalive ping 失败: \(error)")
                        }
                    }
                } catch {
                    print("⚠️ [WS \(id)] Keepalive 发送失败")
                }
            }
        }
    }
    
    /// 带超时的接收（用于密钥交换）
    private func recvBinaryWithTimeout(timeout: TimeInterval) async throws -> Data {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
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
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebSocketError.receiveTimeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    /// 无超时接收（用于接收循环）
    private func recvBinaryNoTimeout() async throws -> Data {
        guard let ws = webSocketTask else {
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
    
    /// 更新活动时间
    private func updateActivity() {
        lastActivity = Date()
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
            print("🔴 [WS \(id)] Delegate 通知连接已关闭")
            isConnected = false
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
        print("✅ [Delegate] WebSocket 已打开")
    }
    
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "无"
        print("🔴 [Delegate] WebSocket 已关闭，代码: \(closeCode.rawValue), 原因: \(reasonStr)")
        websocket?.notifyConnectionClosed()
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            print("❌ [Delegate] 连接错误: \(error.localizedDescription)")
            websocket?.notifyConnectionClosed()
        }
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
    case invalidURL
    case invalidServerKey
    case invalidPSK
    case authenticationFailed
    case invalidFrame
    case receiveTimeout
    case alreadyDestroyed
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket 未连接"
        case .connectionClosed: return "WebSocket 连接已关闭"
        case .connectionFailed(let reason): return "连接失败: \(reason)"
        case .connectionRefused(let reason): return "连接被拒绝: \(reason)"
        case .invalidURL: return "无效的 URL"
        case .invalidServerKey: return "无效的服务器公钥"
        case .invalidPSK: return "无效的预共享密钥"
        case .authenticationFailed: return "认证失败"
        case .invalidFrame: return "无效的 WebSocket 帧"
        case .receiveTimeout: return "接收超时"
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
