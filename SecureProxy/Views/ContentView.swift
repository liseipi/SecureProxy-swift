// Views/ContentView.swift
// 修复版本 - 支持 SwiftProxyManager

import SwiftUI

struct ContentView: View {
    // 修改：支持两种管理器类型
    @EnvironmentObject var manager: ProxyManager
    @State private var showingConfigEditor = false
    @State private var editingConfig: ProxyConfig? = nil
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            StatusBar(manager: manager, openWindow: { id in
                openWindow(id: id)
            })
            
            Divider()
            
            if manager.configs.isEmpty {
                EmptyStateView(onAddConfig: {
                    createNewConfig()
                }, onImport: {
                    manager.importConfig()
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
                            onDelete: { manager.deleteConfig(config) },
                            onExport: { manager.exportConfig(config) }
                        )
                    }
                }
                .listStyle(InsetListStyle())
            }
            
            HStack {
                Button(action: createNewConfig) {
                    Label("添加配置", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                
                Menu {
                    Button(action: { manager.importConfig() }) {
                        Label("导入配置", systemImage: "square.and.arrow.down")
                    }
                    
                    Button(action: { manager.exportAllConfigs() }) {
                        Label("导出所有配置", systemImage: "square.and.arrow.up")
                    }
                    .disabled(manager.configs.isEmpty)
                } label: {
                    Label("导入/导出", systemImage: "arrow.up.arrow.down.circle")
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
        editingConfig = newConfig
    }
}

struct EmptyStateView: View {
    let onAddConfig: () -> Void
    let onImport: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("还没有配置")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("点击下方按钮添加或导入配置")
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button(action: onAddConfig) {
                    Label("添加配置", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: onImport) {
                    Label("导入配置", systemImage: "square.and.arrow.down")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 预览
#Preview {
    ContentView()
        .environmentObject(ProxyManager())
}
