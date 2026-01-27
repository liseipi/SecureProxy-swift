// MultiplexedConnectionManager.swift
// 管理多路复用 WebSocket 连接池
// 每个 WebSocket 可以处理多个并发请求

import Foundation

actor MultiplexedConnectionManager {
    private let config: ProxyConfig
    private var pool: [MultiplexedWebSocket] = []
    private let maxPoolSize: Int
    private let minPoolSize: Int
    private var isCleaningUp = false
    
    // 统计
    private var totalStreamsCreated = 0
    private var totalConnectionsCreated = 0
    
    init(config: ProxyConfig, minPoolSize: Int = 2, maxPoolSize: Int = 5) {
        self.config = config
        self.minPoolSize = minPoolSize
        self.maxPoolSize = maxPoolSize
    }
    
    // MARK: - Lifecycle
    
    func warmup() async throws {
        print("🔥 [MuxPool] 预热连接池（多路复用模式）...")
        
        await cleanup()
        
        var successCount = 0
        
        for i in 0..<minPoolSize {
            do {
                print("🔗 [MuxPool] 创建连接 \(i + 1)/\(minPoolSize)...")
                let ws = try await createConnection()
                pool.append(ws)
                successCount += 1
                print("✅ [MuxPool] 连接 \(i + 1) 创建成功")
            } catch {
                print("❌ [MuxPool] 连接 \(i + 1) 创建失败: \(error.localizedDescription)")
            }
        }
        
        if successCount == 0 {
            throw ConnectionError.warmupFailed("无法创建任何连接")
        }
        
        print("✅ [MuxPool] 预热完成: 成功 \(successCount) 个连接")
        print("ℹ️  [MuxPool] 每个连接支持多路复用，无需为每个请求创建新连接")
    }
    
    private func createConnection() async throws -> MultiplexedWebSocket {
        let maxRetries = 3
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let ws = MultiplexedWebSocket(config: config)
                try await ws.connect()
                totalConnectionsCreated += 1
                return ws
            } catch {
                lastError = error
                print("⚠️ [MuxPool] 连接尝试 \(attempt)/\(maxRetries) 失败: \(error.localizedDescription)")
                
                if attempt < maxRetries {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        
        throw lastError ?? ConnectionError.creationFailed
    }
    
    // MARK: - Stream Management (核心方法)
    
    /// 打开一个新的数据流（不需要占用整个连接）
    func openStream(host: String, port: Int) async throws -> Stream {
        guard !isCleaningUp else {
            throw ConnectionError.poolClosed
        }
        
        totalStreamsCreated += 1
        
        // 1. 尝试从现有连接中找一个健康的
        for ws in pool {
            if await ws.isHealthy() {
                do {
                    let stream = try await ws.openStream(host: host, port: port)
                    return stream
                } catch {
                    print("⚠️ [MuxPool] 在连接 \(ws.id) 上打开流失败: \(error.localizedDescription)")
                    continue
                }
            }
        }
        
        // 2. 清理不健康的连接
        await removeUnhealthyConnections()
        
        // 3. 如果池未满，创建新连接
        if pool.count < maxPoolSize {
            print("🆕 [MuxPool] 创建新连接 (当前: \(pool.count)/\(maxPoolSize))")
            do {
                let ws = try await createConnection()
                pool.append(ws)
                let stream = try await ws.openStream(host: host, port: port)
                return stream
            } catch {
                print("❌ [MuxPool] 新连接创建失败: \(error.localizedDescription)")
                throw error
            }
        }
        
        // 4. 池已满，尝试在最空闲的连接上打开流
        if let ws = await findLeastLoadedConnection() {
            print("♻️ [MuxPool] 复用最空闲的连接 \(ws.id)")
            do {
                let stream = try await ws.openStream(host: host, port: port)
                return stream
            } catch {
                print("❌ [MuxPool] 在最空闲连接上打开流失败: \(error.localizedDescription)")
                throw error
            }
        }
        
        throw ConnectionError.poolExhausted
    }
    
    private func findLeastLoadedConnection() async -> MultiplexedWebSocket? {
        var leastLoaded: MultiplexedWebSocket?
        var minStreams = Int.max
        
        for ws in pool {
            if await ws.isHealthy() {
                let stats = await ws.getStats()
                if stats.activeStreams < minStreams {
                    minStreams = stats.activeStreams
                    leastLoaded = ws
                }
            }
        }
        
        return leastLoaded
    }
    
    private func removeUnhealthyConnections() async {
        var toRemove: [UUID] = []
        
        for ws in pool {
            if await !ws.isHealthy() {
                toRemove.append(ws.id)
                await ws.close()
            }
        }
        
        if !toRemove.isEmpty {
            pool.removeAll { toRemove.contains($0.id) }
            print("🧹 [MuxPool] 移除 \(toRemove.count) 个不健康连接，剩余 \(pool.count)")
        }
    }
    
    // MARK: - Cleanup
    
    func cleanup() async {
        guard !isCleaningUp else { return }
        
        isCleaningUp = true
        
        print("🧹 [MuxPool] 开始清理连接池...")
        
        for ws in pool {
            await ws.close()
        }
        
        pool.removeAll()
        
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        isCleaningUp = false
        
        print("✅ [MuxPool] 连接池已清理")
    }
    
    func rebuild() async throws {
        print("🔄 [MuxPool] 重建连接池...")
        await cleanup()
        
        totalStreamsCreated = 0
        totalConnectionsCreated = 0
        
        try await warmup()
        print("✅ [MuxPool] 连接池重建完成")
    }
    
    // MARK: - Stats
    
    func getStats() async -> (poolSize: Int, totalStreams: Int, totalConnections: Int) {
        var totalActiveStreams = 0
        
        for ws in pool {
            let stats = await ws.getStats()
            totalActiveStreams += stats.activeStreams
        }
        
        return (pool.count, totalActiveStreams, totalConnectionsCreated)
    }
    
    func printStats() async {
        let stats = await getStats()
        print("📊 [MuxPool] 连接数: \(stats.poolSize), 活跃流: \(stats.totalStreams), 总创建: \(stats.totalConnections)")
        
        for ws in pool {
            let wsStats = await ws.getStats()
            print("   └─ WS \(ws.id): \(wsStats.activeStreams) 活跃流, \(wsStats.totalHandled) 总处理")
        }
    }
}

// MARK: - Errors

enum ConnectionError: LocalizedError {
    case poolExhausted
    case creationFailed
    case warmupFailed(String)
    case poolClosed
    
    var errorDescription: String? {
        switch self {
        case .poolExhausted:
            return "连接池已耗尽，无法获取连接"
        case .creationFailed:
            return "创建连接失败"
        case .warmupFailed(let reason):
            return "连接池预热失败: \(reason)"
        case .poolClosed:
            return "连接池已关闭"
        }
    }
}
