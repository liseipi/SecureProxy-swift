import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ProxyManager()
    @State private var showingConfigEditor = false
    @State private var editingConfig: ProxyConfig? = nil
    @State private var showingLogs = false
    
    var body: some View {
        VStack(spacing: 0) {
            StatusBar(manager: manager, showingLogs: $showingLogs)
            
            Divider()
            
            if manager.configs.isEmpty {
                EmptyStateView(onAddConfig: {
                    createNewConfig()
                })
            } else {
                List {
                    ForEach(manager.configs) { config in
                        ConfigRow(
                            config: config,
                            isActive: manager.activeConfig?.id == config.id,
                            onSelect: { manager.switchConfig(config) },
                            onEdit: {
                                editingConfig = config
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    showingConfigEditor = true
                                }
                            },
                            onDelete: { manager.deleteConfig(config) }
                        )
                    }
                }
                .listStyle(InsetListStyle())
            }
            
            // 底部工具栏
            HStack {
                Button(action: createNewConfig) {
                    Label("添加配置", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Text("共 \(manager.configs.count) 个配置")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .sheet(item: $editingConfig) { config in
            ConfigEditor(
                config: config,
                onSave: { newConfig in
                    manager.saveConfig(newConfig)
                    editingConfig = nil
                },
                onCancel: {
                    editingConfig = nil
                }
            )
        }
        .sheet(isPresented: $showingLogs) {
            LogsView(logs: manager.logs)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
    
    private func createNewConfig() {
        let newConfig = ProxyConfig(
            name: "新配置",
            sniHost: "example.com",
            path: "/ws",
            serverPort: 443,
            socksPort: 1080,
            httpPort: 1081,
            preSharedKey: ""
        )
        // 直接设置 editingConfig，触发 sheet(item:) 自动显示
        editingConfig = newConfig
    }
}

struct EmptyStateView: View {
    let onAddConfig: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("还没有配置")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("点击下方按钮添加第一个代理配置")
                .foregroundColor(.secondary)
            
            Button(action: onAddConfig) {
                Label("添加配置", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
