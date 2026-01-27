// OptimizedConnectionManager.swift
// 修复版本 - 解决重连问题

import Foundation

actor OptimizedConnectionManager {
    private let config: ProxyConfig
    private var pool: [SecureWebSocket] = []
    private var busyConnections: Set<UUID> = []
    private let maxPoolSize: Int
    let minPoolSize: Int
    private var creatingCount = 0
    
    // 统计信息
    private var totalAcquired = 0
    private var totalCreated = 0
    private var totalReused = 0
    
    init(config: ProxyConfig, minPoolSize: Int = 2, maxPoolSize: Int = 20) {
        self.config = config
        self.minPoolSize = minPoolSize
        self.maxPoolSize = maxPoolSize
    }
    
    // 预热连接池
    func warmup() async throws {
        print("🔥 预热连接池...")
        
        // 🔧 修复：预热前先清空旧连接
        await cleanup()
        
        for i in 0..<minPoolSize {
            do {
                print("🔗 创建连接 \(i + 1)/\(minPoolSize)...")
                let ws = SecureWebSocket(config: config)
                try await ws.connect()
                pool.append(ws)
                totalCreated += 1
                print("✅ 连接 \(i + 1) 创建成功")
            } catch {
                print("❌ 连接 \(i + 1) 创建失败: \(error.localizedDescription)")
                throw error
            }
        }
        print("✅ 连接池预热完成: \(pool.count) 个连接")
    }
    
    // 获取连接
    func acquire() async throws -> SecureWebSocket {
        totalAcquired += 1
        
        // 1. 尝试从池中获取空闲且健康的连接
        if let ws = pool.first(where: { !busyConnections.contains($0.id) }) {
            // 检查连接是否健康
            if await ws.isHealthy() {
                busyConnections.insert(ws.id)
                totalReused += 1
                print("♻️ [Pool] 复用连接 \(ws.id)")
                return ws
            } else {
                // 移除不健康的连接
                print("⚠️ [Pool] 移除不健康的连接 \(ws.id)")
                pool.removeAll { $0.id == ws.id }
                await ws.close()
            }
        }
        
        // 2. 池未满，创建新连接
        if pool.count < maxPoolSize {
            creatingCount += 1
            print("🆕 [Pool] 创建新连接 (当前池大小: \(pool.count)/\(maxPoolSize))")
            
            let ws = SecureWebSocket(config: config)
            do {
                try await ws.connect()
                pool.append(ws)
                busyConnections.insert(ws.id)
                totalCreated += 1
                creatingCount -= 1
                print("✅ [Pool] 新连接创建成功 \(ws.id)")
                return ws
            } catch {
                creatingCount -= 1
                print("❌ [Pool] 新连接创建失败: \(error.localizedDescription)")
                throw error
            }
        }
        
        // 3. 等待连接释放（最多等待 5 秒）
        print("⏳ [Pool] 连接池已满，等待连接释放...")
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 5.0 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if let ws = pool.first(where: { !busyConnections.contains($0.id) }) {
                if await ws.isHealthy() {
                    busyConnections.insert(ws.id)
                    totalReused += 1
                    print("✅ [Pool] 等待后获得连接 \(ws.id)")
                    return ws
                }
            }
        }
        
        print("❌ [Pool] 连接池已耗尽，无法获取连接")
        throw ConnectionError.poolExhausted
    }
    
    // 释放连接（返回池中）
    func release(_ ws: SecureWebSocket) async {
        busyConnections.remove(ws.id)
        print("🔄 [Pool] 连接已释放 \(ws.id)")
        
        // 检查连接是否还健康
        if await ws.isHealthy() {
            print("✅ [Pool] 连接健康，保留在池中")
        } else {
            print("⚠️ [Pool] 连接不健康，从池中移除")
            pool.removeAll { $0.id == ws.id }
            await ws.close()
        }
    }
    
    // 清理连接池（修复版本）
    func cleanup() async {
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
        
        // 3. 等待一小段时间确保资源释放
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        print("✅ [Pool] 连接池已完全清理")
        print("📊 统计: 总获取=\(totalAcquired), 创建=\(totalCreated), 复用=\(totalReused)")
        
        // 4. 重置统计（可选）
        // totalAcquired = 0
        // totalCreated = 0
        // totalReused = 0
    }
    
    // 获取统计信息
    func getStats() -> (poolSize: Int, busy: Int, created: Int, reused: Int) {
        return (pool.count, busyConnections.count, totalCreated, totalReused)
    }
}

enum ConnectionError: Error {
    case poolExhausted
    
    var localizedDescription: String {
        switch self {
        case .poolExhausted:
            return "连接池已耗尽，无法获取连接"
        }
    }
}
