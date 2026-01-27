// ConnectionManager.swift
// 连接池管理器 - 模拟 client.js 的实现
// ✅ 真正的连接复用和池管理

import Foundation

/// 连接池管理器
actor ConnectionManager {
    private let config: ProxyConfig
    private var pool: [SecureWebSocket] = []
    private let minPoolSize: Int
    private let maxPoolSize: Int
    private var currentAcquires = 0
    
    // 统计
    private var totalAcquired = 0
    private var totalReleased = 0
    private var totalCreated = 0
    
    init(config: ProxyConfig, minPoolSize: Int = 3, maxPoolSize: Int = 10) {
        self.config = config
        self.minPoolSize = minPoolSize
        self.maxPoolSize = maxPoolSize
    }
    
    // MARK: - 生命周期
    
    /// 预热连接池
    func warmup() async throws {
        print("🔥 [Pool] 正在预热连接池...")
        
        await cleanup()
        
        var successCount = 0
        
        for i in 0..<minPoolSize {
            do {
                print("🔗 [Pool] 创建连接 \(i + 1)/\(minPoolSize)...")
                let ws = try await createConnection()
                pool.append(ws)
                successCount += 1
                print("✅ [Pool] 连接 \(i + 1) 创建成功")
            } catch {
                print("❌ [Pool] 连接 \(i + 1) 创建失败: \(error.localizedDescription)")
            }
        }
        
        if successCount == 0 {
            throw PoolError.warmupFailed("无法创建任何连接")
        }
        
        print("✅ [Pool] 预热完成: 成功创建 \(successCount)/\(minPoolSize) 个连接")
    }
    
    /// 创建新连接
    private func createConnection() async throws -> SecureWebSocket {
        let ws = SecureWebSocket(config: config)
        try await ws.connect()
        totalCreated += 1
        return ws
    }
    
    // MARK: - 连接获取和释放
    
    /// 获取一个可用连接
    func acquire() async throws -> SecureWebSocket {
        currentAcquires += 1
        totalAcquired += 1
        
        // 1. 尝试从池中获取健康的连接
        for ws in pool {
            if await ws.isHealthy() {
                print("♻️ [Pool] 复用连接 \(ws.id)")
                return ws
            }
        }
        
        // 2. 清理不健康的连接
        await removeUnhealthyConnections()
        
        // 3. 如果池未满，创建新连接
        if pool.count < maxPoolSize {
            print("🆕 [Pool] 创建新连接 (当前: \(pool.count)/\(maxPoolSize))")
            do {
                let ws = try await createConnection()
                pool.append(ws)
                return ws
            } catch {
                print("❌ [Pool] 创建连接失败: \(error.localizedDescription)")
                throw error
            }
        }
        
        // 4. 池已满，返回第一个可用连接
        if let ws = pool.first {
            print("⚠️ [Pool] 池已满，强制使用第一个连接")
            return ws
        }
        
        throw PoolError.exhausted
    }
    
    /// 释放连接回池
    func release(_ ws: SecureWebSocket) {
        currentAcquires -= 1
        totalReleased += 1
        
        Task {
            // 检查连接是否健康
            if await !ws.isHealthy() {
                print("🗑️ [Pool] 释放不健康的连接 \(ws.id)")
                await ws.close()
                
                // 从池中移除
                pool.removeAll { $0.id == ws.id }
                
                // 如果池太小，补充连接
                if pool.count < minPoolSize {
                    do {
                        let newWs = try await createConnection()
                        pool.append(newWs)
                        print("✅ [Pool] 已补充连接，当前: \(pool.count)")
                    } catch {
                        print("❌ [Pool] 补充连接失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    // MARK: - 维护
    
    /// 移除不健康的连接
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
            print("🧹 [Pool] 移除 \(toRemove.count) 个不健康连接，剩余 \(pool.count)")
        }
    }
    
    /// 清理所有连接
    func cleanup() async {
        print("🧹 [Pool] 开始清理连接池...")
        
        for ws in pool {
            await ws.close()
        }
        
        pool.removeAll()
        currentAcquires = 0
        
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        print("✅ [Pool] 连接池已清理")
    }
    
    /// 重建连接池
    func rebuild() async throws {
        print("🔄 [Pool] 重建连接池...")
        await cleanup()
        
        totalAcquired = 0
        totalReleased = 0
        totalCreated = 0
        
        try await warmup()
        print("✅ [Pool] 连接池重建完成")
    }
    
    // MARK: - 统计
    
    func getStats() -> (poolSize: Int, active: Int, total: (acquired: Int, released: Int, created: Int)) {
        return (pool.count, currentAcquires, (totalAcquired, totalReleased, totalCreated))
    }
    
    func printStats() {
        let stats = getStats()
        print("📊 [Pool] 连接池: \(stats.poolSize) 个, 活跃: \(stats.active), 总获取: \(stats.total.acquired), 总释放: \(stats.total.released), 总创建: \(stats.total.created)")
    }
}

// MARK: - 错误

enum PoolError: LocalizedError {
    case exhausted
    case warmupFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .exhausted:
            return "连接池已耗尽"
        case .warmupFailed(let reason):
            return "连接池预热失败: \(reason)"
        }
    }
}
