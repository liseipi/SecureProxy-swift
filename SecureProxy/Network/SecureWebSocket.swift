// SecureWebSocket.swift
// 修复版本 - 增强稳定性和错误处理

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
    private var isConnecting = false  // 🔧 新增：防止重复连接
    private var connectionAttempts = 0  // 🔧 新增：连接尝试次数
    
    // 健康检查相关
    private var lastActivityTime = Date()
    private var connectionTime = Date()
    private let maxIdleTime: TimeInterval = 300  // 🔧 修改：从 120s 增加到 300s
    private let maxConnectionAge: TimeInterval = 1800  // 🔧 修改：从 600s 增加到 1800s
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // 🔧 nonisolated 方法供 delegate 调用
    nonisolated func notifyConnectionClosed() {
        Task {
            await self.handleDelegateClose()
        }
    }
    
    // 🔧 优化：更宽松的健康检查
    func isHealthy() -> Bool {
        guard isConnected, !isConnecting else {
            return false
        }
        
        guard let task = webSocketTask, session != nil else {
            return false
        }
        
        // 检查 WebSocket 状态
        switch task.state {
        case .running:
            break
        case .suspended, .canceling, .completed:
            return false
        @unknown default:
            return false
        }
        
        let now = Date()
        
        // 🔧 修改：只在超过限制时返回 false，不记录日志避免噪音
        if now.timeIntervalSince(lastActivityTime) > maxIdleTime {
            return false
        }
        
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
        // 🔧 防止重复连接
        guard !isConnecting else {
            print("⚠️ [WebSocket \(id)] 正在连接中，跳过重复请求")
            throw WebSocketError.alreadyConnecting
        }
        
        isConnecting = true
        connectionAttempts += 1
        
        // 先确保完全关闭旧连接
        if isConnected || webSocketTask != nil || session != nil {
            print("⚠️ [WebSocket \(id)] 检测到旧连接，先关闭")
            await forceClose()
        }
        
        let useCDN = config.sniHost != config.proxyIP
        let actualHost = useCDN ? config.proxyIP : config.sniHost
        
        guard let url = URL(string: "wss://\(actualHost):\(config.serverPort)\(config.path)") else {
            isConnecting = false
            throw WebSocketError.invalidURL
        }
        
        print("🔗 [WebSocket \(id)] 连接尝试 #\(connectionAttempts)")
        print("🔗 [WebSocket \(id)] 目标: \(url.absoluteString)")
        if useCDN {
            print("🌐 [WebSocket \(id)] CDN 模式 - SNI: \(config.sniHost), IP: \(config.proxyIP)")
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.sniHost, forHTTPHeaderField: "Host")
        request.setValue("SecureProxy-Swift/3.3", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Protocol-Version")
        request.timeoutInterval = 15  // 🔧 增加超时时间
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true  // 🔧 新增：等待网络可用
        
        let delegate = WebSocketDelegate(sniHost: config.sniHost, websocket: self)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        
        guard let session = session else {
            isConnecting = false
            throw WebSocketError.notConnected
        }
        
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        
        print("🔗 [WebSocket \(id)] 任务已启动，等待握手...")
        
        do {
            try await setupKeys()
            
            isConnected = true
            isConnecting = false
            connectionTime = Date()
            updateActivity()
            connectionAttempts = 0  // 🔧 重置连接尝试次数
            
            print("✅ [WebSocket \(id)] 连接建立成功")
        } catch {
            isConnecting = false
            isConnected = false
            print("❌ [WebSocket \(id)] 连接失败: \(error.localizedDescription)")
            
            // 清理失败的连接
            await forceClose()
            throw error
        }
    }
    
    // 处理 delegate 的关闭回调
    private func handleDelegateClose() {
        if isConnected {
            print("🔴 [WebSocket \(id)] Delegate 通知连接已关闭")
            isConnected = false
            isConnecting = false
        }
    }
    
    // MARK: - Key Exchange
    
    private func setupKeys() async throws {
        guard let ws = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        print("🔐 [WebSocket \(id)] 开始密钥交换...")
        
        // 1. 客户端公钥
        let clientPub = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        do {
            try await ws.send(.data(clientPub))
            updateActivity()
            print("📤 [WebSocket \(id)] 已发送客户端公钥")
        } catch {
            print("❌ [WebSocket \(id)] 发送客户端公钥失败: \(error)")
            throw WebSocketError.keyExchangeFailed("发送客户端公钥失败")
        }
        
        // 2. 服务器公钥
        let serverPub: Data
        do {
            serverPub = try await recvBinary()
            guard serverPub.count == 32 else {
                throw WebSocketError.invalidServerKey
            }
            updateActivity()
            print("📥 [WebSocket \(id)] 已接收服务器公钥")
        } catch {
            print("❌ [WebSocket \(id)] 接收服务器公钥失败: \(error)")
            throw WebSocketError.keyExchangeFailed("接收服务器公钥失败")
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
        print("🔑 [WebSocket \(id)] 密钥派生完成")
        
        // 4. 认证
        let authMessage = "auth".data(using: .utf8)!
        let challenge = hmacSHA256(key: keys.sendKey, message: authMessage)
        do {
            try await ws.send(.data(challenge))
            updateActivity()
            print("📤 [WebSocket \(id)] 已发送认证挑战")
        } catch {
            print("❌ [WebSocket \(id)] 发送认证挑战失败: \(error)")
            throw WebSocketError.authenticationFailed
        }
        
        // 5. 验证
        let authResponse: Data
        do {
            authResponse = try await recvBinary()
            print("📥 [WebSocket \(id)] 已接收认证响应")
        } catch {
            print("❌ [WebSocket \(id)] 接收认证响应失败: \(error)")
            throw WebSocketError.authenticationFailed
        }
        
        let okMessage = "ok".data(using: .utf8)!
        let expected = hmacSHA256(key: keys.recvKey, message: okMessage)
        
        guard timingSafeEqual(authResponse, expected) else {
            print("❌ [WebSocket \(id)] 认证失败：响应不匹配")
            throw WebSocketError.authenticationFailed
        }
        updateActivity()
        
        print("✅ [WebSocket \(id)] 认证成功")
    }
    
    // MARK: - Send/Receive
    
    func sendConnect(host: String, port: Int) async throws {
        guard let sendKey = sendKey else {
            let error = WebSocketError.keysNotEstablished
            print("❌ [WebSocket \(id)] sendConnect 失败: \(error.errorDescription ?? "未知错误")")
            throw error
        }
        
        guard let task = webSocketTask, isConnected else {
            let error = WebSocketError.notConnected
            print("❌ [WebSocket \(id)] sendConnect 失败: \(error.errorDescription ?? "未知错误")")
            throw error
        }
        
        let target = "\(host):\(port)"
        print("📤 [WebSocket \(id)] 发送 CONNECT 请求: \(target)")
        
        let message = "CONNECT \(target)".data(using: .utf8)!
        let encrypted = try encrypt(key: sendKey, plaintext: message)
        
        do {
            try await task.send(.data(encrypted))
            updateActivity()
            print("✅ [WebSocket \(id)] CONNECT 请求已发送")
        } catch {
            isConnected = false
            print("❌ [WebSocket \(id)] 发送 CONNECT 失败: \(error.localizedDescription)")
            throw error
        }
        
        print("⏳ [WebSocket \(id)] 等待服务器响应...")
        let response: Data
        do {
            response = try await recv()
        } catch {
            // 🔧 关键修复：接收失败时标记连接为不可用
            isConnected = false
            print("❌ [WebSocket \(id)] 接收响应失败: \(error.localizedDescription)")
            throw error
        }
        
        let responseStr = String(data: response, encoding: .utf8) ?? ""
        print("📥 [WebSocket \(id)] 服务器响应: \(responseStr.isEmpty ? "(空)" : responseStr)")
        
        guard !responseStr.isEmpty && responseStr.starts(with: "OK") else {
            // 🔧 关键修复：CONNECT 失败时立即标记连接不可用
            isConnected = false
            let error = WebSocketError.connectionFailed(responseStr.isEmpty ? "服务器无响应" : "服务器拒绝: \(responseStr)")
            print("❌ [WebSocket \(id)] CONNECT 失败: \(error.errorDescription ?? "未知错误")")
            print("🔴 [WebSocket \(id)] 连接已标记为不可用")
            throw error
        }
        
        updateActivity()
        print("✅ [WebSocket \(id)] CONNECT 成功: \(target)")
    }
    
    func send(_ data: Data) async throws {
        guard let sendKey = sendKey else {
            throw WebSocketError.keysNotEstablished
        }
        
        guard let task = webSocketTask, isConnected else {
            throw WebSocketError.notConnected
        }
        
        let encrypted = try encrypt(key: sendKey, plaintext: data)
        
        do {
            try await task.send(.data(encrypted))
            updateActivity()
        } catch {
            isConnected = false
            print("⚠️ [WebSocket \(id)] 发送数据失败: \(error)")
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
            isConnected = false
            print("⚠️ [WebSocket \(id)] 接收数据失败: \(error)")
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
                try await Task.sleep(nanoseconds: 20_000_000_000)  // 🔧 增加到 20s
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
        isConnecting = false
        
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
        
        lastActivityTime = Date()
        connectionTime = Date()
    }
    
    private func forceClose() async {
        close()
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
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
        case .receiveTimeout: return "接收超时 (20秒)"
        case .alreadyConnecting: return "连接正在进行中，请稍候"
        case .keyExchangeFailed(let reason): return "密钥交换失败: \(reason)"
        }
    }
}
