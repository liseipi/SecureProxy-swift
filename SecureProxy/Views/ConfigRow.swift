// Views/ConfigRow.swift
// 支持显示 proxy_ip 信息
import SwiftUI

struct ConfigRow: View {
    let config: ProxyConfig
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    var onCopyURL: (() -> Void)? = nil
    
    @State private var showingDeleteAlert = false
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(config.name)
                        .font(.headline)
                    
                    if isActive {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                
                // SNI Host
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(config.sniHost)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Proxy IP (新增)
                HStack(spacing: 4) {
                    if config.sniHost == config.proxyIP {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text("直连")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "server.rack")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("CDN: \(config.proxyIP)")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                
                // 端口信息
                HStack(spacing: 16) {
                    Label("\(config.socksPort)", systemImage: "s.circle.fill")
                    Label("\(config.httpPort)", systemImage: "h.circle.fill")
                }
                .font(.caption)
                .foregroundColor(.orange)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                // 复制链接按钮
                if let copyAction = onCopyURL {
                    Button(action: copyAction) {
                        Image(systemName: "link.circle.fill")
                            .font(.title3)
                            .foregroundColor(.purple)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("复制配置链接")
                }
                
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(.green)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("导出 JSON 文件")
                
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("编辑配置")
                
                Button(action: { showingDeleteAlert = true }) {
                    Image(systemName: "trash.circle.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("删除配置")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                onSelect()
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
    }
}
