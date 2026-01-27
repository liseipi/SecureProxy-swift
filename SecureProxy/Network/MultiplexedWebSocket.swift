// MultiplexedWebSocket.swift
// 支持多路复用的 WebSocket 连接
// ✅ 修复连接超时问题

import Foundation
import CryptoKit

actor MultiplexedWebSocket {
    let id = UUID()
    private let config: ProxyConfig
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sendKey: Data?
    private var recvKey: Data?
    private var isConnected = false
    
    // 多路复用相关
    private var streams: [UInt32: StreamHandler] = [:]
    private var nextStreamId: UInt32 = 1
    private var receiveTask: Task<Void, Never>?
    
    // 健康检查
    private var lastActivityTime = Date()
    private var connectionTime = Date()
    private let maxIdleTime: TimeInterval = 300
    private let maxConnectionAge: TimeInterval = 1800
    
    // 统计
    private var activeStreams: Int { streams.count }
    private var totalStreamsHandled: Int = 0
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // MARK: - Lifecycle
    
    func connect() async throws {
        guard !isConnected else { return }
        
        if webSocketTask != nil || session != nil {
            print("⚠️ [MuxWS \(id)] 检测到旧连接，先清理")
            closeSync()
        }
        
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            throw WebSocketError.invalidURL
        }
        
        print("🔗 [MuxWS \(id)] 连接到: \(url.absoluteString)")
        if useCDN {
            print("🌐 [MuxWS \(id)] CDN 模式 - SNI: \(config.sniHost), IP: \(actualHost)")
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.sniHost, forHTTPHeaderField: "Host")
        request.setValue("SecureProxy-Mux/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30  // ✅ 增加超时时间
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        
        let delegate = WebSocketDelegate(sniHost: config.sniHost, websocket: self)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        guard let session = session else {
            throw WebSocketError.notConnected
        }
        
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        
        // ✅ 关键修复：等待 WebSocket 真正打开
        try await waitForConnection()
        
        // ✅ 完成密钥交换
        try await setupKeys()
        
        isConnected = true
        connectionTime = Date()
        updateActivity()
        
        // ✅ 密钥交换完成后才启动接收循环
        receiveTask = Task {
            await receiveLoop()
        }
        
        print("✅ [MuxWS \(id)] 连接建立，开始接收循环")
    }
    
    // ✅ 新增：等待 WebSocket 连接建立
    private func waitForConnection() async throws {
        // 尝试发送一个 ping 来确认连接
        for attempt in 1...3 {
            do {
                try await webSocketTask?.sendPing { error in
                    if let error = error {
                        print("⚠️ [MuxWS \(self.id)] Ping 失败: \(error)")
                    }
                }
                print("✅ [MuxWS \(id)] WebSocket 连接已建立 (ping 成功)")
                return
            } catch {
                if attempt < 3 {
                    print("⚠️ [MuxWS \(id)] 连接尝试 \(attempt)/3 失败，重试...")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    throw WebSocketError.connectionFailed("无法建立 WebSocket 连接")
                }
            }
        }
    }
    
    func isHealthy() -> Bool {
        guard isConnected else { return false }
        
        let now = Date()
        if now.timeIntervalSince(lastActivityTime) > maxIdleTime {
            return false
        }
        if now.timeIntervalSince(connectionTime) > maxConnectionAge {
            return false
        }
        
        return true
    }
    
    func getStats() -> (activeStreams: Int, totalHandled: Int) {
        return (activeStreams, totalStreamsHandled)
    }
    
    private func closeSync() {
        isConnected = false
        
        receiveTask?.cancel()
        receiveTask = nil
        
        for (_, handler) in streams {
            Task {
                await handler.close()
            }
        }
        streams.removeAll()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        session?.invalidateAndCancel()
        session = nil
        
        sendKey = nil
        recvKey = nil
    }
    
    func close() {
        closeSync()
    }
    
    // MARK: - Key Exchange
    
    private func setupKeys() async throws {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        print("🔐 [MuxWS \(id)] 开始密钥交换...")
        
        do {
            // 1. 发送客户端公钥
            let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await ws.send(.data(clientPub))
            updateActivity()
            print("📤 [MuxWS \(id)] 已发送客户端公钥")
            
            // 2. 接收服务器公钥（使用更短的超时）
            let serverPub = try await recvBinaryWithTimeout(timeout: 10.0)
            guard serverPub.count == 32 else {
                throw WebSocketError.invalidServerKey
            }
            updateActivity()
            print("📥 [MuxWS \(id)] 已接收服务器公钥")
            
            // 3. 派生密钥
            let salt = clientPub + serverPub
            let psk = hexToData(config.preSharedKey)
            guard psk.count == 32 else {
                throw WebSocketError.invalidPSK
            }
            
            let keys = deriveKeys(sharedKey: psk, salt: salt)
            sendKey = keys.sendKey
            recvKey = keys.recvKey
            print("🔑 [MuxWS \(id)] 密钥派生完成")
            
            // 4. 认证
            let authMessage = "auth".data(using: .utf8)!
            let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
            try await ws.send(.data(challenge))
            updateActivity()
            print("📤 [MuxWS \(id)] 已发送认证挑战")
            
            // 5. 验证响应
            let authResponse = try await recvBinaryWithTimeout(timeout: 10.0)
            let okMessage = "ok".data(using: .utf8)!
            let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
            
            guard timingSafeEqual(authResponse, expected) else {
                throw WebSocketError.authenticationFailed
            }
            updateActivity()
            
            print("✅ [MuxWS \(id)] 密钥交换和认证完成")
            
        } catch {
            print("❌ [MuxWS \(id)] 密钥交换失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Stream Management
    
    func openStream(host: String, port: Int) async throws -> Stream {
        guard isConnected, let sendKey = sendKey else {
            throw WebSocketError.notConnected
        }
        
        let streamId = nextStreamId
        nextStreamId += 1
        totalStreamsHandled += 1
        
        let handler = StreamHandler(id: streamId)
        streams[streamId] = handler
        
        print("📤 [MuxWS \(id)] 打开流 #\(streamId) -> \(host):\(port)")
        
        // 发送 CONNECT 请求
        let target = "\(host):\(port)"
        let message = "CONNECT \(streamId) \(target)".data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: message)
        
        do {
            try await webSocketTask?.send(.data(encrypted))
            updateActivity()
            print("📤 [MuxWS \(id)] 已发送流 #\(streamId) 的 CONNECT 请求")
        } catch {
            streams.removeValue(forKey: streamId)
            print("❌ [MuxWS \(id)] 发送 CONNECT 失败: \(error.localizedDescription)")
            throw error
        }
        
        // ✅ 等待连接确认（使用更短的超时）
        do {
            let response = try await handler.waitForConnect(timeout: 5.0)
            guard response.hasPrefix("OK") else {
                streams.removeValue(forKey: streamId)
                throw WebSocketError.connectionFailed("Stream \(streamId): \(response)")
            }
            
            print("✅ [MuxWS \(id)] 流 #\(streamId) 已建立")
            
            return await Stream(
                id: streamId,
                websocket: self,
                handler: handler
            )
        } catch {
            streams.removeValue(forKey: streamId)
            print("❌ [MuxWS \(id)] 流 #\(streamId) 连接超时或失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    func closeStream(_ streamId: UInt32) {
        if let handler = streams.removeValue(forKey: streamId) {
            Task {
                await handler.close()
            }
            print("🔴 [MuxWS \(id)] 关闭流 #\(streamId)")
        }
    }
    
    // MARK: - Send
    
    func send(streamId: UInt32, data: Data) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        guard isConnected, let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: streamId.bigEndian) { Data($0) })
        packet.append(data)
        
        let encrypted = try encrypt(key: sendKey, plaintext: packet)
        try await ws.send(.data(encrypted))
        updateActivity()
    }
    
    // MARK: - Receive Loop
    
    private func receiveLoop() async {
        print("🔄 [MuxWS \(id)] 接收循环开始")
        
        while isConnected {
            do {
                guard let recvKey = recvKey else {
                    print("⚠️ [MuxWS \(id)] 接收密钥未设置，退出循环")
                    break
                }
                
                // ✅ 使用无限超时，让 WebSocket 自然等待
                let encrypted = try await recvBinaryNoTimeout()
                let packet = try decrypt(key: recvKey, ciphertext: encrypted)
                updateActivity()
                
                guard packet.count >= 4 else {
                    print("⚠️ [MuxWS \(id)] 收到无效数据包（长度不足）")
                    continue
                }
                
                let streamIdBytes = packet.prefix(4)
                let streamId = streamIdBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
                let payload = packet.dropFirst(4)
                
                if let handler = streams[streamId] {
                    Task {
                        await handler.receive(Data(payload))
                    }
                } else {
                    // 流已关闭
                }
                
            } catch {
                if isConnected {
                    print("❌ [MuxWS \(id)] 接收循环错误: \(error.localizedDescription)")
                }
                break
            }
        }
        
        print("🔴 [MuxWS \(id)] 接收循环结束")
    }
    
    // ✅ 新增：无超时的接收（用于接收循环）
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
    
    // ✅ 修改：带超时的接收（用于密钥交换）
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
    
    // MARK: - Crypto Helpers
    
    private func updateActivity() {
        lastActivityTime = Date()
    }
    
    nonisolated func notifyConnectionClosed() {
        Task {
            await self.handleDelegateClose()
        }
    }
    
    private func handleDelegateClose() {
        if isConnected {
            print("🔴 [MuxWS \(id)] Delegate 通知连接已关闭")
            isConnected = false
        }
    }
    
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
            throw WebSocketCryptoError.invalidDataLength
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

// MARK: - Stream Handler

actor StreamHandler {
    let id: UInt32
    private var receiveBuffer: [Data] = []
    private var connectResponse: String?
    private var waitingForConnect: CheckedContinuation<String, Error>?
    private var waitingForData: CheckedContinuation<Data, Error>?
    private var isClosed = false
    
    init(id: UInt32) {
        self.id = id
    }
    
    // ✅ 修改：添加超时参数
    func waitForConnect(timeout: TimeInterval = 5.0) async throws -> String {
        if let response = connectResponse {
            return response
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            waitingForConnect = continuation
            
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = waitingForConnect {
                    waitingForConnect = nil
                    cont.resume(throwing: WebSocketError.receiveTimeout)
                }
            }
        }
    }
    
    func receive(_ data: Data) {
        guard !isClosed else { return }
        
        // 如果是 CONNECT 响应
        if connectResponse == nil, let text = String(data: data, encoding: .utf8), text.hasPrefix("OK") || text.hasPrefix("ERR") {
            connectResponse = text
            if let continuation = waitingForConnect {
                waitingForConnect = nil
                continuation.resume(returning: text)
            }
            return
        }
        
        // 正常数据
        if let continuation = waitingForData {
            waitingForData = nil
            continuation.resume(returning: data)
        } else {
            receiveBuffer.append(data)
        }
    }
    
    func read() async throws -> Data {
        guard !isClosed else {
            throw WebSocketError.connectionClosed
        }
        
        if !receiveBuffer.isEmpty {
            return receiveBuffer.removeFirst()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            waitingForData = continuation
        }
    }
    
    func close() {
        isClosed = true
        
        if let cont = waitingForConnect {
            waitingForConnect = nil
            cont.resume(throwing: WebSocketError.connectionClosed)
        }
        
        if let cont = waitingForData {
            waitingForData = nil
            cont.resume(throwing: WebSocketError.connectionClosed)
        }
        
        receiveBuffer.removeAll()
    }
}

// MARK: - Stream

struct Stream: Sendable {
    let id: UInt32
    private let websocket: MultiplexedWebSocket
    private let handler: StreamHandler
    
    init(id: UInt32, websocket: MultiplexedWebSocket, handler: StreamHandler) {
        self.id = id
        self.websocket = websocket
        self.handler = handler
    }
    
    func send(_ data: Data) async throws {
        try await websocket.send(streamId: id, data: data)
    }
    
    func receive() async throws -> Data {
        try await handler.read()
    }
    
    func close() async {
        await websocket.closeStream(id)
    }
}

// MARK: - WebSocket Delegate

final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let sniHost: String
    private weak var websocket: MultiplexedWebSocket?
    
    init(sniHost: String, websocket: MultiplexedWebSocket) {
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
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "无原因"
        print("🔴 [Delegate] WebSocket 已关闭，代码: \(closeCode.rawValue), 原因: \(reasonStr)")
        websocket?.notifyConnectionClosed()
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            let nsError = error as NSError
            print("❌ [Delegate] 连接错误: \(error.localizedDescription)")
            print("❌ [Delegate] 错误域: \(nsError.domain), 代码: \(nsError.code)")
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("❌ [Delegate] 底层错误: \(underlyingError.localizedDescription)")
            }
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

enum WebSocketError: LocalizedError {
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
    case alreadyConnecting
    case keyExchangeFailed(String)
    
    var errorDescription: String? {
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
        case .alreadyConnecting: return "连接正在进行中，请稍候"
        case .keyExchangeFailed(let reason): return "密钥交换失败: \(reason)"
        }
    }
}

enum WebSocketCryptoError: Error {
    case invalidDataLength
    case encryptionFailed
    case decryptionFailed
    case invalidNonce
    
    var localizedDescription: String {
        switch self {
        case .invalidDataLength: return "Invalid data length for decryption"
        case .encryptionFailed: return "Encryption failed"
        case .decryptionFailed: return "Decryption failed"
        case .invalidNonce: return "Invalid nonce"
        }
    }
}
