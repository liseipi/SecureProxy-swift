# SecureProxy

<div align="center">

![SecureProxy](https://img.shields.io/badge/SecureProxy-v1.0.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2012.0%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.5%2B-orange.svg)
![Python](https://img.shields.io/badge/Python-3.8%2B-green.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

<p align="center">
  <img src="SecureProxy/Assets.xcassets/icon.png" width="128" height="128" alt="SystemProxy Logo">
</p>

**原生 macOS 安全代理客户端 - 极简设计，强大功能**

Swift 开发的现代化代理管理工具，提供 SOCKS5 和 HTTP 代理服务
支持 WebSocket + AES-256-GCM 加密隧道

[功能特性](#功能特性) • [快速开始](#快速开始) • [界面预览](#界面预览) • [使用指南](#使用指南) • [常见问题](#常见问题)

</div>

---

## 🖼️ 界面预览

### 主窗口
<img src="https://assets.musicses.vip/images/proxy/proxy_main.png" width="500" />

**主窗口功能区域：**
1. **状态栏**（顶部）：显示当前配置、连接状态、开关按钮
2. **流量监控**：实时上传/下载速度和端口信息
3. **配置列表**：所有已保存的配置，支持选择、编辑、删除
4. **工具栏**（底部）：添加新配置、显示配置数量

### 配置编辑器
<img src="https://assets.musicses.vip/images/proxy/proxy_add.png" width="500" />

**编辑器特性：**
- 实时输入验证（端口范围、密钥格式）
- 一键生成 64 位十六进制 PSK
- 清晰的状态指示（格式正确/错误）
- 示例文本提示

### 菜单栏
<img src="https://assets.musicses.vip/images/proxy/proxy_top.png" width="100" />

**菜单栏功能：**
- 一键查看状态和流量
- 快速启停代理
- 打开主窗口和日志
- 退出应用

### 日志窗口
<img src="https://assets.musicses.vip/images/proxy/proxy_log.png" width="400" />

**日志窗口特性：**
- 带行号的日志显示
- 彩色日志（成功=绿色，错误=红色）
- 自动滚动到最新日志
- 支持文本选择和复制
- 一键清空历史

---


## 💻 系统要求

### 最低要求
- **操作系统**：macOS 12.0 (Monterey) 或更高版本
- **Python**：3.8 或更高版本
- **RAM**：至少 256 MB 可用内存
- **磁盘空间**：约 50 MB

### Python 安装依赖
```bash
# 必需的 Python 库
pip install -r requirements.txt
```

**注意**：应用会自动检测系统中的 Python 安装，支持以下路径：
- Homebrew：`/opt/homebrew/bin/python3`
- pyenv：`~/.pyenv/shims/python3`
- 系统默认：`/usr/bin/python3`

---

## 👨‍💻 开发指南

### 项目结构

```
SecureProxy/
├── SecureProxy/
│   ├── SecureProxyApp.swift       # 应用入口
│   ├── Models/                    # 数据模型层
│   │   ├── ProxyConfig.swift      # 配置模型
│   │   └── ProxyStatus.swift      # 状态枚举
│   ├── ViewModels/                # 业务逻辑层
│   │   └── ProxyManager.swift     # 核心管理器
│   ├── Views/                     # 视图层
│   │   ├── ContentView.swift      # 主界面
│   │   ├── StatusBar.swift        # 状态栏
│   │   ├── ConfigEditor.swift     # 配置编辑器
│   │   ├── ConfigRow.swift        # 配置列表项
│   │   └── LogsView.swift         # 日志窗口
│   ├── Python/                    # Python 脚本
│   │   ├── client.py              # Python 客户端
│   │   ├── crypto.py              # 加密模块
│   │   └── tls_fingerprint.py     # TLS 指纹
│   ├── Assets.xcassets/           # 资源文件
│   │   ├── AppIcon.appiconset/    # 应用图标
│   │   └── AccentColor.colorset/  # 强调色
│   └── Info.plist                 # 应用配置
├── README.md
└── LICENSE
```

## 📞 联系方式

- **问题反馈**：[GitHub Issues](https://github.com/liseipi/SecureProxy-swift/issues)
- **讨论区**：[GitHub Discussions](https://github.com/liseipi/SecureProxy-swift/discussions)
- **邮件**：oliliu.au@gmail.com

---

**⭐ 如果这个项目对你有帮助，请给个 Star！⭐**

Made with ❤️ by SecureProxy Team
