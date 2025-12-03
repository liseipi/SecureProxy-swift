// ViewModels/ProxyManager.swift
import Foundation
import Combine

class ProxyManager: ObservableObject {
    @Published var configs: [ProxyConfig] = []
    @Published var activeConfig: ProxyConfig?
    @Published var status: ProxyStatus = .disconnected
    @Published var isRunning = false
    @Published var trafficUp: Double = 0
    @Published var trafficDown: Double = 0
    @Published var logs: [String] = []
    
    private var process: Process?
    private var configDirectory: URL
    private var pythonDirectory: URL
    private var pythonPath: String
    private var timer: Timer?
    
    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let baseDir = appSupport.appendingPathComponent("SecureProxy")
        self.configDirectory = baseDir.appendingPathComponent("config")
        self.pythonDirectory = baseDir.appendingPathComponent("python")
        
        // 初始化 pythonPath（先设置默认值）
        self.pythonPath = "/usr/bin/python3"
        
        // 创建目录
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pythonDirectory, withIntermediateDirectories: true)
        
        // 现在可以调用实例方法了
        self.pythonPath = findPython()
        
        copyPythonScripts()
        loadConfigs()
        startTrafficMonitor()
    }
    
    private func findPython() -> String {
        // 优先级顺序
        let paths = [
            shell("which python3"),
            "\(NSHomeDirectory())/.pyenv/shims/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        
        let fm = FileManager.default
        for path in paths {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty && fm.fileExists(atPath: trimmedPath) {
                if checkPythonDependencies(pythonPath: trimmedPath) {
                    addLog("✅ 找到可用的 Python: \(trimmedPath)")
                    return trimmedPath
                } else {
                    addLog("⚠️ Python 存在但缺少依赖: \(trimmedPath)")
                }
            }
        }
        
        addLog("⚠️ 未找到合适的 Python，使用默认路径")
        return "/usr/bin/python3"
    }
    
    private func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.standardInput = nil
        
        var environment = ProcessInfo.processInfo.environment
        if let home = environment["HOME"] {
            let pyenvRoot = "\(home)/.pyenv"
            let path = "\(pyenvRoot)/shims:\(pyenvRoot)/bin:\(environment["PATH"] ?? "")"
            environment["PATH"] = path
            task.environment = environment
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
    
    private func checkPythonDependencies(pythonPath: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = ["-c", "import cryptography, websockets"]
        task.environment = ProcessInfo.processInfo.environment
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func copyPythonScripts() {
        let fm = FileManager.default
        let pythonFiles = ["client.py", "crypto.py", "tls_fingerprint.py"]
        var copiedCount = 0
        
        for file in pythonFiles {
            let destPath = pythonDirectory.appendingPathComponent(file)
            try? fm.removeItem(at: destPath)
            
            let possiblePaths = [
                Bundle.main.resourceURL?.appendingPathComponent("Python").appendingPathComponent(file),
                Bundle.main.resourceURL?.appendingPathComponent(file),
                Bundle.main.path(forResource: file.replacingOccurrences(of: ".py", with: ""), ofType: "py", inDirectory: "Python").map { URL(fileURLWithPath: $0) },
                Bundle.main.path(forResource: file.replacingOccurrences(of: ".py", with: ""), ofType: "py").map { URL(fileURLWithPath: $0) }
            ].compactMap { $0 }
            
            var copied = false
            for sourcePath in possiblePaths {
                if fm.fileExists(atPath: sourcePath.path) {
                    do {
                        try fm.copyItem(at: sourcePath, to: destPath)
                        addLog("✅ 复制: \(file)")
                        copiedCount += 1
                        copied = true
                        break
                    } catch {
                        continue
                    }
                }
            }
            
            if !copied {
                addLog("❌ 未找到: \(file)")
            }
        }
        
        if copiedCount == 0 {
            addLog("⚠️ 警告: 未能复制任何 Python 文件")
        } else {
            addLog("✅ 复制完成: \(copiedCount)/3 个文件")
        }
    }
    
    func loadConfigs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil) else {
            addLog("配置目录为空")
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
        
        addLog("加载了 \(configs.count) 个配置")
        
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
        
        addLog("保存配置: \(config.name)")
        loadConfigs()
    }
    
    func deleteConfig(_ config: ProxyConfig) {
        let url = configDirectory.appendingPathComponent("\(config.name).json")
        try? FileManager.default.removeItem(at: url)
        
        addLog("删除配置: \(config.name)")
        loadConfigs()
    }
    
    func switchConfig(_ config: ProxyConfig) {
        activeConfig = config
        UserDefaults.standard.set(config.name, forKey: "activeConfig")
        
        addLog("切换到配置: \(config.name)")
        
        if isRunning {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.start()
            }
        }
    }
    
    func start() {
        guard let config = activeConfig else {
            addLog("错误: 没有选中的配置")
            return
        }
        guard !isRunning else { return }
        
        status = .connecting
        addLog("🚀 启动代理...")
        
        // 启动前先清理
        addLog("🧹 清理残留进程...")
        killAllClientProcesses()
        releasePort(config.socksPort)
        releasePort(config.httpPort)
        
        // 延迟启动，确保端口完全释放
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startProxyProcess(config: config)
        }
    }
    
    private func startProxyProcess(config: ProxyConfig) {
        let tempConfigPath = createTempConfig(config: config)
        let scriptPath = pythonDirectory.appendingPathComponent("client.py").path
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: pythonPath)
        process?.arguments = [scriptPath]
        process?.currentDirectoryURL = pythonDirectory
        
        var environment = ProcessInfo.processInfo.environment
        environment["SECURE_PROXY_CONFIG"] = tempConfigPath
        
        if let home = environment["HOME"] {
            let pyenvRoot = "\(home)/.pyenv"
            let currentPath = environment["PATH"] ?? ""
            
            var pathComponents = [
                "\(pyenvRoot)/shims",
                "\(pyenvRoot)/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]
            
            for component in currentPath.split(separator: ":") {
                let path = String(component)
                if !pathComponents.contains(path) {
                    pathComponents.append(path)
                }
            }
            
            environment["PATH"] = pathComponents.joined(separator: ":")
            environment["PYENV_ROOT"] = pyenvRoot
        }
        
        environment["PYTHONUNBUFFERED"] = "1"
        process?.environment = environment
        
        addLog("🐍 Python: \(pythonPath)")
        addLog("📂 工作目录: \(pythonDirectory.path)")
        addLog("📄 配置: \(config.name)")
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = pipe
        process?.standardError = errorPipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    self?.parseOutput(output)
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    self?.addLog("错误: \(output)")
                }
            }
        }
        
        do {
            try process?.run()
            isRunning = true
            status = .connected
            addLog("✅ 代理进程已启动")
            addLog("📡 SOCKS5: 127.0.0.1:\(config.socksPort)")
            addLog("📡 HTTP: 127.0.0.1:\(config.httpPort)")
        } catch {
            status = .error(error.localizedDescription)
            addLog("❌ 启动失败: \(error.localizedDescription)")
        }
    }
    
    private func createTempConfig(config: ProxyConfig) -> String {
        let configDir = pythonDirectory.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        let configPath = configDir.appendingPathComponent("active_config.json")
        
        let configDict: [String: Any] = [
            "name": config.name,
            "sni_host": config.sniHost,
            "path": config.path,
            "server_port": config.serverPort,
            "socks_port": config.socksPort,
            "http_port": config.httpPort,
            "pre_shared_key": config.preSharedKey
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: configDict, options: .prettyPrinted) {
            try? jsonData.write(to: configPath)
            addLog("✅ 配置文件已创建: \(configPath.lastPathComponent)")
        }
        
        return configPath.path
    }
    
    func stop() {
        addLog("🛑 停止代理...")
        
        // 1. 终止当前进程
        if let process = process {
            process.terminate()
            
            DispatchQueue.global().async {
                process.waitUntilExit()
            }
            
            // 强制杀死
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // 👇 将此行修改为直接 if 检查
                let pid = process.processIdentifier // processIdentifier 是 Int32，不是 Optional
                if pid > 0 {
                    // 由于 processIdentifier 是 Int32 类型，kill 函数需要 pid_t (也是 Int32)
                    kill(pid, SIGKILL)
                    // 您也可以写成：kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        
        // 2. 清理所有相关进程
        killAllClientProcesses()
        
        // 3. 释放端口
        if let config = activeConfig {
            releasePort(config.socksPort)
            releasePort(config.httpPort)
        }
        
        // 4. 重置状态
        process = nil
        isRunning = false
        status = .disconnected
        trafficUp = 0
        trafficDown = 0
        
        addLog("✅ 代理已停止")
    }
    
    private func killAllClientProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "client.py"]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                addLog("🔪 已清理残留进程")
            }
        } catch {
            // 失败不影响主流程
        }
    }
    
    private func releasePort(_ port: Int) {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .compactMap { Int($0) }
                
                for pid in pids {
                    kill(pid_t(pid), SIGKILL)
                    addLog("🔪 释放端口 \(port) (PID: \(pid))")
                }
            }
        } catch {
            // 失败不影响主流程
        }
    }
    
    func forceCleanup() {
        addLog("🧹 开始强制清理...")
        
        killAllClientProcesses()
        
        if let config = activeConfig {
            releasePort(config.socksPort)
            releasePort(config.httpPort)
        }
        
        releasePort(1080)
        releasePort(1081)
        
        process = nil
        isRunning = false
        status = .disconnected
        
        addLog("✅ 清理完成")
    }
    
    private func parseOutput(_ output: String) {
        addLog(output)
        
        if output.contains("连接成功") || output.contains("监听") {
            status = .connected
        } else if output.contains("错误") || output.contains("失败") {
            status = .error(output)
        }
    }
    
    private func startTrafficMonitor() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            
            self.trafficUp = Double.random(in: 0...100)
            self.trafficDown = Double.random(in: 0...100)
        }
    }
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 500 {
            logs.removeFirst()
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        addLog("日志已清除")
    }
    
    deinit {
        killAllClientProcesses()
        if let config = activeConfig {
            releasePort(config.socksPort)
            releasePort(config.httpPort)
        }
        timer?.invalidate()
    }
}
