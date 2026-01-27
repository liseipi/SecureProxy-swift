// OptimizedConnectionManager.swift
// 修复版本 - 增加重试机制和更好的错误处理

import Foundation

actor OptimizedConnectionManager {
    private let config: ProxyConfig
    private var pool: [SecureWebSocket] = []
    private var busyConnections: Set<UUID> = []
    private let maxPoolSize: Int
    let minPoolSize: Int
    private var creatingCount = 0
    private var isCleaningUp = false  // 🔧 新增：防止清理时获取连接
    
    // 统计信息
    private var totalAcquired = 0
    private var totalCreated = 0
    private var totalReused = 0
    private var totalFailed = 0  // 🔧 新增：失败次数
    
    // 🔧 新增：重试配置
    private let maxRetries = 3
    private let retryDelay: UInt64 = 1_000_000_000  // 1秒
    
    init(config: ProxyConfig, minPoolSize: Int = 2, maxPoolSize: Int = 20) {
        self.config = config
        self.minPoolSize = minPoolSize
        self.maxPoolSize = maxPoolSize
    }
    
    // 预热连接池
    func warmup() async throws {
        print("🔥 [Pool] 预热连接池...")
        
        // 先清空旧连接
        await cleanup()
        
        var successCount = 0
        var failedCount = 0
        
        for i in 0..<minPoolSize {
            do {
                print("🔗 [Pool] 创建连接 \(i + 1)/\(minPoolSize)...")
                
                // 🔧 增加重试机制
                let ws = try await createConnectionWithRetry()
                pool.append(ws)
                totalCreated += 1
                successCount += 1
                
                print("✅ [Pool] 连接 \(i + 1) 创建成功")
            } catch {
                failedCount += 1
                totalFailed += 1
                print("❌ [Pool] 连接 \(i + 1) 创建失败: \(error.localizedDescription)")
                
                // 🔧 如果失败过多，提前终止
                if failedCount >= 2 {
                    print("⚠️ [Pool] 连续失败 \(failedCount) 次，停止预热")
                    break
                }
            }
        }
        
        if successCount == 0 {
            throw ConnectionError.warmupFailed("无法创建任何连接")
        }
        
        print("✅ [Pool] 连接池预热完成: 成功 \(successCount), 失败 \(failedCount)")
    }
    
    // 🔧 新增：带重试的连接创建
    private func createConnectionWithRetry() async throws -> SecureWebSocket {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let ws = SecureWebSocket(config: config)
                try await ws.connect()
                return ws
            } catch {
                lastError = error
                print("⚠️ [Pool] 连接尝试 \(attempt)/\(maxRetries) 失败: \(error.localizedDescription)")
                
                if attempt < maxRetries {
                    print("⏳ [Pool] 等待 1 秒后重试...")
                    try await Task.sleep(nanoseconds: retryDelay)
                }
            }
        }
        
        throw lastError ?? ConnectionError.creationFailed
    }
    
    // 获取连接
    func acquire() async throws -> SecureWebSocket {
        // 🔧 防止在清理时获取连接
        guard !isCleaningUp else {
            throw ConnectionError.poolClosed
        }
        
        totalAcquired += 1
        
        // 1. 尝试从池中获取空闲且健康的连接
        var unhealthyConnections: [UUID] = []
        
        for ws in pool where !busyConnections.contains(ws.id) {
            if await ws.isHealthy() {
                busyConnections.insert(ws.id)
                totalReused += 1
                print("♻️ [Pool] 复用连接 \(ws.id)")
                return ws
            } else {
                // 收集不健康的连接ID
                unhealthyConnections.append(ws.id)
            }
        }
        
        // 🔧 批量移除所有不健康的连接
        if !unhealthyConnections.isEmpty {
            print("🧹 [Pool] 移除 \(unhealthyConnections.count) 个不健康的连接")
            for wsId in unhealthyConnections {
                if let ws = pool.first(where: { $0.id == wsId }) {
                    await ws.close()
                }
            }
            pool.removeAll { unhealthyConnections.contains($0.id) }
            print("📊 [Pool] 清理后池大小: \(pool.count)")
        }
        
        // 2. 池未满，创建新连接
        if pool.count < maxPoolSize {
            creatingCount += 1
            print("🆕 [Pool] 创建新连接 (当前池大小: \(pool.count)/\(maxPoolSize))")
            
            do {
                // 🔧 使用带重试的创建方法
                let ws = try await createConnectionWithRetry()
                pool.append(ws)
                busyConnections.insert(ws.id)
                totalCreated += 1
                creatingCount -= 1
                print("✅ [Pool] 新连接创建成功 \(ws.id)")
                return ws
            } catch {
                creatingCount -= 1
                totalFailed += 1
                print("❌ [Pool] 新连接创建失败: \(error.localizedDescription)")
                throw error
            }
        }
        
        // 3. 等待连接释放（最多等待 10 秒）
        print("⏳ [Pool] 连接池已满(\(pool.count)/\(maxPoolSize))，等待连接释放...")
        let startTime = Date()
        var waitCount = 0
        
        while Date().timeIntervalSince(startTime) < 10.0 {
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            waitCount += 1
            
            if waitCount % 10 == 0 {  // 每秒输出一次
                print("⏳ [Pool] 已等待 \(waitCount / 10) 秒...")
            }
            
            for ws in pool where !busyConnections.contains(ws.id) {
                if await ws.isHealthy() {
                    busyConnections.insert(ws.id)
                    totalReused += 1
                    print("✅ [Pool] 等待后获得连接 \(ws.id)")
                    return ws
                }
            }
        }
        
        print("❌ [Pool] 连接池已耗尽，等待超时")
        print("📊 [Pool] 当前状态: 总数=\(pool.count), 忙碌=\(busyConnections.count), 最大=\(maxPoolSize)")
        throw ConnectionError.poolExhausted
    }
    
    // 释放连接（返回池中）
    func release(_ ws: SecureWebSocket) async {
        busyConnections.remove(ws.id)
        
        // 🔧 立即检查连接健康状态
        let isHealthy = await ws.isHealthy()
        
        if isHealthy {
            print("✅ [Pool] 连接 \(ws.id) 健康，保留在池中")
        } else {
            print("⚠️ [Pool] 连接 \(ws.id) 不健康，立即移除并关闭")
            pool.removeAll { $0.id == ws.id }
            await ws.close()
            
            // 🔧 如果池变小了，记录一下
            if pool.count < minPoolSize {
                print("📉 [Pool] 当前池大小 \(pool.count) 低于最小值 \(minPoolSize)")
            }
        }
        
        print("🔄 [Pool] 连接已释放，当前池状态: 总数=\(pool.count), 忙碌=\(busyConnections.count)")
    }
    
    // 🔧 优化：清理连接池
    func cleanup() async {
        guard !isCleaningUp else {
            print("⚠️ [Pool] 已在清理中，跳过")
            return
        }
        
        isCleaningUp = true
        
        print("🧹 [Pool] 开始清理连接池...")
        print("📊 [Pool] 当前池大小: \(pool.count), 忙碌: \(busyConnections.count)")
        
        // 1. 关闭所有连接
        for ws in pool {
            print("🔴 [Pool] 关闭连接 \(ws.id)")
            await ws.close()
        }
        
        // 2. 清空池和忙碌集合
        pool.removeAll()
        busyConnections.removeAll()
        creatingCount = 0
        
        // 3. 等待确保资源释放
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        
        isCleaningUp = false
        
        print("✅ [Pool] 连接池已完全清理")
        print("📊 [Pool] 统计: 总获取=\(totalAcquired), 创建=\(totalCreated), 复用=\(totalReused), 失败=\(totalFailed)")
    }
    
    // 🔧 新增：强制重建连接池
    func rebuild() async throws {
        print("🔄 [Pool] 强制重建连接池...")
        await cleanup()
        
        // 重置统计
        totalAcquired = 0
        totalCreated = 0
        totalReused = 0
        totalFailed = 0
        
        try await warmup()
        print("✅ [Pool] 连接池重建完成")
    }
    
    // 获取统计信息
    func getStats() -> (poolSize: Int, busy: Int, created: Int, reused: Int, failed: Int) {
        return (pool.count, busyConnections.count, totalCreated, totalReused, totalFailed)
    }
}

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
