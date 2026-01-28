// ConnectionManager.swift
// 简化版连接管理器 - 完全模拟 client.js 实现
// ✅ 不使用连接池，每次创建新连接
// ✅ 避免连接复用导致的状态混乱

import Foundation

/// 简化的连接管理器（不使用连接池）
actor ConnectionManager {
    private let config: ProxyConfig
    
    // 统计
    private var totalAcquired = 0
    private var totalReleased = 0
    private var totalCreated = 0
    private var activeConnections = 0
    
    init(config: ProxyConfig) {
        self.config = config
    }
    
    // MARK: - 生命周期
    
    /// 预热（空操作，因为不使用连接池）
    func warmup() async throws {
        print("ℹ️  [Manager] 使用按需连接模式（无连接池）")
        print("ℹ️  [Manager] 每个请求创建独立连接")
    }
    
    // MARK: - 连接获取和释放
    
    /// 获取一个新连接
    func acquire() async throws -> SecureWebSocket {
        totalAcquired += 1
        activeConnections += 1
        
        print("🆕 [Manager] 创建新连接 (活跃: \(activeConnections))")
        
        let ws = SecureWebSocket(config: config)
        
        do {
            try await ws.connect()
            totalCreated += 1
            return ws
        } catch {
            activeConnections -= 1
            print("❌ [Manager] 创建连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 释放连接（直接关闭）
    func release(_ ws: SecureWebSocket) {
        totalReleased += 1
        activeConnections -= 1
        
        Task {
            await ws.close()
            print("🗑️  [Manager] 关闭连接 (活跃: \(activeConnections))")
        }
    }
    
    // MARK: - 清理
    
    /// 清理（空操作，因为没有池）
    func cleanup() async {
        print("✅ [Manager] 清理完成")
    }
    
    /// 重建（空操作）
    func rebuild() async throws {
        print("ℹ️  [Manager] 按需连接模式无需重建")
    }
    
    // MARK: - 统计
    
    func getStats() -> (poolSize: Int, active: Int, total: (acquired: Int, released: Int, created: Int)) {
        return (0, activeConnections, (totalAcquired, totalReleased, totalCreated))
    }
    
    func printStats() {
        print("📊 [Manager] 活跃连接: \(activeConnections), 总获取: \(totalAcquired), 总释放: \(totalReleased), 总创建: \(totalCreated)")
    }
}
