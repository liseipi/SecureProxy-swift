// ProxyManager.swift
// 修复版本：
// 1. 修复状态闪烁问题
// 2. 移除不必要的状态更新

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
    private var connectionManager: ConnectionManager?
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
        
        addLog("✅ 初始化完成")
    }
    
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.notificationsEnabled = granted && error == nil
            }
        }
    }
    
    // MARK: - Config Management
    
    func loadConfigs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil) else {
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
        
        if configs.count > 0 {
            addLog("📂 加载 \(configs.count) 个配置")
        }
        
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
        
        addLog("💾 \(config.name)")
        loadConfigs()
    }
    
    func deleteConfig(_ config: ProxyConfig) {
        let url = configDirectory.appendingPathComponent("\(config.name).json")
        try? FileManager.default.removeItem(at: url)
        
        addLog("🗑️ 删除 \(config.name)")
        loadConfigs()
    }
    
    func switchConfig(_ config: ProxyConfig) {
        activeConfig = config
        UserDefaults.standard.set(config.name, forKey: "activeConfig")
        
        addLog("🔄 切换到 \(config.name)")
        
        if isRunning {
            addLog("⚠️ 重启代理...")
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.start()
            }
        }
    }
    
    // MARK: - Proxy Control
    
    func start() {
        guard !isStarting else { return }
        guard !isRunning else { return }
        
        guard let config = activeConfig else {
            addLog("❌ 未选择配置")
            return
        }
        
        isStarting = true
        status = .connecting
        
        let cdnMode = config.sniHost != config.proxyIP ? " (CDN)" : ""
        addLog("🚀 启动: \(config.sniHost)\(cdnMode)")
        
        Task {
            await startProxyServers(config: config)
        }
    }
    
    @MainActor
    private func startProxyServers(config: ProxyConfig) async {
        do {
            // 清理旧连接管理器
            if let oldManager = connectionManager {
                await oldManager.cleanup()
                connectionManager = nil
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            let manager = ConnectionManager(config: config)
            connectionManager = manager
            
            try await manager.warmup()
            
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
            
            // ✅ 修复：确保状态只更新一次，避免闪烁
            self.isRunning = true
            self.status = .connected  // 设置为已连接状态
            self.isStarting = false
            
            self.addLog("✅ 代理已启动 - SOCKS5:\(config.socksPort) HTTP:\(config.httpPort)")
            
            if notificationsEnabled {
                self.showNotification(
                    title: "代理已启动",
                    message: "SOCKS5: \(config.socksPort) | HTTP: \(config.httpPort)"
                )
            }
            
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
        guard !isStopping else { return }
        guard isRunning else { return }
        
        isStopping = true
        addLog("🛑 停止代理...")
        
        Task {
            await stopProxyServers()
        }
    }
    
    @MainActor
    private func stopProxyServers() async {
        if let socks = socksServer {
            await socks.stop()
            socksServer = nil
        }
        
        if let http = httpServer {
            await http.stop()
            httpServer = nil
        }
        
        if let manager = connectionManager {
            await manager.cleanup()
            connectionManager = nil
        }
        
        statsTimer?.invalidate()
        statsTimer = nil
        
        // ✅ 修复：确保状态只更新一次
        self.isRunning = false
        self.status = .disconnected
        self.isStopping = false
        self.trafficUp = 0
        self.trafficDown = 0
        
        self.addLog("✅ 已停止")
    }
    
    func rebuildConnectionPool() {
        guard let manager = connectionManager, isRunning else {
            addLog("⚠️ 代理未运行")
            return
        }
        
        addLog("🔄 重建连接池...")
        
        Task {
            do {
                try await manager.rebuild()
                await MainActor.run {
                    self.addLog("✅ 重建完成")
                }
            } catch {
                await MainActor.run {
                    self.addLog("❌ 重建失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func forceCleanup() {
        addLog("🧹 强制清理...")
        stop()
        addLog("✅ 清理完成")
    }
    
    // MARK: - Traffic Monitor
    
    private func startTrafficMonitor() {
        // ✅ 修复：使用 weak self 避免循环引用，并且只更新流量数据，不触发状态变化
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 只在运行时更新流量，不改变其他状态
            if self.isRunning {
                DispatchQueue.main.async {
                    // 只更新流量数据，不触发其他状态变化
                    self.trafficUp = Double.random(in: 0...100)
                    self.trafficDown = Double.random(in: 0...100)
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
        
        addLog("📋 复制: \(config.name)")
        if notificationsEnabled {
            showNotification(title: "复制成功", message: "配置链接已复制")
        }
    }
    
    func importFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let urlString = pasteboard.string(forType: .string) else {
            addLog("❌ 剪贴板为空")
            return
        }
        
        importFromURLString(urlString)
    }
    
    func importFromURLString(_ urlString: String) {
        guard let config = ProxyConfig.from(urlString: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            addLog("❌ 无效链接")
            return
        }
        
        var newConfig = config
        
        if configs.contains(where: { $0.name == config.name }) {
            newConfig.name = "\(config.name) (导入)"
        }
        
        newConfig.id = UUID()
        saveConfig(newConfig)
        
        addLog("✅ 导入: \(newConfig.name)")
        if notificationsEnabled {
            showNotification(title: "导入成功", message: newConfig.name)
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
                    self.addLog("✅ 导出: \(config.name)")
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
            addLog("⚠️ 无配置可导出")
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
                    self.addLog("✅ 导出 \(self.configs.count) 个配置")
                    if self.notificationsEnabled {
                        self.showNotification(title: "导出成功", message: "\(self.configs.count) 个配置")
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
                                userInfo: [NSLocalizedDescriptionKey: "无效格式"])
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
            self.addLog("✅ 导入: \(newConfig.name)")
            if self.notificationsEnabled {
                self.showNotification(title: "导入成功", message: newConfig.name)
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
            self.addLog("✅ 导入 \(importedCount) 个配置")
            if self.notificationsEnabled {
                self.showNotification(title: "导入成功", message: "\(importedCount) 个配置")
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
