// OptimizedConnectionManager.swift
// 修复 actor 隔离问题

import Foundation

actor OptimizedConnectionManager {
    private let config: ProxyConfig
    private var pool: [SecureWebSocket] = []
    private var busyConnections: Set<UUID> = []
    private let maxPoolSize: Int
    let minPoolSize: Int  // 改为 let (public)
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
        
        // 1. 尝试从池中获取空闲连接
        if let ws = pool.first(where: { !busyConnections.contains($0.id) }) {
            // 检查连接是否有效
            if await ws.isHealthy() {
                busyConnections.insert(ws.id)
                totalReused += 1
                return ws
            } else {
                // 移除无效连接
                pool.removeAll { $0.id == ws.id }
                await ws.close()
            }
        }
        
        // 2. 池未满,创建新连接
        if pool.count < maxPoolSize {
            creatingCount += 1
            let ws = SecureWebSocket(config: config)
            do {
                try await ws.connect()
                pool.append(ws)
                busyConnections.insert(ws.id)
                totalCreated += 1
                creatingCount -= 1
                return ws
            } catch {
                creatingCount -= 1
                throw error
            }
        }
        
        // 3. 等待连接释放(最多等待 5 秒)
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 5.0 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if let ws = pool.first(where: { !busyConnections.contains($0.id) }) {
                if await ws.isHealthy() {
                    busyConnections.insert(ws.id)
                    totalReused += 1
                    return ws
                }
            }
        }
        
        throw ConnectionError.poolExhausted
    }
    
    // 释放连接(返回池中) - 改为 async func
    func release(_ ws: SecureWebSocket) async {
        busyConnections.remove(ws.id)
        // 不关闭连接,保持在池中复用
    }
    
    // 清理连接池
    func cleanup() async {
        for ws in pool {
            await ws.close()
        }
        pool.removeAll()
        busyConnections.removeAll()
        
        print("🧹 连接池已清理")
        print("📊 统计: 总获取=\(totalAcquired), 创建=\(totalCreated), 复用=\(totalReused)")
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
            return "连接池已耗尽,无法获取连接"
        }
    }
}
