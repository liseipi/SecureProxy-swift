// SecureWebSocket.swift
// 优化版本 - 移除过度的健康检查，让错误自然发生

import Foundation
import CryptoKit

actor SecureWebSocket {
    let id = UUID()
    private let config: ProxyConfig
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sendKey: Data?
    private var recvKey: Data?
    private var isConnected = false
    private var messageQueue: [Data] = []
    private var messageContinuation: CheckedContinuation<Data, Error>?
    
    // 健康检查相关
    private var lastActivityTime = Date()
    private var connectionTime = Date()
    private let maxIdleTime: TimeInterval = 120
    private let maxConnectionAge: TimeInterval = 600
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // 🔧 nonisolated 方法供 delegate 调用
    nonisolated func notifyConnectionClosed() {
        Task {
            await self.handleDelegateClose()
        }
    }
    
    // 健康检查 - 仅用于连接池判断是否复用
    func isHealthy() -> Bool {
        guard isConnected else {
            return false
        }
        
        guard let task = webSocketTask, session != nil else {
            return false
        }
        
        // 🔧 关键：检查 WebSocket 的实际状态
        switch task.state {
        case .running:
            break // 只有 running 状态才是健康的
        case .suspended, .canceling, .completed:
            return false
        @unknown default:
            return false
        }
        
        let now = Date()
        
        // 检查空闲时间（只记录，不拒绝）
        if now.timeIntervalSince(lastActivityTime) > maxIdleTime {
            print("⚠️ [Health] 连接空闲 \(Int(now.timeIntervalSince(lastActivityTime)))s")
            return false
        }
        
        // 检查连接年龄（只记录，不拒绝）
        if now.timeIntervalSince(connectionTime) > maxConnectionAge {
            print("⚠️ [Health] 连接已存活 \(Int(now.timeIntervalSince(connectionTime)))s")
            return false
        }
        
        return true
    }
    
    // 更新活动时间
    private func updateActivity() {
        lastActivityTime = Date()
    }
    
    // MARK: - Connection
    
    func connect() async throws {
        // 先确保完全关闭旧连接
        if isConnected || webSocketTask != nil || session != nil {
            print("⚠️ [Connect] 检测到旧连接，先关闭")
            await forceClose()
        }
        
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            throw WebSocketError.invalidURL
        }
        
        print("🔗 [Connect] 连接到: \(url.absoluteString)")
        if useCDN {
            print("🌐 [Connect] CDN 模式 - SNI: \(config.sniHost), IP: \(config.proxyIP)")
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.sniHost, forHTTPHeaderField: "Host")
        request.setValue("SecureProxy-Swift/3.2", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Protocol-Version")
        request.timeoutInterval = 10
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        
        let delegate = WebSocketDelegate(sniHost: config.sniHost, websocket: self)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        guard let session = session else {
            throw WebSocketError.notConnected
        }
        
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        
        print("🔗 [Connect] WebSocket 任务已启动")
        
        try await setupKeys()
        
        isConnected = true
        connectionTime = Date()
        updateActivity()
        
        print("✅ [Connect] 连接建立成功 (ID: \(id))")
    }
    
    // 处理 delegate 的关闭回调
    private func handleDelegateClose() {
        if isConnected {
            print("🔴 [WebSocket \(id)] Delegate 通知连接已关闭")
            isConnected = false
        }
    }
    
    // MARK: - Key Exchange
    
    private func setupKeys() async throws {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        // 1. 客户端公钥
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await ws.send(.data(clientPub))
        updateActivity()
        
        // 2. 服务器公钥
        let serverPub = try await recvBinary()
        guard serverPub.count == 32 else {
            throw WebSocketError.invalidServerKey
        }
        updateActivity()
        
        // 3. 密钥派生
        let salt = clientPub + serverPub
        let psk = hexToData(config.preSharedKey)
        guard psk.count == 32 else {
            throw WebSocketError.invalidPSK
        }
        
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        
        // 4. 认证
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        try await ws.send(.data(challenge))
        updateActivity()
        
        // 5. 验证
        let authResponse = try await recvBinary()
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        
        guard timingSafeEqual(authResponse, expected) else {
            throw WebSocketError.authenticationFailed
        }
        updateActivity()
    }
    
    // MARK: - Send/Receive (优化：移除健康检查，让错误自然发生)
    
    func sendConnect(host: String, port: Int) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        guard let task = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        let target = "\(host):\(port)"
        let message = "CONNECT \(target)".data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: message)
        
        try await task.send(.data(encrypted))
        updateActivity()
        
        let response = try await recv()
        let responseStr = String(data: response, encoding: .utf8) ?? ""
        
        guard !responseStr.isEmpty && responseStr.starts(with: "OK") else {
            throw WebSocketError.connectionFailed(responseStr)
        }
        updateActivity()
    }
    
    func send(_ data: Data) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        guard let task = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        let encrypted = try encrypt(key: sendKey, plaintext: data)
        
        do {
            try await task.send(.data(encrypted))
            updateActivity()
        } catch {
            // WebSocket 已关闭或出错，更新状态
            isConnected = false
            throw error
        }
    }
    
    func recv() async throws -> Data {
        guard let recvKey = recvKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        do {
            let encrypted = try await recvBinary()
            updateActivity()
            return try decrypt(key: recvKey, ciphertext: encrypted)
        } catch {
            // WebSocket 已关闭或出错，更新状态
            isConnected = false
            throw error
        }
    }
    
    // MARK: - Internal Receive
    
    private func recvBinary() async throws -> Data {
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
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw WebSocketError.receiveTimeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    // MARK: - Close
    
    func close() {
        isConnected = false
        
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
        }
        
        if let sess = session {
            sess.invalidateAndCancel()
            session = nil
        }
        
        sendKey = nil
        recvKey = nil
        messageQueue.removeAll()
        
        if let cont = messageContinuation {
            cont.resume(throwing: WebSocketError.notConnected)
            messageContinuation = nil
        }
        
        lastActivityTime = Date()
        connectionTime = Date()
    }
    
    private func forceClose() async {
        close()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    
    // MARK: - Crypto Helpers
    
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
        print("🔴 [Delegate] WebSocket 已关闭，代码: \(closeCode.rawValue)")
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

// MARK: - Errors

enum WebSocketError: Error {
    case notConnected
    case connectionClosed
    case invalidURL
    case invalidServerKey
    case invalidPSK
    case authenticationFailed
    case keysNotEstablished
    case connectionFailed(String)
    case invalidFrame
    case invalidResponse
    case noData
    case receiveTimeout
    
    var localizedDescription: String {
        switch self {
        case .notConnected: return "WebSocket 未连接"
        case .connectionClosed: return "WebSocket 连接已关闭"
        case .invalidURL: return "无效的 WebSocket URL"
        case .invalidServerKey: return "无效的服务器公钥"
        case .invalidPSK: return "无效的预共享密钥"
        case .authenticationFailed: return "认证失败"
        case .keysNotEstablished: return "加密密钥未建立"
        case .connectionFailed(let reason):
            return reason.isEmpty ? "连接失败: 服务器无响应" : "连接失败: \(reason)"
        case .invalidFrame: return "无效的 WebSocket 帧"
        case .invalidResponse: return "无效的服务器响应"
        case .noData: return "没有数据"
        case .receiveTimeout: return "接收超时"
        }
    }
}
