// SecureProxyApp.swift
// 完全修复版本 - 使用 SwiftProxyManager
import SwiftUI

@main
struct SecureProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = ProxyManager()  // 使用新的管理器
    
    var body: some Scene {
        // 主窗口
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
                            NSApplication.AboutPanelOptionKey.applicationName: "SecureProxy Swift",
                            NSApplication.AboutPanelOptionKey.applicationVersion: "2.0.0",
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "纯 Swift 实现的安全代理客户端\n支持 SOCKS5 和 HTTP 代理\n基于 Network.framework",
                                attributes: [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11)]
                            )
                        ]
                    )
                }
            }
        }
        
        // 日志窗口
        Window("运行日志", id: "logs") {
            LogsWindowView()
                .environmentObject(manager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 700, height: 450)
        
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

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

struct MenuBarLabel: View {
    let isRunning: Bool
    let status: ProxyStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
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
        }
    }
}

struct HorizontalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

struct MenuBarView: View {
    let appDelegate: AppDelegate
    @EnvironmentObject var manager: ProxyManager
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
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
                
                // Swift 版本标识
                HStack {
                    Image(systemName: "swift")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("Swift 原生实现")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
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
            
            if manager.isRunning, let config = manager.activeConfig {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(format: "%.1f KB/s", manager.trafficUp),
                          systemImage: "arrow.up.circle.fill")
                        .labelStyle(HorizontalLabelStyle())
                        .foregroundColor(.blue)
                    
                    Label(String(format: "%.1f KB/s", manager.trafficDown),
                          systemImage: "arrow.down.circle.fill")
                        .labelStyle(HorizontalLabelStyle())
                        .foregroundColor(.green)
                    
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
            
            Button(action: {
                openWindow(id: "logs")
            }) {
                Label("查看日志", systemImage: "doc.text")
                    .labelStyle(HorizontalLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            Divider()
            
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
        .frame(width: 260)
    }
}
