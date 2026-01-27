// MultiplexedProxyManager.swift
// 使用多路复用连接的代理管理器

import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import UserNotifications

class MultiplexedProxyManager: ObservableObject {
    @Published var configs: [ProxyConfig] = []
    @Published var activeConfig: ProxyConfig?
    @Published var status: ProxyStatus = .disconnected
    @Published var isRunning = false
    @Published var trafficUp: Double = 0
    @Published var trafficDown: Double = 0
    @Published var logs: [String] = []
    @Published var showingLogs = false
    
    private var socksServer: MultiplexedSOCKS5Server?
    private var httpServer: MultiplexedHTTPProxyServer?
    private var connectionManager: MultiplexedConnectionManager?
    private var configDirectory: URL
    private var timer: Timer?
    private var statsTimer: Timer?
    private var notificationsEnabled = false
    
    private var isStarting = false
    private var isStopping = false
    
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
        addLog("🚀 使用多路复用连接池 v4.0")
        addLog("ℹ️  每个 WebSocket 支持多个并发请求，大幅提升性能")
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
    
    // MARK: - Config Management (保持不变)
    
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
            addLog("⚠️ 代理正在运行，将重启...")
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.start()
            }
        }
    }
    
    // MARK: - Proxy Control (使用多路复用)
    
    func start() {
        guard !isStarting else {
            addLog("⚠️ 代理正在启动中，请稍候...")
            return
        }
        
        guard !isRunning else {
            addLog("⚠️ 代理已在运行")
            return
        }
        
        guard let config = activeConfig else {
            addLog("❌ 错误: 没有选中的配置")
            return
        }
        
        isStarting = true
        status = .connecting
        addLog("🚀 准备启动代理（多路复用模式）...")
        addLog("📡 服务器: \(config.sniHost):\(config.serverPort)")
        if config.sniHost != config.proxyIP {
            addLog("🌐 CDN 模式: \(config.proxyIP)")
        }
        addLog("🔐 使用 AES-256-GCM 加密")
        addLog("🌟 启用 WebSocket 多路复用，大幅提升并发性能")
        
        Task {
            await startProxyServers(config: config)
        }
    }
    
    @MainActor
    private func startProxyServers(config: ProxyConfig) async {
        do {
            // 清理旧的连接管理器
            if let oldManager = connectionManager {
                addLog("🧹 清理旧的连接管理器...")
                await oldManager.cleanup()
                connectionManager = nil
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            // 创建多路复用连接管理器
            let manager = MultiplexedConnectionManager(
                config: config,
                minPoolSize: 2,   // 只需要少量连接
                maxPoolSize: 5    // 每个连接可处理多个请求
            )
            
            connectionManager = manager
            
            // 预热连接池
            try await manager.warmup()
            
            // 启动 SOCKS5 服务器
            let socks = MultiplexedSOCKS5Server(
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
            
            // 启动 HTTP 服务器
            let http = MultiplexedHTTPProxyServer(
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
            
            // 更新状态
            self.isRunning = true
            self.status = .connected
            self.isStarting = false
            
            self.addLog("✅ 代理服务启动成功（多路复用模式）")
            self.addLog("📡 SOCKS5: 127.0.0.1:\(config.socksPort)")
            self.addLog("📡 HTTP: 127.0.0.1:\(config.httpPort)")
            self.addLog("ℹ️  并发性能大幅提升，无需担心连接池耗尽")
            
            if notificationsEnabled {
                self.showNotification(
                    title: "代理已启动",
                    message: "多路复用模式 - SOCKS5: \(config.socksPort) | HTTP: \(config.httpPort)"
                )
            }
            
            startStatsMonitor()
            
        } catch {
            self.addLog("❌ 启动失败: \(error.localizedDescription)")
            self.status = .disconnected
            self.isRunning = false
            self.isStarting = false
            
            if let manager = connectionManager {
                await manager.cleanup()
                connectionManager = nil
            }
        }
    }
    
    func stop() {
        guard !isStopping else {
            addLog("⚠️ 代理正在停止中...")
            return
        }
        
        guard isRunning else {
            addLog("ℹ️ 代理未运行")
            return
        }
        
        isStopping = true
        addLog("🛑 准备停止代理...")
        
        Task {
            await stopProxyServers()
        }
    }
    
    @MainActor
    private func stopProxyServers() async {
        // 1. 停止服务器
        if let socks = socksServer {
            await socks.stop()
            socksServer = nil
        }
        
        if let http = httpServer {
            await http.stop()
            httpServer = nil
        }
        
        // 2. 清理连接管理器
        if let manager = connectionManager {
            await manager.cleanup()
            connectionManager = nil
        }
        
        // 3. 停止统计监控
        statsTimer?.invalidate()
        statsTimer = nil
        
        // 4. 更新状态
        self.isRunning = false
        self.status = .disconnected
        self.isStopping = false
        self.trafficUp = 0
        self.trafficDown = 0
        
        self.addLog("✅ 代理已完全停止")
    }
    
    func rebuildConnectionPool() {
        guard let manager = connectionManager, isRunning else {
            addLog("⚠️ 代理未运行，无法重建连接池")
            return
        }
        
        addLog("🔄 开始重建连接池...")
        
        Task {
            do {
                try await manager.rebuild()
                await MainActor.run {
                    self.addLog("✅ 连接池重建成功")
                }
            } catch {
                await MainActor.run {
                    self.addLog("❌ 连接池重建失败: \(error.localizedDescription)")
                }
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
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task {
                if let manager = await self.connectionManager {
                    await manager.printStats()
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
    
    // MARK: - Import/Export (保持不变)
    
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
}
