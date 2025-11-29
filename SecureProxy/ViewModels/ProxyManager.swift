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
        // 优先级顺序：
        // 1. pyenv Python (如果用户使用 pyenv)
        // 2. Homebrew Python
        // 3. 系统 Python
        let paths = [
            // pyenv Python (通过 shell 环境获取)
            shell("which python3"),
            // pyenv 全局 Python
            "\(NSHomeDirectory())/.pyenv/shims/python3",
            // Homebrew ARM Mac
            "/opt/homebrew/bin/python3",
            // Homebrew Intel Mac
            "/usr/local/bin/python3",
            // 系统 Python
            "/usr/bin/python3"
        ]
        
        let fm = FileManager.default
        for path in paths {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty && fm.fileExists(atPath: trimmedPath) {
                // 验证这个 Python 是否有所需的依赖
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
        
        // 设置环境变量，确保能找到 pyenv
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
        
        // 继承当前环境变量
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
            
            // 删除旧文件
            try? fm.removeItem(at: destPath)
            
            // 尝试多个可能的源路径
            let possiblePaths = [
                // 1. Bundle 的 Python 子目录
                Bundle.main.resourceURL?.appendingPathComponent("Python").appendingPathComponent(file),
                // 2. Bundle 根目录
                Bundle.main.resourceURL?.appendingPathComponent(file),
                // 3. Bundle.main.path 方式
                Bundle.main.path(forResource: file.replacingOccurrences(of: ".py", with: ""), ofType: "py", inDirectory: "Python").map { URL(fileURLWithPath: $0) },
                // 4. 直接在 Bundle 根
                Bundle.main.path(forResource: file.replacingOccurrences(of: ".py", with: ""), ofType: "py").map { URL(fileURLWithPath: $0) }
            ].compactMap { $0 }
            
            var copied = false
            for sourcePath in possiblePaths {
                if fm.fileExists(atPath: sourcePath.path) {
                    do {
                        try fm.copyItem(at: sourcePath, to: destPath)
                        addLog("✅ 复制: \(file) 从 \(sourcePath.lastPathComponent)")
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
            addLog("解决方案: 请手动复制文件到:")
            addLog("  \(pythonDirectory.path)")
        } else {
            addLog("✅ 复制完成: \(copiedCount)/3 个文件")
        }
        
        // 打印调试信息
        if let resourcePath = Bundle.main.resourcePath {
            addLog("📁 Bundle 路径: \(resourcePath)")
            
            // 列出 Bundle 中的 Python 文件
            if let items = try? fm.contentsOfDirectory(atPath: resourcePath) {
                let pyFiles = items.filter { $0.hasSuffix(".py") }
                if !pyFiles.isEmpty {
                    addLog("📄 Bundle 中的 .py 文件: \(pyFiles.joined(separator: ", "))")
                }
            }
            
            // 检查 Python 子目录
            let pythonSubDir = resourcePath + "/Python"
            if fm.fileExists(atPath: pythonSubDir) {
                if let items = try? fm.contentsOfDirectory(atPath: pythonSubDir) {
                    addLog("📂 Python 目录内容: \(items.joined(separator: ", "))")
                }
            }
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
        addLog("启动代理...")
        
        // 创建临时配置文件供 Python 脚本使用
        let tempConfigPath = createTempConfig(config: config)
        
        let scriptPath = pythonDirectory.appendingPathComponent("client.py").path
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: pythonPath)
        process?.arguments = [scriptPath]
        process?.currentDirectoryURL = pythonDirectory
        
        // 设置环境变量传递配置路径
        var environment = ProcessInfo.processInfo.environment
        environment["SECURE_PROXY_CONFIG"] = tempConfigPath
        process?.environment = environment
        
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
            addLog("代理已启动 - SOCKS5:\(config.socksPort) HTTP:\(config.httpPort)")
        } catch {
            status = .error(error.localizedDescription)
            addLog("启动失败: \(error.localizedDescription)")
        }
    }
    
    private func createTempConfig(config: ProxyConfig) -> String {
        // 在 Python 脚本目录创建临时配置文件
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
        process?.terminate()
        process = nil
        isRunning = false
        status = .disconnected
        trafficUp = 0
        trafficDown = 0
        addLog("代理已停止")
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
        if logs.count > 100 {
            logs.removeFirst()
        }
    }
    
    deinit {
        timer?.invalidate()
        stop()
    }
}
