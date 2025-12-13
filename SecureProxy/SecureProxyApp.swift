import SwiftUI

@main
struct SecureProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = ProxyManager()
    
    var body: some Scene {
        // 主窗口 - 使用 Window 而不是 WindowGroup
        Window("SecureProxy", id: "main") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 600, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 SecureProxy") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.applicationName: "SecureProxy",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "1.0.0",
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "安全代理客户端\n支持 SOCKS5 和 HTTP 代理",
                                attributes: [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11)]
                            )
                        ]
                    )
                }
            }
        }
        
        // 菜单栏图标
        MenuBarExtra {
            MenuBarView(appDelegate: appDelegate)
                .environmentObject(manager)
        } label: {
            MenuBarLabel(isRunning: manager.isRunning, status: manager.status)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（只显示菜单栏图标）
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关闭窗口不退出应用
        return false
    }
    
    func showMainWindow() {
        // 🔥 关键修复：激活应用程序
        NSApp.activate(ignoringOtherApps: true)
        
        // 查找主窗口（排除菜单栏弹出窗口）
        let mainWindow = NSApp.windows.first { window in
            window.contentViewController != nil &&
            !window.styleMask.contains(.nonactivatingPanel) &&
            window.title == "SecureProxy"
        }
        
        if let window = mainWindow {
            // 如果窗口已存在，直接显示
            window.makeKeyAndOrderFront(nil)
            
            // 临时设为浮动窗口以确保显示在最前面
            window.level = .floating
            window.orderFrontRegardless()
            
            // 0.5秒后恢复正常层级
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.level = .normal
            }
        } else {
            // 如果窗口不存在（首次打开），等待创建后再显示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let window = NSApp.windows.first(where: {
                    $0.contentViewController != nil &&
                    !$0.styleMask.contains(.nonactivatingPanel) &&
                    $0.title == "SecureProxy"
                }) {
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        window.level = .normal
                    }
                }
            }
        }
    }
}

// 通知名称
extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

// ===================================
// 菜单栏标签
// ===================================
struct MenuBarLabel: View {
    let isRunning: Bool
    let status: ProxyStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
            // Text("代理")  // 可选：显示文字
        }
    }
    
    private var iconName: String {
        if isRunning {
            return "network"
        } else {
            return "network.slash"
        }
    }
    
    private var iconColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
}

// ===================================
// 自定义 LabelStyle - 强制水平布局
// ===================================
struct HorizontalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

// ===================================
// 菜单栏视图 - 使用自定义 LabelStyle
// ===================================
struct MenuBarView: View {
    let appDelegate: AppDelegate
    @EnvironmentObject var manager: ProxyManager
    @State private var showingLogs = false
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // 状态信息
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: manager.status.icon)
                        .foregroundColor(manager.status.color)
                    Text(manager.status.text)
                        .font(.headline)
                    Spacer()
                }
                
                if let config = manager.activeConfig {
                    Text(config.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // 开关按钮
            Button(action: {
                if manager.isRunning {
                    manager.stop()
                } else {
                    manager.start()
                }
            }) {
                Label(manager.isRunning ? "停止代理" : "启动代理",
                      systemImage: manager.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .labelStyle(HorizontalLabelStyle())
                    .foregroundColor(manager.isRunning ? .red : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            // 流量信息
            if manager.isRunning, let config = manager.activeConfig {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    // 上传
                    Label(String(format: "%.1f KB/s", manager.trafficUp),
                          systemImage: "arrow.up.circle.fill")
                        .labelStyle(HorizontalLabelStyle())
                        .foregroundColor(.blue)
                    
                    // 下载
                    Label(String(format: "%.1f KB/s", manager.trafficDown),
                          systemImage: "arrow.down.circle.fill")
                        .labelStyle(HorizontalLabelStyle())
                        .foregroundColor(.green)
                    
                    // 端口信息
                    Text("SOCKS5: \(config.socksPort) | HTTP: \(config.httpPort)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            
            Divider()
            
            // 打开主窗口按钮
            Button(action: {
                appDelegate.showMainWindow()
                openWindow(id: "main")
            }) {
                Label("打开主窗口", systemImage: "macwindow")
                    .labelStyle(HorizontalLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            // 查看日志按钮
            Button(action: {
                showingLogs = true
            }) {
                Label("查看日志", systemImage: "doc.text")
                    .labelStyle(HorizontalLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            Divider()
            
            // 退出按钮
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("退出", systemImage: "power")
                    .labelStyle(HorizontalLabelStyle())
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: 240)
        .sheet(isPresented: $showingLogs) {
            LogsView(logs: manager.logs, onClear: {
                manager.clearLogs()
            })
        }
    }
}
