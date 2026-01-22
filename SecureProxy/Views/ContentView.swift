// Views/ContentView.swift
// 支持 proxy_ip 的导入导出

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: ProxyManager
    @State private var showingConfigEditor = false
    @State private var editingConfig: ProxyConfig? = nil
    @State private var showingURLImport = false
    @State private var importURLString = ""
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            StatusBar(manager: manager, openWindow: { id in
                openWindow(id: id)
            })
            
            Divider()
            
            if manager.configs.isEmpty {
                EmptyStateView(
                    onAddConfig: { createNewConfig() },
                    onImport: { manager.importConfig() },
                    onQuickImport: { showingURLImport = true }
                )
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
                            onExport: { manager.exportConfig(config) },
                            onCopyURL: { manager.copyConfigURL(config) }
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
                    // ===== 导入功能 =====
                    Section(header: Text("导入配置").font(.caption).foregroundColor(.secondary)) {
                        Button(action: { showingURLImport = true }) {
                            Label("粘贴链接导入", systemImage: "link.badge.plus")
                        }
                        
                        Button(action: { manager.importFromClipboard() }) {
                            Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                        }
                        
                        Button(action: { manager.importConfig() }) {
                            Label("导入 JSON 文件", systemImage: "doc.badge.arrow.up")
                        }
                    }
                    
                    Divider()
                    
                    // ===== 导出功能 =====
                    Section(header: Text("导出配置").font(.caption).foregroundColor(.secondary)) {
                        Button(action: { manager.exportAllConfigs() }) {
                            Label("导出所有配置（JSON）", systemImage: "square.and.arrow.up")
                        }
                        .disabled(manager.configs.isEmpty)
                    }
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
        .sheet(isPresented: $showingURLImport) {
            URLImportSheet(
                urlString: $importURLString,
                onImport: {
                    manager.importFromURLString(importURLString)
                    showingURLImport = false
                    importURLString = ""
                },
                onCancel: {
                    showingURLImport = false
                    importURLString = ""
                }
            )
        }
        .frame(minWidth: 600, minHeight: 500)
    }
    
    private func createNewConfig() {
        let newConfig = ProxyConfig(
            name: "新配置",
            sniHost: "example.com",
            proxyIP: "example.com",  // 新增: 默认与 sniHost 相同（直连模式）
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
    let onQuickImport: () -> Void
    
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
                
                Button(action: onQuickImport) {
                    Label("粘贴链接导入", systemImage: "link.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                
                Button(action: onImport) {
                    Label("导入 JSON 文件", systemImage: "square.and.arrow.down")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 快速导入 Sheet
struct URLImportSheet: View {
    @Binding var urlString: String
    let onImport: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("粘贴链接导入配置")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("粘贴配置链接")
                    .font(.headline)
                
                Text("格式: wss://host:port/path?psk=xxx&socks=1080&http=1081&name=MyProxy&proxy_ip=1.1.1.1")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $urlString)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                    .border(Color.gray.opacity(0.5), width: 1)
                    .cornerRadius(4)
                
                if !urlString.isEmpty {
                    if urlString.hasPrefix("wss://") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("格式正确")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("链接应以 wss:// 开头")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("示例链接")
                    .font(.headline)
                
                Text("wss://example.com:443/ws?psk=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&socks=1080&http=1081&name=MyProxy&proxy_ip=1.1.1.1")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("导入") {
                    onImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 600, height: 450)
    }
}

// 预览
#Preview {
    ContentView()
        .environmentObject(ProxyManager())
}
