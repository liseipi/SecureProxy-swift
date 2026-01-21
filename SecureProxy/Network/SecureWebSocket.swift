// SecureWebSocket.swift - 修复版
import Foundation
import Network
import CryptoKit

actor SecureWebSocket {
    private let config: ProxyConfig
    private var connection: NWConnection?
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
        let host = NWEndpoint.Host(config.sniHost)
        let port = NWEndpoint.Port(integerLiteral: UInt16(config.serverPort))
        
        // 配置 TLS
        let tlsOptions = NWProtocolTLS.Options()
        
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completion in
                completion(true)
            },
            DispatchQueue.global()
        )
        
        sec_protocol_options_set_tls_server_name(
            tlsOptions.securityProtocolOptions,
            config.sniHost
        )
        
        // 🔧 修复：正确配置 WebSocket
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        
        // 设置 WebSocket 路径
        wsOptions.setAdditionalHeaders([
            ("Host", config.sniHost),
            ("User-Agent", "SecureProxy-Swift/2.0"),
            ("Upgrade", "websocket"),
            ("Connection", "Upgrade")
        ])
        
        // 🔧 修复：创建正确的参数配置
        let parameters = NWParameters(tls: tlsOptions)
        
        // 🔧 修复：正确的方式添加 WebSocket 协议
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        
        // 设置 WebSocket 请求路径
        if !config.path.isEmpty {
            // 构造完整的 WebSocket URL
            let urlString = "wss://\(config.sniHost):\(config.serverPort)\(config.path)"
            if let url = URL(string: urlString) {
                websocketOptions.setAdditionalHeaders([
                    ("Host", config.sniHost),
                    ("Origin", "https://\(config.sniHost)"),
                    ("User-Agent", "SecureProxy-Swift/2.0")
                ])
            }
        }
        
        // 添加 WebSocket 到协议栈
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)
        
        // 创建连接
        connection = NWConnection(host: host, port: port, using: parameters)
        
        // 启动连接
        return try await withCheckedThrowingContinuation { continuation in
            connection?.stateUpdateHandler = { [weak self] state in
                Task {
                    await self?.handleConnectionState(state, continuation: continuation)
                }
            }
            
            connection?.start(queue: .global())
        }
    }
    
    private func handleConnectionState(
        _ state: NWConnection.State,
        continuation: CheckedContinuation<Void, Error>
    ) {
        switch state {
        case .ready:
            print("✅ WebSocket 连接就绪")
            Task {
                do {
                    try await setupKeys()
                    isConnected = true
                    continuation.resume()
                    startReceiving()
                } catch {
                    print("❌ 密钥交换失败: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            
        case .failed(let error):
            print("❌ WebSocket 连接失败: \(error)")
            continuation.resume(throwing: error)
            
        case .waiting(let error):
            print("⚠️ WebSocket 等待中: \(error)")
            // 不要在 waiting 状态终止，继续等待
            
        case .preparing:
            print("🔄 WebSocket 准备中...")
            
        case .setup:
            print("🔧 WebSocket 设置中...")
            
        case .cancelled:
            print("🛑 WebSocket 已取消")
            continuation.resume(throwing: WebSocketError.notConnected)
            
        @unknown default:
            print("⚠️ 未知状态: \(state)")
        }
    }
    
    // MARK: - Key Exchange & Authentication
    
    private func setupKeys() async throws {
        guard connection != nil else {
            throw WebSocketError.notConnected
        }
        
        print("🔑 开始密钥交换...")
        
        // 1. 生成客户端公钥
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await sendRaw(clientPub)
        print("📤 已发送客户端公钥")
        
        // 2. 接收服务器公钥
        let serverPub = try await recvRaw()
        guard serverPub.count == 32 else {
            throw WebSocketError.invalidServerKey
        }
        print("📥 已接收服务器公钥")
        
        // 3. 派生密钥
        let salt = clientPub + serverPub
        let psk = hexToData(config.preSharedKey)
        let keys = deriveKeys(sharedKey: psk, salt: salt)
        
        sendKey = keys.sendKey
        recvKey = keys.recvKey
        print("🔐 密钥派生完成")
        
        // 4. 认证
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        try await sendRaw(challenge)
        print("📤 已发送认证请求")
        
        // 5. 验证响应
        let authResponse = try await recvRaw()
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
        
        try await sendRaw(encrypted)
        
        // 接收响应
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
        try await sendRaw(encrypted)
    }
    
    func recv() async throws -> Data {
        guard let recvKey = recvKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let encrypted = try await recvMessage()
        return try decrypt(key: recvKey, ciphertext: encrypted)
    }
    
    // MARK: - Raw WebSocket Operations
    
    private func sendRaw(_ data: Data) async throws {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "WebSocket",
            metadata: [metadata]
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
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
    
    private func recvRaw() async throws -> Data {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, context, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = content else {
                    continuation.resume(throwing: WebSocketError.noData)
                    return
                }
                
                continuation.resume(returning: data)
            }
        }
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
            while isConnected {
                do {
                    let data = try await recvRaw()
                    
                    if let continuation = messageContinuation {
                        continuation.resume(returning: data)
                        messageContinuation = nil
                    } else {
                        messageQueue.append(data)
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
        connection?.cancel()
        connection = nil
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
        let sendKey = keyData.prefix(32)
        let recvKey = keyData.suffix(32)
        
        return (Data(sendKey), Data(recvKey))
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
        
        let nonceData = ciphertext.prefix(12)
        let tag = ciphertext.suffix(16)
        let ciphertextData = ciphertext.dropFirst(12).dropLast(16)
        
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertextData,
            tag: tag
        )
        
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
    private func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
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
            let substring = hex[..<subIndex]
            
            if let byte = UInt8(substring, radix: 16) {
                data.append(byte)
            }
            
            hex = String(hex[subIndex...])
        }
        
        return data
    }
}

// MARK: - Errors

enum WebSocketError: Error {
    case notConnected
    case invalidServerKey
    case authenticationFailed
    case keysNotEstablished
    case connectionFailed(String)
    case noData
    
    var localizedDescription: String {
        switch self {
        case .notConnected:
            return "WebSocket not connected"
        case .invalidServerKey:
            return "Invalid server public key"
        case .authenticationFailed:
            return "Authentication failed"
        case .keysNotEstablished:
            return "Encryption keys not established"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .noData:
            return "No data received"
        }
    }
}
