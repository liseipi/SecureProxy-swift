// ContentView.swift
// 美化版本 - 现代化设计

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: ProxyManager
    @State private var showingConfigEditor = false
    @State private var editingConfig: ProxyConfig? = nil
    @State private var showingURLImport = false
    @State private var importURLString = ""
    @State private var hoveredConfigId: UUID? = nil
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 0.98),
                    Color(red: 0.98, green: 0.99, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 状态栏
                ModernStatusBar(manager: manager, openWindow: { id in
                    openWindow(id: id)
                })
                
                // 主内容区
                if manager.configs.isEmpty {
                    ModernEmptyStateView(
                        onAddConfig: { createNewConfig() },
                        onImport: { manager.importConfig() },
                        onQuickImport: { showingURLImport = true }
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(manager.configs) { config in
                                ModernConfigCard(
                                    config: config,
                                    isActive: manager.activeConfig?.id == config.id,
                                    isHovered: hoveredConfigId == config.id,
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
                                .onHover { isHovered in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        hoveredConfigId = isHovered ? config.id : nil
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
                
                // 底部工具栏
                ModernToolbar(
                    configCount: manager.configs.count,
                    onAddConfig: { createNewConfig() },
                    onQuickImport: { showingURLImport = true },
                    onImportClipboard: { manager.importFromClipboard() },
                    onImportFile: { manager.importConfig() },
                    onExportAll: { manager.exportAllConfigs() }
                )
            }
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
        .frame(minWidth: 750, idealWidth: 900, maxWidth: .infinity,
               minHeight: 600, idealHeight: 700, maxHeight: .infinity)
    }
    
    private func createNewConfig() {
        let newConfig = ProxyConfig(
            name: "新配置",
            sniHost: "example.com",
            proxyIP: "example.com",
            path: "/ws",
            serverPort: 443,
            socksPort: 1080,
            httpPort: 1081,
            preSharedKey: ""
        )
        editingConfig = newConfig
    }
}

// MARK: - Modern Status Bar

struct ModernStatusBar: View {
    @ObservedObject var manager: ProxyManager
    let openWindow: (String) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部信息栏
            HStack(spacing: 20) {
                // 左侧：配置信息
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        // 配置名称
                        Text(manager.activeConfig?.name ?? "未选择配置")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        
                        // 状态指示器
                        StatusPill(status: manager.status)
                    }
                    
                    // 服务器信息
                    if let config = manager.activeConfig {
                        HStack(spacing: 12) {
                            Label(config.sniHost, systemImage: "network")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            
                            if config.sniHost != config.proxyIP {
                                Label("CDN", systemImage: "server.rack")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.blue, Color.blue.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
                
                Spacer()
                
                // 右侧：控制按钮
                HStack(spacing: 12) {
                    // 查看日志按钮
                    Button(action: { openWindow("logs") }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                            Text("日志")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Color.purple, Color.purple.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(8)
                        .shadow(color: Color.purple.opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // 开关
                    Toggle("", isOn: Binding(
                        get: { manager.isRunning },
                        set: { isOn in
                            if isOn { manager.start() }
                            else { manager.stop() }
                        }
                    ))
                    .toggleStyle(ModernToggleStyle())
                    .scaleEffect(1.1)
                }
            }
            .padding(20)
            
            // 流量统计（仅在运行时显示）
            if manager.isRunning {
                TrafficStatsCard(
                    uploadSpeed: manager.trafficUp,
                    downloadSpeed: manager.trafficDown,
                    config: manager.activeConfig
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.white.opacity(0.8))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: manager.isRunning)
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let status: ProxyStatus
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(status.color.opacity(0.3))
                        .frame(width: 14, height: 14)
                        .scaleEffect(status == .connected ? 1 : 0)
                )
            
            Text(status.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(status.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(status.color.opacity(0.1))
        .cornerRadius(12)
        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: status == .connecting)
    }
}

// MARK: - Traffic Stats Card

struct TrafficStatsCard: View {
    let uploadSpeed: Double
    let downloadSpeed: Double
    let config: ProxyConfig?
    
    var body: some View {
        HStack(spacing: 20) {
            // 上传
            TrafficMetric(
                icon: "arrow.up.circle.fill",
                label: "上传",
                value: uploadSpeed,
                color: .blue
            )
            
            Divider()
                .frame(height: 40)
            
            // 下载
            TrafficMetric(
                icon: "arrow.down.circle.fill",
                label: "下载",
                value: downloadSpeed,
                color: .green
            )
            
            Spacer()
            
            // 端口信息
            if let config = config {
                HStack(spacing: 20) {
                    PortBadge(label: "SOCKS5", port: config.socksPort, color: .orange)
                    PortBadge(label: "HTTP", port: config.httpPort, color: .pink)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.9),
                            Color.white.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
}

struct TrafficMetric: View {
    let icon: String
    let label: String
    let value: Double
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(formatSpeed(value))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
            }
        }
    }
    
    private func formatSpeed(_ kbps: Double) -> String {
        if kbps < 1 {
            return String(format: "%.0f B/s", kbps * 1024)
        } else if kbps < 1024 {
            return String(format: "%.1f KB/s", kbps)
        } else {
            return String(format: "%.2f MB/s", kbps / 1024)
        }
    }
}

struct PortBadge: View {
    let label: String
    let port: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            
            Text("\(port)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }
}

// MARK: - Modern Config Card

struct ModernConfigCard: View {
    let config: ProxyConfig
    let isActive: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    let onCopyURL: () -> Void
    
    @State private var showingDeleteAlert = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：名称和状态
            HStack(spacing: 12) {
                // 名称
                HStack(spacing: 8) {
                    Text(config.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.primary)
                    
                    if isActive {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                    }
                }
                
                Spacer()
                
                // 操作按钮（悬停时显示）
                if isHovered || isActive {
                    HStack(spacing: 8) {
                        ActionButton(icon: "link.circle.fill", color: .purple, action: onCopyURL)
                        ActionButton(icon: "square.and.arrow.up", color: .green, action: onExport)
                        ActionButton(icon: "pencil.circle.fill", color: .blue, action: onEdit)
                        ActionButton(icon: "trash.circle.fill", color: .red, action: { showingDeleteAlert = true })
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(16)
            
            Divider()
                .padding(.horizontal, 16)
            
            // 中部：服务器信息
            VStack(alignment: .leading, spacing: 10) {
                // SNI Host
                InfoRow(
                    icon: "network",
                    label: "服务器",
                    value: config.sniHost,
                    color: .blue
                )
                
                // 代理模式
                if config.sniHost == config.proxyIP {
                    InfoRow(
                        icon: "checkmark.circle.fill",
                        label: "模式",
                        value: "直连",
                        color: .green
                    )
                } else {
                    InfoRow(
                        icon: "server.rack",
                        label: "CDN",
                        value: config.proxyIP,
                        color: .purple
                    )
                }
            }
            .padding(16)
            
            Divider()
                .padding(.horizontal, 16)
            
            // 底部：端口信息
            HStack(spacing: 20) {
                PortInfo(label: "SOCKS5", port: config.socksPort, color: .orange)
                PortInfo(label: "HTTP", port: config.httpPort, color: .pink)
                
                Spacer()
                
                Text(":\(config.serverPort)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                .shadow(
                    color: isActive ? Color.blue.opacity(0.2) : Color.black.opacity(isHovered ? 0.1 : 0.05),
                    radius: isActive ? 12 : (isHovered ? 8 : 4),
                    x: 0,
                    y: isActive ? 4 : 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isActive ? Color.blue.opacity(0.5) : Color.clear,
                    lineWidth: 2
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    onSelect()
                }
            }
        }
        .alert("确认删除", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("确定要删除配置 \"\(config.name)\" 吗？此操作不可恢复。")
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
    }
}

struct ActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.1))
                .cornerRadius(8)
                .scaleEffect(isPressed ? 0.9 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)
            
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }
}

struct PortInfo: View {
    let label: String
    let port: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("\(port)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Modern Empty State

struct ModernEmptyStateView: View {
    let onAddConfig: () -> Void
    let onImport: () -> Void
    let onQuickImport: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // 图标
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "tray")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(.secondary)
            }
            
            // 文字
            VStack(spacing: 8) {
                Text("还没有配置")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("添加或导入配置以开始使用")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            
            // 按钮
            HStack(spacing: 16) {
                ModernButton(
                    title: "添加配置",
                    icon: "plus.circle.fill",
                    color: .blue,
                    isPrimary: true,
                    action: onAddConfig
                )
                
                ModernButton(
                    title: "粘贴链接",
                    icon: "link.badge.plus",
                    color: .purple,
                    isPrimary: false,
                    action: onQuickImport
                )
                
                ModernButton(
                    title: "导入文件",
                    icon: "square.and.arrow.down",
                    color: .green,
                    isPrimary: false,
                    action: onImport
                )
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModernButton: View {
    let title: String
    let icon: String
    let color: Color
    let isPrimary: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(isPrimary ? .white : color)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isPrimary
                            ? LinearGradient(
                                colors: [color, color.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [color.opacity(0.15), color.opacity(0.1)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isPrimary ? Color.clear : color.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: isPrimary ? color.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
    }
}

// MARK: - Modern Toolbar

struct ModernToolbar: View {
    let configCount: Int
    let onAddConfig: () -> Void
    let onQuickImport: () -> Void
    let onImportClipboard: () -> Void
    let onImportFile: () -> Void
    let onExportAll: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // 添加配置按钮
            Button(action: onAddConfig) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加配置")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(10)
                .shadow(color: Color.blue.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            
            // 导入/导出菜单
            Menu {
                Section(header: Text("导入")) {
                    Button(action: onQuickImport) {
                        Label("粘贴链接导入", systemImage: "link.badge.plus")
                    }
                    
                    Button(action: onImportClipboard) {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    
                    Button(action: onImportFile) {
                        Label("导入 JSON 文件", systemImage: "doc.badge.arrow.up")
                    }
                }
                
                Divider()
                
                Section(header: Text("导出")) {
                    Button(action: onExportAll) {
                        Label("导出所有配置", systemImage: "square.and.arrow.up")
                    }
                    .disabled(configCount == 0)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                    Text("导入/导出")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.purple, Color.purple.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(10)
                .shadow(color: Color.purple.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            .menuStyle(BorderlessButtonMenuStyle())
            
            Spacer()
            
            // 配置数量
            HStack(spacing: 6) {
                Image(systemName: "number.circle.fill")
                    .foregroundColor(.blue)
                Text("共 \(configCount) 个配置")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.5))
            .cornerRadius(8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: -2)
        )
    }
}

// MARK: - Modern Toggle Style

struct ModernToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack {
                // 背景
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isOn ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 56, height: 32)
                
                // 滑块
                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .offset(x: configuration.isOn ? 12 : -12)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
    }
}

// MARK: - URL Import Sheet (保持原有实现)

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

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ProxyManager())
}
