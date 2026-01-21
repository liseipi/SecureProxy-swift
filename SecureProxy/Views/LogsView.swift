import SwiftUI

// ✅ 新增：日志窗口包装器
struct LogsWindowView: View {
    @EnvironmentObject var manager: ProxyManager
    
    var body: some View {
        LogsView(logs: manager.logs, onClear: {
            manager.clearLogs()
        })
    }
}

// 原有的 LogsView 保持不变
struct LogsView: View {
    let logs: [String]
    let onClear: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var autoScroll = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("运行日志")
                    .font(.headline)
                
                Spacer()
                
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                
                Button(action: {
                    onClear()
                }) {
                    Label("清除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(logs.isEmpty)
                
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if logs.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                Text("暂无日志")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 60)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                                LogRow(index: index, log: log)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logs.count) { oldValue, newValue in
                    if autoScroll, let lastIndex = logs.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let lastIndex = logs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
            
            HStack {
                Text("共 \(logs.count) 条")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("可选择文本复制")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct LogRow: View {
    let index: Int
    let log: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            
            Text(log)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(logColor(for: log))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
        }
        .padding(.vertical, 1)
        .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.03))
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("✅") || log.contains("成功") || log.contains("连接成功") {
            return .green
        } else if log.contains("❌") || log.contains("错误") || log.contains("失败") {
            return .red
        } else if log.contains("⚠️") || log.contains("警告") {
            return .orange
        } else if log.contains("🔗") || log.contains("连接") || log.contains("启动") {
            return .blue
        } else {
            return Color(NSColor.labelColor)
        }
    }
}
