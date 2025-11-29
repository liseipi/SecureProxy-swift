import SwiftUI

struct ConfigEditor: View {
    @State private var name: String
    @State private var sniHost: String
    @State private var path: String
    @State private var serverPort: Int
    @State private var socksPort: Int
    @State private var httpPort: Int
    @State private var preSharedKey: String
    
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
    
    private func saveConfig() {
        var newConfig = originalConfig
        newConfig.name = name
        newConfig.sniHost = sniHost
        newConfig.path = path
        newConfig.serverPort = serverPort
        newConfig.socksPort = socksPort
        newConfig.httpPort = httpPort
        newConfig.preSharedKey = preSharedKey
        onSave(newConfig)
    }
    
    private func generatePSK() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
