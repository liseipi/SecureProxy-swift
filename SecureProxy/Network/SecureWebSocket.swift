// SecureWebSocket.swift
// 优化版本 - 支持健康检查和连接复用

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
    private let maxIdleTime: TimeInterval = 120 // 2分钟无活动则认为不健康
    private let maxConnectionAge: TimeInterval = 600 // 10分钟后重建连接
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // 健康检查
    func isHealthy() -> Bool {
        guard isConnected else { return false }
        
        let now = Date()
        
        // 检查空闲时间
        if now.timeIntervalSince(lastActivityTime) > maxIdleTime {
            return false
        }
        
        // 检查连接年龄
        if now.timeIntervalSince(connectionTime) > maxConnectionAge {
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
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            throw WebSocketError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.sniHost, forHTTPHeaderField: "Host")
        request.setValue("SecureProxy-Swift/3.2", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Protocol-Version")
        request.timeoutInterval = 10
        
        // 优化的 URLSession 配置
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 10 // 增加并发连接数
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil // 禁用缓存减少开销
        
        let delegate = WebSocketDelegate(sniHost: config.sniHost)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        try await setupKeys()
        
        isConnected = true
        connectionTime = Date()
        updateActivity()
    }
    
    // MARK: - Key Exchange (增强错误处理)
    
    private func setupKeys() async throws {
        guard let ws = webSocketTask else {
            print("❌ WebSocketTask 为 nil")
            throw WebSocketError.notConnected
        }
        
        // 1. 客户端公钥
        print("1️⃣ 发送客户端公钥...")
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        print("   客户端公钥 (前8字节): \(clientPub.prefix(8).map { String(format: "%02x", $0) }.joined())")
        
        try await ws.send(.data(clientPub))
        updateActivity()
        print("✅ 客户端公钥已发送 (32字节)")
        
        // 2. 服务器公钥
        print("2️⃣ 等待服务器公钥...")
        let serverPub = try await recvBinary()
        print("   收到数据: \(serverPub.count) 字节")
        
        guard serverPub.count == 32 else {
            print("❌ 服务器公钥长度错误: 期望32字节，实际\(serverPub.count)字节")
            print("   数据 (前32字节): \(serverPub.prefix(32).map { String(format: "%02x", $0) }.joined())")
            throw WebSocketError.invalidServerKey
        }
        print("   服务器公钥 (前8字节): \(serverPub.prefix(8).map { String(format: "%02x", $0) }.joined())")
        updateActivity()
        print("✅ 收到服务器公钥")
        
        // 3. 密钥派生
        print("3️⃣ 派生加密密钥...")
        let salt = clientPub + serverPub
        print("   Salt (前8字节): \(salt.prefix(8).map { String(format: "%02x", $0) }.joined())")
        
        let psk = hexToData(config.preSharedKey)
        print("   PSK 长度: \(psk.count) 字节")
        print("   PSK (前8字节): \(psk.prefix(8).map { String(format: "%02x", $0) }.joined())")
        
        guard psk.count == 32 else {
            print("❌ PSK 长度错误: 期望32字节，实际\(psk.count)字节")
            throw WebSocketError.invalidPSK
        }
        
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        print("   发送密钥 (前8字节): \(keys.sendKey.prefix(8).map { String(format: "%02x", $0) }.joined())")
        print("   接收密钥 (前8字节): \(keys.recvKey.prefix(8).map { String(format: "%02x", $0) }.joined())")
        print("✅ 密钥派生完成")
        
        // 4. 认证
        print("4️⃣ 发送认证质询...")
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        print("   质询 (前8字节): \(challenge.prefix(8).map { String(format: "%02x", $0) }.joined())")
        
        try await ws.send(.data(challenge))
        updateActivity()
        print("✅ 认证质询已发送 (32字节)")
        
        // 5. 验证
        print("5️⃣ 等待认证响应...")
        let authResponse = try await recvBinary()
        print("   收到数据: \(authResponse.count) 字节")
        print("   响应 (前8字节): \(authResponse.prefix(8).map { String(format: "%02x", $0) }.joined())")
        
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        print("   期望 (前8字节): \(expected.prefix(8).map { String(format: "%02x", $0) }.joined())")
        
        guard timingSafeEqual(authResponse, expected) else {
            print("❌ 认证失败: HMAC 不匹配")
            print("   收到: \(authResponse.map { String(format: "%02x", $0) }.joined())")
            print("   期望: \(expected.map { String(format: "%02x", $0) }.joined())")
            throw WebSocketError.authenticationFailed
        }
        updateActivity()
        print("✅ 认证成功")
    }
    
    // MARK: - Send/Receive (简化版本 - 直接调用)
    
    func sendConnect(host: String, port: Int) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let target = "\(host):\(port)"
        let message = "CONNECT \(target)".data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: message)
        
        try await webSocketTask?.send(.data(encrypted))
        updateActivity()
        
        let response = try await recv()
        let responseStr = String(data: response, encoding: .utf8) ?? ""
        
        guard responseStr.starts(with: "OK") else {
            throw WebSocketError.connectionFailed(responseStr)
        }
        updateActivity()
    }
    
    func send(_ data: Data) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let encrypted = try encrypt(key: sendKey, plaintext: data)
        try await webSocketTask?.send(.data(encrypted))
        updateActivity()
    }
    
    func recv() async throws -> Data {
        guard let recvKey = recvKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let encrypted = try await recvBinary()
        updateActivity()
        return try decrypt(key: recvKey, ciphertext: encrypted)
    }
    
    // MARK: - Internal Receive (简化版本 - 直接接收)
    
    private func recvBinary() async throws -> Data {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        print("📥 直接调用 receive()...")
        
        // 设置超时
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let message = try await ws.receive()
                switch message {
                case .data(let data):
                    print("✅ 收到二进制数据: \(data.count) 字节")
                    return data
                case .string(let text):
                    print("✅ 收到文本数据: \(text.count) 字符，转换为二进制")
                    return text.data(using: .utf8) ?? Data()
                @unknown default:
                    throw WebSocketError.invalidFrame
                }
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                print("⏰ 接收超时")
                throw WebSocketError.receiveTimeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    private func recvMessage() async throws -> Data {
        return try await recvBinary()
    }
    
    // MARK: - Close
    
    func close() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sendKey = nil
        recvKey = nil
        messageQueue.removeAll()
    }
    
    // MARK: - Crypto Helpers (内联优化)
    
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

// MARK: - WebSocket Delegate (增强版本)

final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private let sniHost: String
    
    init(sniHost: String) {
        self.sniHost = sniHost
        super.init()
        print("🔧 [Delegate] 初始化，SNI Host: \(sniHost)")
    }
    
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("✅ [Delegate] WebSocket 已打开")
        if let proto = `protocol` {
            print("📋 [Delegate] 协议: \(proto)")
        }
    }
    
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        print("🔴 [Delegate] WebSocket 已关闭，代码: \(closeCode.rawValue)")
        if let reason = reason, let reasonString = String(data: reason, encoding: .utf8) {
            print("📋 [Delegate] 原因: \(reasonString)")
        }
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            print("❌ [Delegate] 任务完成但有错误: \(error.localizedDescription)")
        } else {
            print("✅ [Delegate] 任务正常完成")
        }
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        print("🔐 [Delegate] 收到认证质询: \(challenge.protectionSpace.authenticationMethod)")
        
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            print("🔓 [Delegate] 接受服务器证书（用于自签名证书）")
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        
        print("⚠️ [Delegate] 使用默认处理")
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Errors

enum WebSocketError: Error {
    case notConnected
    case invalidURL
    case invalidServerKey
    case invalidPSK
    case authenticationFailed
    case keysNotEstablished
    case connectionFailed(String)
    case invalidFrame
    case noData
    case receiveTimeout
    
    var localizedDescription: String {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .invalidURL: return "Invalid WebSocket URL"
        case .invalidServerKey: return "Invalid server public key"
        case .invalidPSK: return "Invalid pre-shared key"
        case .authenticationFailed: return "Authentication failed"
        case .keysNotEstablished: return "Encryption keys not established"
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .invalidFrame: return "Invalid WebSocket frame"
        case .noData: return "No data received"
        case .receiveTimeout: return "Receive timeout"
        }
    }
}
