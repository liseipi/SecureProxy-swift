// ConnectionManager.swift
// 简化日志版本 - 移除冗余输出

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
        // 静默，无输出
    }
    
    // MARK: - 连接获取和释放
    
    /// 获取一个新连接
    func acquire() async throws -> SecureWebSocket {
        totalAcquired += 1
        activeConnections += 1
        
        // 移除日志：每次创建连接都输出太多了
        
        let ws = SecureWebSocket(config: config)
        
        do {
            try await ws.connect()
            totalCreated += 1
            return ws
        } catch {
            activeConnections -= 1
            // 只在失败时输出
            print("❌ 连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 释放连接（直接关闭）
    func release(_ ws: SecureWebSocket) {
        totalReleased += 1
        activeConnections -= 1
        
        Task {
            await ws.close()
            // 移除日志：太频繁
        }
    }
    
    // MARK: - 清理
    
    /// 清理（空操作，因为没有池）
    func cleanup() async {
        // 静默
    }
    
    /// 重建（空操作）
    func rebuild() async throws {
        // 静默
    }
    
    // MARK: - 统计
    
    func getStats() -> (poolSize: Int, active: Int, total: (acquired: Int, released: Int, created: Int)) {
        return (0, activeConnections, (totalAcquired, totalReleased, totalCreated))
    }
    
    func printStats() {
        // 只在真正需要时才调用，不自动输出
        print("📊 活跃: \(activeConnections), 获取: \(totalAcquired), 释放: \(totalReleased), 创建: \(totalCreated)")
    }
}
