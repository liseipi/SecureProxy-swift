// SecureWebSocket.swift - 高性能版本
// 使用 URLSessionWebSocketTask 获得与 Node.js ws 库相同的性能
import Foundation
import CryptoKit

actor SecureWebSocket {
    private let config: ProxyConfig
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sendKey: Data?
    private var recvKey: Data?
    private var isConnected = false
    private var messageQueue: [Data] = []
    private var messageContinuation: CheckedContinuation<Data, Error>?
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // MARK: - Connection
    
    func connect() async throws {
        // 判断连接方式
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        if useCDN {
            print("🌐 CDN 模式: \(config.proxyIP) -> \(config.sniHost)")
        } else {
            print("🔗 直连模式: \(config.sniHost)")
        }
        
        // 构建 WebSocket URL
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            throw WebSocketError.invalidURL
        }
        
        // 创建 URLRequest
        var request = URLRequest(url: url)
        request.setValue(config.sniHost, forHTTPHeaderField: "Host")
        request.setValue("SecureProxy-Swift/3.2", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Protocol-Version")
        request.timeoutInterval = 10
        
        // 配置 URLSession（支持自签名证书）
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 300
        
        let delegate = WebSocketDelegate(sniHost: config.sniHost)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        // 创建 WebSocket Task
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        print("✅ WebSocket 连接中...")
        
        // 等待连接就绪（通过发送第一个消息来验证）
        try await setupKeys()
        
        isConnected = true
        startReceiving()
        print("✅ 连接成功")
    }
    
    // MARK: - Key Exchange & Authentication
    
    private func setupKeys() async throws {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        print("🔑 密钥交换...")
        
        // 1. 生成并发送客户端公钥
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await ws.send(.data(clientPub))
        
        // 2. 接收服务器公钥
        let serverPub = try await recvBinary()
        guard serverPub.count == 32 else {
            throw WebSocketError.invalidServerKey
        }
        
        // 3. 密钥派生
        let salt = clientPub + serverPub
        let psk = hexToData(config.preSharedKey)
        guard psk.count == 32 else {
            throw WebSocketError.invalidPSK
        }
        
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        print("🔐 密钥派生完成")
        
        // 4. 发送认证
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        try await ws.send(.data(challenge))
        
        // 5. 验证响应
        let authResponse = try await recvBinary()
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        
        guard timingSafeEqual(authResponse, expected) else {
            throw WebSocketError.authenticationFailed
        }
        print("✅ 认证成功")
    }
    
    // MARK: - Send/Receive
    
    func sendConnect(host: String, port: Int) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let target = "\(host):\(port)"
        let message = "CONNECT \(target)".data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: message)
        
        try await webSocketTask?.send(.data(encrypted))
        
        let response = try await recv()
        let responseStr = String(data: response, encoding: .utf8) ?? ""
        
        guard responseStr.starts(with: "OK") else {
            throw WebSocketError.connectionFailed(responseStr)
        }
    }
    
    func send(_ data: Data) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let encrypted = try encrypt(key: sendKey, plaintext: data)
        try await webSocketTask?.send(.data(encrypted))
    }
    
    func recv() async throws -> Data {
        guard let recvKey = recvKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let encrypted = try await recvMessage()
        return try decrypt(key: recvKey, ciphertext: encrypted)
    }
    
    // MARK: - Internal Receive
    
    private func recvBinary() async throws -> Data {
        let message = try await recvMessage()
        return message
    }
    
    private func recvMessage() async throws -> Data {
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            messageContinuation = continuation
        }
    }
    
    private func startReceiving() {
        Task {
            guard let ws = webSocketTask else { return }
            
            while isConnected {
                do {
                    let message = try await ws.receive()
                    
                    switch message {
                    case .data(let data):
                        if let continuation = messageContinuation {
                            continuation.resume(returning: data)
                            messageContinuation = nil
                        } else {
                            messageQueue.append(data)
                        }
                        
                    case .string(let text):
                        // 转换为 Data
                        if let data = text.data(using: .utf8) {
                            if let continuation = messageContinuation {
                                continuation.resume(returning: data)
                                messageContinuation = nil
                            } else {
                                messageQueue.append(data)
                            }
                        }
                        
                    @unknown default:
                        break
                    }
                } catch {
                    if let continuation = messageContinuation {
                        continuation.resume(throwing: error)
                        messageContinuation = nil
                    }
                    break
                }
            }
        }
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
    
    // MARK: - Crypto Helpers
    
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
    
    private func encrypt(key: Data, plaintext: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        
        var result = Data()
        result.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }
    
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
    
    private func hmacSHA256(key: Data, message: Data) -> Data {
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(hmac)
    }
    
    private func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var result: UInt8 = 0
        for i in 0..<lhs.count {
            result |= lhs[i] ^ rhs[i]
        }
        return result == 0
    }
    
    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var hex = hex
        while !hex.isEmpty {
            let subIndex = hex.index(hex.startIndex, offsetBy: min(2, hex.count))
            if let byte = UInt8(String(hex[..<subIndex]), radix: 16) {
                data.append(byte)
            }
            hex = String(hex[subIndex...])
        }
        return data
    }
}

// MARK: - URLSession Delegate

final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private let sniHost: String
    
    init(sniHost: String) {
        self.sniHost = sniHost
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // 接受自签名证书
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
    case invalidURL
    case invalidServerKey
    case invalidPSK
    case authenticationFailed
    case keysNotEstablished
    case connectionFailed(String)
    case invalidFrame
    case noData
    
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
        }
    }
}
