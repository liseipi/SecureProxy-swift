// SecureWebSocket.swift - 支持 Cloudflare CDN 优选 IP
// 最小修改版本：只修复并发问题，保持原有连接方式
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
    private var wsHandshakeComplete = false
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // MARK: - Connection
    
    func connect() async throws {
        // 🔧 判断连接方式
        let useCDN = config.sniHost != config.proxyIP
        
        let actualHost: String
        if useCDN {
            actualHost = config.proxyIP
            print("🌐 使用 CDN 优选 IP: \(config.proxyIP)")
        } else {
            actualHost = config.sniHost
            print("🔗 直连域名: \(config.sniHost)")
        }
        
        // 🔧 使用纯 TLS 连接，不使用 NWProtocolWebSocket
        let tlsOptions = NWProtocolTLS.Options()
        
        // 允许自签名证书
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completion in
                completion(true)
            },
            DispatchQueue.global()
        )
        
        // 设置 SNI (始终使用 sni_host 作为 SNI)
        sec_protocol_options_set_tls_server_name(
            tlsOptions.securityProtocolOptions,
            config.sniHost
        )
        
        // 🔧 关键：只使用 TLS，不添加 WebSocket 协议层
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        
        // 创建连接 (使用 actualHost 作为连接地址)
        let host = NWEndpoint.Host(actualHost)
        let port = NWEndpoint.Port(integerLiteral: UInt16(config.serverPort))
        
        connection = NWConnection(host: host, port: port, using: parameters)
        
        // 等待 TLS 连接建立
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let stateHandler = ConnectionStateHandler(continuation: continuation)
            
            connection?.stateUpdateHandler = { state in
                Task {
                    await stateHandler.handleState(state)
                }
            }
            
            connection?.start(queue: .global())
            
            // 超时处理
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await stateHandler.timeout()
            }
        }
        
        // TLS 连接成功后，执行 WebSocket 握手
        print("✅ TLS 连接就绪")
        try await performWebSocketHandshake()
        
        // WebSocket 握手成功后，执行密钥交换
        try await setupKeys()
        isConnected = true
        startReceiving()
    }
    
    // MARK: - WebSocket Handshake
    
    private func performWebSocketHandshake() async throws {
        print("🤝 开始 WebSocket 握手...")
        
        // 生成 WebSocket Key
        let wsKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        
        // 构建 WebSocket 握手请求 (Host 始终使用 sni_host)
        var request = "GET \(config.path) HTTP/1.1\r\n"
        request += "Host: \(config.sniHost)\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(wsKey)\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        request += "User-Agent: SecureProxy-Swift/2.0\r\n"
        request += "\r\n"
        
        // 发送握手请求
        try await sendRawTCP(request.data(using: .utf8)!)
        
        // 读取握手响应
        let response = try await readHTTPResponse()
        
        // 验证握手响应
        guard response.contains("HTTP/1.1 101") || response.contains("HTTP/1.0 101") else {
            print("❌ WebSocket 握手失败: \(response)")
            throw WebSocketError.handshakeFailed
        }
        
        wsHandshakeComplete = true
        print("✅ WebSocket 握手成功")
    }
    
    private func readHTTPResponse() async throws -> String {
        var buffer = Data()
        
        // 读取直到遇到 \r\n\r\n（HTTP 头结束标志）
        while true {
            let chunk = try await recvRawTCP(maxLength: 1024)
            buffer.append(chunk)
            
            if let str = String(data: buffer, encoding: .utf8),
               str.contains("\r\n\r\n") {
                return str
            }
            
            // 防止无限读取
            if buffer.count > 4096 {
                throw WebSocketError.handshakeFailed
            }
        }
    }
    
    // MARK: - Key Exchange & Authentication
    
    private func setupKeys() async throws {
        guard connection != nil else {
            throw WebSocketError.notConnected
        }
        
        print("🔑 开始密钥交换...")
        
        // 1. 生成并发送客户端公钥
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await sendWebSocketBinary(clientPub)
        
        // 2. 接收服务器公钥
        let serverPub = try await recvWebSocketBinary()
        
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
        try await sendWebSocketBinary(challenge)
        
        // 5. 验证响应
        let authResponse = try await recvWebSocketBinary()
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
        
        try await sendWebSocketBinary(encrypted)
        
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
        try await sendWebSocketBinary(encrypted)
    }
    
    func recv() async throws -> Data {
        guard let recvKey = recvKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        let encrypted = try await recvMessage()
        return try decrypt(key: recvKey, ciphertext: encrypted)
    }
    
    // MARK: - WebSocket Frame Operations
    
    private func sendWebSocketBinary(_ data: Data) async throws {
        // WebSocket 二进制帧格式
        var frame = Data()
        
        // Byte 0: FIN(1) + RSV(3) + Opcode(4) = 10000010 = 0x82
        frame.append(0x82)
        
        // Byte 1: MASK(1) + Payload length(7)
        let length = data.count
        if length < 126 {
            frame.append(UInt8(0x80 | length)) // 客户端必须设置 MASK 位
        } else if length < 65536 {
            frame.append(0xFE) // 126 + MASK
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0xFF) // 127 + MASK
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> i) & 0xFF))
            }
        }
        
        // Masking key (4 bytes)
        let maskKey = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        frame.append(maskKey)
        
        // Masked payload
        var maskedData = Data()
        for (i, byte) in data.enumerated() {
            maskedData.append(byte ^ maskKey[i % 4])
        }
        frame.append(maskedData)
        
        try await sendRawTCP(frame)
    }
    
    private func recvWebSocketBinary() async throws -> Data {
        // 读取帧头（至少 2 字节）
        let header = try await recvRawTCP(exactLength: 2)
        
        let opcode = header[0] & 0x0F
        guard opcode == 0x02 else { // Binary frame
            throw WebSocketError.invalidFrame
        }
        
        let masked = (header[1] & 0x80) != 0
        var payloadLength = Int(header[1] & 0x7F)
        
        // 读取扩展长度
        if payloadLength == 126 {
            let extLen = try await recvRawTCP(exactLength: 2)
            payloadLength = Int(extLen[0]) << 8 | Int(extLen[1])
        } else if payloadLength == 127 {
            let extLen = try await recvRawTCP(exactLength: 8)
            payloadLength = 0
            for byte in extLen {
                payloadLength = (payloadLength << 8) | Int(byte)
            }
        }
        
        // 读取 masking key（如果有）
        var maskKey: Data?
        if masked {
            maskKey = try await recvRawTCP(exactLength: 4)
        }
        
        // 读取 payload
        var payload = try await recvRawTCP(exactLength: payloadLength)
        
        // 解码（如果需要）
        if let mask = maskKey {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }
        
        return payload
    }
    
    // MARK: - Raw TCP Operations
    
    private func sendRawTCP(_ data: Data) async throws {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
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
    
    private func recvRawTCP(exactLength: Int) async throws -> Data {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: exactLength, maximumLength: exactLength) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count == exactLength {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WebSocketError.invalidFrame)
                }
            }
        }
    }
    
    private func recvRawTCP(maxLength: Int) async throws -> Data {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WebSocketError.noData)
                }
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
                    let data = try await recvWebSocketBinary()
                    
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

// MARK: - Connection State Handler

private actor ConnectionStateHandler {
    private var continuation: CheckedContinuation<Void, Error>?
    private var hasCompleted = false
    
    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
    
    func handleState(_ state: NWConnection.State) {
        guard !hasCompleted else { return }
        
        switch state {
        case .ready:
            hasCompleted = true
            continuation?.resume()
            continuation = nil
            
        case .failed(let error):
            print("❌ TLS 连接失败: \(error)")
            hasCompleted = true
            continuation?.resume(throwing: error)
            continuation = nil
            
        case .waiting(let error):
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 53 {
                hasCompleted = true
                continuation?.resume(throwing: error)
                continuation = nil
            }
            
        case .preparing:
            break
        case .setup:
            break
        case .cancelled:
            hasCompleted = true
            continuation?.resume(throwing: WebSocketError.notConnected)
            continuation = nil
        @unknown default:
            break
        }
    }
    
    func timeout() {
        guard !hasCompleted else { return }
        hasCompleted = true
        continuation?.resume(throwing: WebSocketError.connectionTimeout)
        continuation = nil
    }
}

// MARK: - Errors

enum WebSocketError: Error {
    case notConnected
    case handshakeFailed
    case invalidServerKey
    case invalidPSK
    case authenticationFailed
    case keysNotEstablished
    case connectionFailed(String)
    case connectionTimeout
    case invalidFrame
    case noData
    
    var localizedDescription: String {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .handshakeFailed: return "WebSocket handshake failed"
        case .invalidServerKey: return "Invalid server public key"
        case .invalidPSK: return "Invalid pre-shared key"
        case .authenticationFailed: return "Authentication failed"
        case .keysNotEstablished: return "Encryption keys not established"
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .connectionTimeout: return "Connection timeout"
        case .invalidFrame: return "Invalid WebSocket frame"
        case .noData: return "No data received"
        }
    }
}
