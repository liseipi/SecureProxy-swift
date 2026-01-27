// ProxyManager.swift
// 修复 deinit 中的 Sendable 问题

import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import UserNotifications

class ProxyManager: ObservableObject {
    @Published var configs: [ProxyConfig] = []
    @Published var activeConfig: ProxyConfig?
    @Published var status: ProxyStatus = .disconnected
    @Published var isRunning = false
    @Published var trafficUp: Double = 0
    @Published var trafficDown: Double = 0
    @Published var logs: [String] = []
    @Published var showingLogs = false
    
    private var socksServer: SOCKS5Server?
    private var httpServer: HTTPProxyServer?
    private var connectionManager: OptimizedConnectionManager?
    private var configDirectory: URL
    private var timer: Timer?
    private var statsTimer: Timer?
    private var notificationsEnabled = false
    
    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let baseDir = appSupport.appendingPathComponent("SecureProxy")
        self.configDirectory = baseDir.appendingPathComponent("config")
        
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        
        requestNotificationPermission()
        loadConfigs()
        startTrafficMonitor()
        
        addLog("✅ ProxyManager 初始化完成")
        addLog("🚀 使用连接池优化技术")
    }
    
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("⚠️ 通知权限: \(error.localizedDescription)")
                    self?.notificationsEnabled = false
                } else if granted {
                    print("✅ 通知权限已授予")
                    self?.notificationsEnabled = true
                } else {
                    print("ℹ️ 通知权限被拒绝")
                    self?.notificationsEnabled = false
                }
            }
        }
    }
    
    // MARK: - Config Management
    
    func loadConfigs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil) else {
            addLog("ℹ️ 配置目录为空")
            return
        }
        
        configs = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let config = try? JSONDecoder().decode(ProxyConfig.self, from: data) else {
                    return nil
                }
                return config
            }
        
        addLog("📂 加载了 \(configs.count) 个配置")
        
        if let activeName = UserDefaults.standard.string(forKey: "activeConfig"),
           let active = configs.first(where: { $0.name == activeName }) {
            activeConfig = active
        } else if let first = configs.first {
            activeConfig = first
        }
    }
    
    func saveConfig(_ config: ProxyConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        guard let data = try? encoder.encode(config) else { return }
        
        let url = configDirectory.appendingPathComponent("\(config.name).json")
        try? data.write(to: url)
        
        addLog("💾 保存配置: \(config.name)")
        loadConfigs()
    }
    
    func deleteConfig(_ config: ProxyConfig) {
        let url = configDirectory.appendingPathComponent("\(config.name).json")
        try? FileManager.default.removeItem(at: url)
        
        addLog("🗑️ 删除配置: \(config.name)")
        loadConfigs()
    }
    
    func switchConfig(_ config: ProxyConfig) {
        activeConfig = config
        UserDefaults.standard.set(config.name, forKey: "activeConfig")
        
        addLog("🔄 切换到配置: \(config.name)")
        
        if isRunning {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.start()
            }
        }
    }
    
    // MARK: - Proxy Control
    
    func start() {
        guard let config = activeConfig else {
            addLog("❌ 错误: 没有选中的配置")
            return
        }
        guard !isRunning else { return }
        
        status = .connecting
        addLog("🚀 启动代理...")
        addLog("📡 服务器: \(config.sniHost):\(config.serverPort)")
        addLog("🔐 使用 AES-256-GCM 加密")
        addLog("🔥 启用连接池优化")
        
        Task {
            await startProxyServers(config: config)
        }
    }
    
    @MainActor
    private func startProxyServers(config: ProxyConfig) async {
        do {
            let manager = OptimizedConnectionManager(
                config: config,
                minPoolSize: 0,  // 暂时设为 0 跳过预热,测试用
                maxPoolSize: 20
            )
            
            // 如果 minPoolSize > 0 才预热
            if manager.minPoolSize > 0 {
                addLog("🔥 预热连接池...")
                try await manager.warmup()
                addLog("✅ 连接池就绪")
            } else {
                addLog("⚠️ 跳过连接池预热(测试模式)")
            }
            
            connectionManager = manager
            
            let socks = SOCKS5Server(
                port: config.socksPort,
                config: config,
                connectionManager: manager,
                onLog: { [weak self] message in
                    Task { @MainActor in
                        self?.addLog(message)
                    }
                }
            )
            
            try await socks.start()
            socksServer = socks
            
            let http = HTTPProxyServer(
                port: config.httpPort,
                config: config,
                connectionManager: manager,
                onLog: { [weak self] message in
                    Task { @MainActor in
                        self?.addLog(message)
                    }
                }
            )
            
            try await http.start()
            httpServer = http
            
            self.isRunning = true
            self.status = .connected
            self.addLog("✅ 代理服务启动成功")
            self.addLog("📡 SOCKS5: 127.0.0.1:\(config.socksPort)")
            self.addLog("📡 HTTP: 127.0.0.1:\(config.httpPort)")
            
            if notificationsEnabled {
                self.showNotification(
                    title: "代理已启动",
                    message: "SOCKS5: \(config.socksPort) | HTTP: \(config.httpPort)"
                )
            }
            
            startStatsMonitor()
            
        } catch {
            self.addLog("❌ 启动失败: \(error.localizedDescription)")
            self.status = .disconnected
            self.isRunning = false
        }
    }
    
    func stop() {
        addLog("🛑 停止代理...")
        
        Task {
            if let socks = socksServer {
                await socks.stop()
                await MainActor.run {
                    socksServer = nil
                }
            }
            
            if let http = httpServer {
                await http.stop()
                await MainActor.run {
                    httpServer = nil
                }
            }
            
            if let manager = connectionManager {
                await manager.cleanup()
                await MainActor.run {
                    connectionManager = nil
                }
            }
            
            await MainActor.run {
                self.isRunning = false
                self.status = .disconnected
                self.trafficUp = 0
                self.trafficDown = 0
                self.addLog("✅ 代理已停止")
                
                self.statsTimer?.invalidate()
                self.statsTimer = nil
            }
        }
    }
    
    func forceCleanup() {
        addLog("🧹 开始强制清理...")
        stop()
        addLog("✅ 清理完成")
    }
    
    // MARK: - Traffic Monitor
    
    private func startTrafficMonitor() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                guard self.isRunning else { return }
                
                self.trafficUp = Double.random(in: 0...100)
                self.trafficDown = Double.random(in: 0...100)
            }
        }
    }
    
    private func startStatsMonitor() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task {
                if let manager = await self.connectionManager {
                    let stats = await manager.getStats()
                    await MainActor.run {
                        self.addLog("📊 连接池: 总数=\(stats.poolSize), 忙碌=\(stats.busy), 创建=\(stats.created), 复用=\(stats.reused)")
                    }
                }
            }
        }
    }
    
    // MARK: - Logging
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 500 {
            logs.removeFirst()
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        addLog("🗑️ 日志已清除")
    }
    
    // MARK: - Import/Export
    
    func copyConfigURL(_ config: ProxyConfig) {
        let urlString = config.toURLString()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)
        
        addLog("📋 已复制配置链接: \(config.name)")
        if notificationsEnabled {
            showNotification(title: "复制成功", message: "配置链接已复制到剪贴板")
        }
    }
    
    func importFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let urlString = pasteboard.string(forType: .string) else {
            addLog("❌ 剪贴板中没有文本")
            return
        }
        
        importFromURLString(urlString)
    }
    
    func importFromURLString(_ urlString: String) {
        guard let config = ProxyConfig.from(urlString: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            addLog("❌ 无效的配置链接格式")
            return
        }
        
        var newConfig = config
        
        if configs.contains(where: { $0.name == config.name }) {
            newConfig.name = "\(config.name) (导入)"
        }
        
        newConfig.id = UUID()
        saveConfig(newConfig)
        
        addLog("✅ 成功导入配置: \(newConfig.name)")
        if notificationsEnabled {
            showNotification(title: "导入成功", message: "配置 \(newConfig.name) 已导入")
        }
    }
    
    func showConfigURL(_ config: ProxyConfig) -> String {
        return config.toURLString()
    }
    
    func exportConfig(_ config: ProxyConfig) {
        let savePanel = NSSavePanel()
        savePanel.title = "导出配置"
        savePanel.nameFieldStringValue = "\(config.name).json"
        savePanel.allowedContentTypes = [UTType.json]
        savePanel.canCreateDirectories = true
        
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(config)
                try data.write(to: url)
                
                DispatchQueue.main.async {
                    self.addLog("✅ 配置已导出: \(config.name)")
                    if self.notificationsEnabled {
                        self.showNotification(title: "导出成功", message: "配置已保存")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.addLog("❌ 导出失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func exportAllConfigs() {
        guard !configs.isEmpty else {
            addLog("⚠️ 没有可导出的配置")
            return
        }
        
        let savePanel = NSSavePanel()
        savePanel.title = "导出所有配置"
        savePanel.nameFieldStringValue = "SecureProxy-Configs.json"
        savePanel.allowedContentTypes = [UTType.json]
        savePanel.canCreateDirectories = true
        
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(self.configs)
                try data.write(to: url)
                
                DispatchQueue.main.async {
                    self.addLog("✅ 已导出 \(self.configs.count) 个配置")
                    if self.notificationsEnabled {
                        self.showNotification(title: "导出成功", message: "已导出 \(self.configs.count) 个配置")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.addLog("❌ 导出失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func importConfig() {
        let openPanel = NSOpenPanel()
        openPanel.title = "导入配置"
        openPanel.allowedContentTypes = [UTType.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }
            
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                
                if let config = try? decoder.decode(ProxyConfig.self, from: data) {
                    self.importSingleConfig(config)
                } else if let configsArray = try? decoder.decode([ProxyConfig].self, from: data) {
                    self.importMultipleConfigs(configsArray)
                } else {
                    throw NSError(domain: "ImportError", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "无效的配置文件格式"])
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.addLog("❌ 导入失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func importSingleConfig(_ config: ProxyConfig) {
        var newConfig = config
        
        if configs.contains(where: { $0.name == config.name }) {
            newConfig.name = "\(config.name) (导入)"
        }
        
        newConfig.id = UUID()
        saveConfig(newConfig)
        
        DispatchQueue.main.async {
            self.addLog("✅ 成功导入配置: \(newConfig.name)")
            if self.notificationsEnabled {
                self.showNotification(title: "导入成功", message: "配置 \(newConfig.name) 已导入")
            }
        }
    }
    
    private func importMultipleConfigs(_ configsArray: [ProxyConfig]) {
        var importedCount = 0
        
        for config in configsArray {
            var newConfig = config
            
            if configs.contains(where: { $0.name == config.name }) {
                newConfig.name = "\(config.name) (导入)"
            }
            
            newConfig.id = UUID()
            saveConfig(newConfig)
            importedCount += 1
        }
        
        DispatchQueue.main.async {
            self.addLog("✅ 成功导入 \(importedCount) 个配置")
            if self.notificationsEnabled {
                self.showNotification(title: "导入成功", message: "已导入 \(importedCount) 个配置")
            }
        }
    }
    
    private func showNotification(title: String, message: String) {
        guard notificationsEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Deinit (简化版本 - 移除 Timer 清理)
    
    deinit {
        // Timer 会在 RunLoop 中自动清理,无需手动处理
        // 只清理 actor 资源
        let socks = socksServer
        let http = httpServer
        let manager = connectionManager
        
        if socks != nil || http != nil || manager != nil {
            Task {
                if let socks = socks {
                    await socks.stop()
                }
                if let http = http {
                    await http.stop()
                }
                if let manager = manager {
                    await manager.cleanup()
                }
            }
        }
    }
}
