import SwiftUI

struct ConfigEditor: View {
    @State private var name: String
    @State private var sniHost: String
    @State private var path: String
    @State private var serverPort: Int
    @State private var socksPort: Int
    @State private var httpPort: Int
    @State private var preSharedKey: String
    @State private var showingURLSheet = false
    
    let originalConfig: ProxyConfig
    let onSave: (ProxyConfig) -> Void
    let onCancel: () -> Void
    
    init(config: ProxyConfig, onSave: @escaping (ProxyConfig) -> Void, onCancel: @escaping () -> Void) {
        self.originalConfig = config
        _name = State(initialValue: config.name)
        _sniHost = State(initialValue: config.sniHost)
        _path = State(initialValue: config.path)
        _serverPort = State(initialValue: config.serverPort)
        _socksPort = State(initialValue: config.socksPort)
        _httpPort = State(initialValue: config.httpPort)
        _preSharedKey = State(initialValue: config.preSharedKey)
        self.onSave = onSave
        self.onCancel = onCancel
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(name.isEmpty ? "新建配置" : "编辑配置")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                
                // 查看配置链接按钮
                if isValidConfig {
                    Button(action: { showingURLSheet = true }) {
                        Label("查看链接", systemImage: "link.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 表单内容
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 基本信息
                    VStack(alignment: .leading, spacing: 12) {
                        Text("基本信息")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("配置名称")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("例: 我的代理服务器", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SNI 主机名")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("例: example.com", text: $sniHost)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("WebSocket 路径")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("例: /ws", text: $path)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    Divider()
                    
                    // 端口设置
                    VStack(alignment: .leading, spacing: 12) {
                        Text("端口设置")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        HStack {
                            Text("服务器端口")
                                .frame(width: 120, alignment: .leading)
                            TextField("443", value: $serverPort, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("(1-65535)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        HStack {
                            Text("SOCKS5 端口")
                                .frame(width: 120, alignment: .leading)
                            TextField("1080", value: $socksPort, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("(1024-65535)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        HStack {
                            Text("HTTP 端口")
                                .frame(width: 120, alignment: .leading)
                            TextField("1081", value: $httpPort, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("(1024-65535)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                    
                    Divider()
                    
                    // 预共享密钥
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("预共享密钥 (PSK)")
                                .font(.headline)
                                .foregroundColor(.blue)
                            Spacer()
                            Button(action: {
                                preSharedKey = generatePSK()
                            }) {
                                Label("生成密钥", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Text("64 位十六进制字符串 (0-9, a-f)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $preSharedKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .border(Color.gray.opacity(0.5), width: 1)
                            .cornerRadius(4)
                        
                        // 验证状态
                        HStack(spacing: 6) {
                            if preSharedKey.isEmpty {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                                Text("请输入密钥或点击生成")
                                    .font(.caption)
                            } else if preSharedKey.count != 64 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("长度: \(preSharedKey.count)/64")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else if !preSharedKey.allSatisfy({ $0.isHexDigit }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("只能包含 0-9, a-f")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("格式正确")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        Text("示例: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // 按钮栏
            HStack {
                Text("提示: 修改后会立即保存")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("保存") {
                    saveConfig()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidConfig)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 700)
        .sheet(isPresented: $showingURLSheet) {
            ConfigURLView(config: currentConfig)
        }
    }
    
    private var isValidConfig: Bool {
        !name.isEmpty &&
        !sniHost.isEmpty &&
        !path.isEmpty &&
        serverPort >= 1 && serverPort <= 65535 &&
        socksPort >= 1024 && socksPort <= 65535 &&
        httpPort >= 1024 && httpPort <= 65535 &&
        preSharedKey.count == 64 &&
        preSharedKey.allSatisfy { $0.isHexDigit }
    }
    
    private var currentConfig: ProxyConfig {
        ProxyConfig(
            id: originalConfig.id,
            name: name,
            sniHost: sniHost,
            path: path,
            serverPort: serverPort,
            socksPort: socksPort,
            httpPort: httpPort,
            preSharedKey: preSharedKey
        )
    }
    
    private func saveConfig() {
        onSave(currentConfig)
    }
    
    private func generatePSK() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// 配置 URL 查看视图
struct ConfigURLView: View {
    let config: ProxyConfig
    @Environment(\.dismiss) var dismiss
    @State private var copySuccess = false
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("配置链接")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("一键分享配置")
                    .font(.headline)
                
                Text("复制下方链接，发送给他人即可导入配置")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("配置链接")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if copySuccess {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("已复制")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                
                TextEditor(text: .constant(config.toURLString()))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                    .border(Color.gray.opacity(0.5), width: 1)
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }
            
            Button(action: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(config.toURLString(), forType: .string)
                copySuccess = true
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copySuccess = false
                }
            }) {
                Label("复制到剪贴板", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("如何使用")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("1.")
                            .foregroundColor(.secondary)
                        Text("点击上方按钮复制配置链接")
                            .font(.caption)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("2.")
                            .foregroundColor(.secondary)
                        Text("发送链接给需要的人")
                            .font(.caption)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("3.")
                            .foregroundColor(.secondary)
                        Text("接收方点击「导入/导出」→「快速导入」粘贴链接即可")
                            .font(.caption)
                    }
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 450)
    }
}
