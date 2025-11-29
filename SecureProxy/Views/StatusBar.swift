import SwiftUI

struct StatusBar: View {
    @ObservedObject var manager: ProxyManager
    @Binding var showingLogs: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(manager.activeConfig?.name ?? "未选择配置")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 6) {
                        Image(systemName: manager.status.icon)
                            .foregroundColor(manager.status.color)
                        Text(manager.status.text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { manager.isRunning },
                        set: { isOn in
                            if isOn {
                                manager.start()
                            } else {
                                manager.stop()
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle())
                    .scaleEffect(1.2)
                    
                    Button(action: { showingLogs = true }) {
                        Label("查看日志", systemImage: "doc.text")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            if manager.isRunning {
                VStack(spacing: 12) {
                    HStack(spacing: 30) {
                        TrafficLabel(
                            icon: "arrow.up.circle.fill",
                            title: "上传",
                            value: manager.trafficUp,
                            color: .blue
                        )
                        
                        TrafficLabel(
                            icon: "arrow.down.circle.fill",
                            title: "下载",
                            value: manager.trafficDown,
                            color: .green
                        )
                    }
                    
                    if let config = manager.activeConfig {
                        HStack(spacing: 20) {
                            PortInfoView(label: "SOCKS5", port: config.socksPort)
                            PortInfoView(label: "HTTP", port: config.httpPort)
                            PortInfoView(label: "服务器", port: config.serverPort)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct TrafficLabel: View {
    let icon: String
    let title: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(formatSpeed(value))
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
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

struct PortInfoView: View {
    let label: String
    let port: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .fontWeight(.medium)
            Text(":")
            Text("\(port)")
                .fontWeight(.semibold)
        }
    }
}
