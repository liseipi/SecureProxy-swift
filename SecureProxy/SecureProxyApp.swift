import SwiftUI
import AppKit

@main
struct SecureProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // ✅ 修改：使用多路复用管理器
    @StateObject private var manager = ProxyManager()
    
    var body: some Scene {
        Window("SecureProxy", id: "main") {
            ContentView()
                .environmentObject(manager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 SecureProxy") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.applicationName: "SecureProxy Swift",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "3.0.0",  // 版本号更新
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "纯 Swift 实现的安全代理客户端\n支持 SOCKS5 和 HTTP 代理\n基于 Network.framework\n✨ WebSocket 多路复用技术",
                                attributes: [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11)]
                            )
                        ]
                    )
                }
            }
        }
        
        Window("运行日志", id: "logs") {
            LogsWindowView()
                .environmentObject(manager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 800, height: 550)
        
        MenuBarExtra {
            MenuBarView(appDelegate: appDelegate)
                .environmentObject(manager)
        } label: {
            MenuBarLabel(isRunning: manager.isRunning, status: manager.status)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate (保持不变)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        let mainWindow = NSApp.windows.first { window in
            window.contentViewController != nil &&
            !window.styleMask.contains(.nonactivatingPanel) &&
            window.title == "SecureProxy"
        }
        
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            window.level = .floating
            window.orderFrontRegardless()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.level = .normal
            }
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

// MARK: - 菜单栏组件 (保持不变)
struct MenuBarLabel: View {
    let isRunning: Bool
    let status: ProxyStatus
    
    var body: some View {
        Image(systemName: isRunning ? "network" : "network.slash")
            .foregroundColor(iconColor)
    }
    
    private var iconColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        }
    }
}

struct MenuBarView: View {
    let appDelegate: AppDelegate
    
    // ✅ 修改：类型改为 ProxyManager
    @EnvironmentObject var manager: ProxyManager
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.status.color)
                            .frame(width: 8, height: 8)
                        Text(manager.status.text)
                            .font(.system(.subheadline, weight: .semibold))
                    }
                    
                    if let config = manager.activeConfig {
                        Text(config.name)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { manager.isRunning },
                    set: { newValue in
                        if newValue { manager.start() }
                        else { manager.stop() }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.03))
            
            Divider()
            
            if manager.isRunning {
                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        TrafficStatsView(title: "上行速度", value: manager.trafficUp, icon: "arrow.up.circle.fill", color: .blue)
                        Divider().frame(height: 30)
                        TrafficStatsView(title: "下行速度", value: manager.trafficDown, icon: "arrow.down.circle.fill", color: .green)
                    }
                    
                    if let config = manager.activeConfig {
                        HStack {
                            Text("SOCKS5: \(config.socksPort)")
                            Text("|")
                            Text("HTTP: \(config.httpPort)")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    }
                    
                    // ✅ 新增：多路复用状态指示
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundColor(.purple)
                        Text("多路复用")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.purple)
                    }
                }
                .padding(.vertical, 12)
                
                Divider()
            }
            
            VStack(spacing: 4) {
                MenuRowButton(title: "控制中心", icon: "macwindow") {
                    appDelegate.showMainWindow()
                    openWindow(id: "main")
                }
                
                MenuRowButton(title: "运行日志", icon: "doc.text") {
                    openWindow(id: "logs")
                }
                
                Divider().padding(.vertical, 4)
                
                MenuRowButton(title: "退出程序", icon: "power", color: .red) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
        .frame(width: 200)
    }
}

struct TrafficStatsView: View {
    let title: String
    let value: Double
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(String(format: "%.1f KB/s", value))
                .font(.system(size: 12))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.light)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MenuRowButton: View {
    let title: String
    let icon: String
    var color: Color = .primary
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .foregroundColor(color)
        .onHover { isHovered = $0 }
    }
}
