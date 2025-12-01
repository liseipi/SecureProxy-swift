import SwiftUI

struct LogsView: View {
    let logs: [String]
    @Environment(\.dismiss) var dismiss
    @State private var autoScroll = true
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("运行日志")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.switch)
                
                Button("清除") {
                    // 这里需要通过回调来清除日志
                }
                .buttonStyle(.bordered)
                
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 日志内容
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if logs.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("暂无日志")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 100)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                                LogRow(index: index, log: log)
                                    .id(index)
                            }
                        }
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logs.count) { _ in
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
            
            // 底部状态栏
            HStack {
                Text("共 \(logs.count) 条日志")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("提示: 可以选择文本进行复制")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

struct LogRow: View {
    let index: Int
    let log: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 行号
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            
            // 日志内容
            Text(log)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(logColor(for: log))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.05))
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("✅") || log.contains("成功") {
            return .green
        } else if log.contains("❌") || log.contains("错误") || log.contains("失败") {
            return .red
        } else if log.contains("⚠️") || log.contains("警告") {
            return .orange
        } else if log.contains("📋") || log.contains("📁") || log.contains("📄") {
            return .blue
        } else {
            return Color(NSColor.labelColor)
        }
    }
}
