#!/usr/bin/env python3

import asyncio
import ssl
import os
import hmac
import json
import socket
import struct
import time
import base64
import hashlib
from collections import deque
from dataclasses import dataclass
from typing import Optional, Dict
from crypto import derive_keys, encrypt, decrypt

# ==================== 清除环境变量 ====================
def clear_system_proxy():
    """清除代理环境变量"""
    proxy_vars = [
        'HTTP_PROXY', 'HTTPS_PROXY', 'FTP_PROXY', 'SOCKS_PROXY',
        'http_proxy', 'https_proxy', 'ftp_proxy', 'socks_proxy',
        'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy'
    ]

    cleared = []
    for var in proxy_vars:
        if var in os.environ:
            cleared.append(f"{var}={os.environ[var]}")
            del os.environ[var]

    if cleared:
        print("🛡️  已清除系统代理环境变量:")
        for item in cleared:
            print(f"   - {item}")
        print()

# 立即清除代理
clear_system_proxy()

# ==================== 自动提高文件描述符限制 ====================
def fix_fd_limit():
    """启动时自动提高文件描述符限制"""
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)

        if soft < 10240:
            import sys
            target = min(10240 if sys.platform == 'darwin' else 65535, hard)
            try:
                resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
                new_soft, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
                print(f"✅ 已提高文件描述符限制: {soft} -> {new_soft}")
            except:
                print(f"⚠️  无法自动提高限制，请手动执行: ulimit -n {target}")
    except:
        pass

# 调用修复函数
fix_fd_limit()

# ==================== 配置 ====================
@dataclass
class Config:
    # 服务器配置
    sni_host: str
    path: str
    server_port: int
    pre_shared_key: str

    # 本地代理配置
    socks_port: int
    http_port: int

    # 缓冲区配置
    buffer_size: int = 131072  # 128KB 固定缓冲区

    # 连接池配置
    pool_size: int = 5  # 预先建立的连接数
    pool_min: int = 2  # 最小保持连接数
    pool_max: int = 20  # 最大连接数

    # 超时配置
    connect_timeout: int = 10
    handshake_timeout: int = 30
    read_timeout: int = 0  # 0 = 无限制
    write_timeout: int = 30

    # 重连配置
    reconnect_delay: int = 1
    max_reconnect_attempts: int = 3

    # WebSocket 配置
    ws_ping_interval: int = 60
    ws_ping_timeout: int = 120

def load_config() -> Config:
    """加载配置文件"""
    import sys

    try:
        # 加载所有配置
        config_dir = "config"

        # 读取活跃配置名称
        active_path = os.path.join(config_dir, "active.txt")
        with open(active_path, 'r') as f:
            active_name = f.read().strip()

        # 读取配置文件
        config_file = os.path.join(config_dir, f"{active_name}.json")
        if not active_name.endswith('.json'):
            config_file = os.path.join(config_dir, f"{active_name}.json")

        with open(config_file, 'r') as f:
            data = json.load(f)

        return Config(
            sni_host=data['sni_host'],
            path=data['path'],
            server_port=data.get('server_port', 443),
            pre_shared_key=data['pre_shared_key'],
            socks_port=data['socks_port'],
            http_port=data['http_port']
        )
    except Exception as e:
        print(f"❌ 加载配置失败: {e}")
        sys.exit(1)

# 加载配置文件二选一，默认 load_config()
#config = load_config()

def load_config_from_env() -> Config:
    """从环境变量读取配置"""
    try:
        # Swift 端会通过环境变量传递 JSON 配置
        config_json = os.environ.get('SECURE_PROXY_CONFIG')

        if not config_json:
            print("❌ 错误: 未找到配置 (SECURE_PROXY_CONFIG 环境变量)")
            return None

        config = json.loads(config_json)

        # 验证必需字段
        required_fields = ['name', 'sni_host', 'path', 'server_port',
                          'socks_port', 'http_port', 'pre_shared_key']

        for field in required_fields:
            if field not in config:
                print(f"❌ 错误: 配置缺少字段 '{field}'")
                return None

        print(f"✅ 加载配置: {config['name']}")
        print(f"   - 服务器: {config['sni_host']}:{config['server_port']}")
        print(f"   - 路径: {config['path']}")
        print(f"   - SOCKS5: {config['socks_port']}")
        print(f"   - HTTP: {config['http_port']}")

        return Config(
            sni_host=config['sni_host'],
            path=config['path'],
            server_port=config.get('server_port', 443),
            pre_shared_key=config['pre_shared_key'],
            socks_port=config['socks_port'],
            http_port=config['http_port']
        )

    except json.JSONDecodeError as e:
        print(f"❌ 配置 JSON 解析失败: {e}")
        return None
    except Exception as e:
        print(f"❌ 加载配置失败: {e}")
        return None

# 加载配置文件二选一，load_config_from_env()在xCode中开启，请保留
config = load_config_from_env()

# ==================== 统计信息 ====================
class Stats:
    def __init__(self):
        self.active_connections = 0
        self.total_connections = 0
        self.total_bytes_sent = 0
        self.total_bytes_recv = 0
        self.errors = 0
        self.lock = asyncio.Lock()

    async def connection_start(self):
        async with self.lock:
            self.active_connections += 1
            self.total_connections += 1

    async def connection_end(self):
        async with self.lock:
            self.active_connections -= 1

    async def add_traffic(self, sent: int, recv: int):
        async with self.lock:
            self.total_bytes_sent += sent
            self.total_bytes_recv += recv

    async def add_error(self):
        async with self.lock:
            self.errors += 1

    async def get_stats(self) -> dict:
        async with self.lock:
            return {
                "active": self.active_connections,
                "total": self.total_connections,
                "sent_mb": self.total_bytes_sent / 1024 / 1024,
                "recv_mb": self.total_bytes_recv / 1024 / 1024,
                "errors": self.errors
            }

stats = Stats()

# ==================== 🔧 底层 WebSocket 实现（绕过代理检测）====================
class DirectWebSocket:
    """
    直接使用 TCP 连接实现的 WebSocket 客户端
    完全绕过 websockets 库的代理检测机制
    """

    def __init__(self):
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self.closed = False

    async def connect_direct(self, host: str, port: int, path: str) -> bool:
        """使用底层 TCP 直连（完全绕过代理）"""
        try:
            # 🔧 核心：使用 asyncio.open_connection 直接连接
            # 不使用 websockets 库，避免代理检测

            # 1. 创建 SSL 上下文
            ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2

            # 2. 直接建立 TLS 连接（绕过任何代理）
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_connection(
                    host, port,
                    ssl=ssl_context,
                    server_hostname=host
                ),
                timeout=config.connect_timeout
            )

            # 3. 手动完成 WebSocket 握手
            if not await self._websocket_handshake(host, path):
                raise Exception("WebSocket 握手失败")

            self.closed = False
            return True

        except Exception as e:
            print(f"⚠️  直连失败: {e}")
            if self.writer:
                self.writer.close()
                try:
                    await self.writer.wait_closed()
                except:
                    pass
            return False

    async def _websocket_handshake(self, host: str, path: str) -> bool:
        """手动执行 WebSocket 握手协议"""
        try:
            # 生成 WebSocket 握手密钥
            ws_key = base64.b64encode(os.urandom(16)).decode('ascii')

            # 构建 HTTP 升级请求
            handshake = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {ws_key}\r\n"
                f"Sec-WebSocket-Version: 13\r\n"
                f"\r\n"
            )

            # 发送握手请求
            self.writer.write(handshake.encode('utf-8'))
            await self.writer.drain()

            # 读取响应
            response = b""
            while b"\r\n\r\n" not in response:
                chunk = await asyncio.wait_for(
                    self.reader.read(1024),
                    timeout=5
                )
                if not chunk:
                    return False
                response += chunk

            # 验证握手响应
            response_str = response.decode('utf-8', errors='ignore')

            if "101 Switching Protocols" not in response_str:
                print(f"⚠️  WebSocket 握手失败: {response_str[:200]}")
                return False

            # 验证 Sec-WebSocket-Accept
            expected_accept = base64.b64encode(
                hashlib.sha1(
                    (ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()
            ).decode('ascii')

            if f"Sec-WebSocket-Accept: {expected_accept}" not in response_str:
                print(f"⚠️  WebSocket Accept 验证失败")
                return False

            return True

        except Exception as e:
            print(f"⚠️  WebSocket 握手异常: {e}")
            return False

    async def send(self, data: bytes):
        """发送 WebSocket 数据帧"""
        if self.closed or not self.writer:
            raise Exception("连接已关闭")

        # 构建 WebSocket 数据帧（Binary，有掩码）
        frame = self._build_frame(data)
        self.writer.write(frame)
        await self.writer.drain()

    async def recv(self) -> bytes:
        """接收 WebSocket 数据帧"""
        if self.closed or not self.reader:
            raise Exception("连接已关闭")

        # 读取帧头（至少 2 字节）
        header = await self.reader.readexactly(2)

        fin = (header[0] & 0x80) != 0
        opcode = header[0] & 0x0F
        masked = (header[1] & 0x80) != 0
        payload_len = header[1] & 0x7F

        # 处理扩展长度
        if payload_len == 126:
            payload_len = struct.unpack(">H", await self.reader.readexactly(2))[0]
        elif payload_len == 127:
            payload_len = struct.unpack(">Q", await self.reader.readexactly(8))[0]

        # 读取掩码（服务端发来的帧不应该有掩码，但要兼容）
        if masked:
            mask = await self.reader.readexactly(4)

        # 读取 payload
        if payload_len > 0:
            payload = await self.reader.readexactly(payload_len)

            # 如果有掩码，解码
            if masked:
                payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
        else:
            payload = b""

        # 处理不同的操作码
        if opcode == 0x8:  # Close
            self.closed = True
            raise Exception("服务器关闭连接")
        elif opcode == 0x9:  # Ping
            # 自动回复 Pong
            await self.send_pong(payload)
            return await self.recv()  # 继续读取下一帧
        elif opcode == 0xA:  # Pong
            return await self.recv()  # 继续读取下一帧
        elif opcode in (0x1, 0x2):  # Text or Binary
            return payload
        else:
            # 未知操作码，继续读取
            return await self.recv()

    def _build_frame(self, data: bytes, opcode: int = 0x2) -> bytes:
        """构建 WebSocket 数据帧（客户端必须使用掩码）"""
        frame = bytearray()

        # 第一字节：FIN + opcode
        frame.append(0x80 | opcode)

        # 第二字节：MASK + payload length
        length = len(data)
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame.extend(struct.pack(">H", length))
        else:
            frame.append(0x80 | 127)
            frame.extend(struct.pack(">Q", length))

        # 掩码密钥（客户端必须使用）
        mask = os.urandom(4)
        frame.extend(mask)

        # 掩码化的 payload
        masked_data = bytes(data[i] ^ mask[i % 4] for i in range(length))
        frame.extend(masked_data)

        return bytes(frame)

    async def send_pong(self, data: bytes = b""):
        """发送 Pong 帧"""
        frame = self._build_frame(data, opcode=0xA)
        self.writer.write(frame)
        await self.writer.drain()

    async def close(self):
        """关闭连接"""
        if not self.closed and self.writer:
            self.closed = True
            try:
                # 发送关闭帧
                close_frame = self._build_frame(b"", opcode=0x8)
                self.writer.write(close_frame)
                await self.writer.drain()
            except:
                pass

            try:
                self.writer.close()
                await self.writer.wait_closed()
            except:
                pass

# ==================== WebSocket 连接（使用直连实现）====================
class SecureWebSocket:
    """安全的 WebSocket 连接（使用直连绕过代理）"""

    def __init__(self):
        self.ws: Optional[DirectWebSocket] = None
        self.send_key: Optional[bytes] = None
        self.recv_key: Optional[bytes] = None
        self.closed = False
        self.in_use = False

    async def connect(self) -> bool:
        """建立 WebSocket 连接并完成握手（使用直连）"""
        try:
            # 使用底层直连实现
            self.ws = DirectWebSocket()

            if not await self.ws.connect_direct(
                config.sni_host,
                config.server_port,
                config.path
            ):
                return False

            # 密钥交换
            client_pub = os.urandom(32)
            await self.ws.send(client_pub)

            server_pub = await asyncio.wait_for(
                self.ws.recv(),
                timeout=config.handshake_timeout
            )

            if len(server_pub) != 32:
                raise Exception("服务器公钥长度错误")

            # 密钥派生
            salt = client_pub + server_pub
            psk = bytes.fromhex(config.pre_shared_key)
            temp_k1, temp_k2 = derive_keys(psk, salt)

            # 注意：客户端和服务端的密钥顺序相反
            self.send_key = temp_k1
            self.recv_key = temp_k2

            # 认证
            auth_digest = hmac.new(self.send_key, b"auth", digestmod='sha256').digest()
            await self.ws.send(auth_digest)

            auth_response = await asyncio.wait_for(
                self.ws.recv(),
                timeout=config.handshake_timeout
            )

            expected = hmac.new(self.recv_key, b"ok", digestmod='sha256').digest()
            if not hmac.compare_digest(auth_response, expected):
                raise Exception("认证失败")

            self.closed = False
            return True

        except Exception as e:
            print(f"⚠️  连接失败: {e}")
            if self.ws:
                await self.ws.close()
            return False

    async def send_connect(self, target: str) -> bool:
        """发送 CONNECT 命令"""
        try:
            connect_cmd = f"CONNECT {target}".encode('utf-8')
            encrypted = encrypt(self.send_key, connect_cmd)

            await self.ws.send(encrypted)

            response = await asyncio.wait_for(
                self.ws.recv(),
                timeout=config.handshake_timeout
            )

            plaintext = decrypt(self.recv_key, response)

            return plaintext == b"OK"

        except Exception:
            return False

    async def send(self, data: bytes):
        """发送数据"""
        encrypted = encrypt(self.send_key, data)
        await self.ws.send(encrypted)

    async def recv(self) -> Optional[bytes]:
        """接收数据"""
        if config.read_timeout > 0:
            encrypted = await asyncio.wait_for(
                self.ws.recv(),
                timeout=config.read_timeout
            )
        else:
            encrypted = await self.ws.recv()

        return decrypt(self.recv_key, encrypted)

    async def close(self):
        """关闭连接"""
        if not self.closed and self.ws:
            self.closed = True
            try:
                await self.ws.close()
            except:
                pass

# ==================== 连接处理 ====================
class ProxyConnection:
    """单个代理连接"""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        self.ws: Optional[SecureWebSocket] = None
        self.closed = False
        self.bytes_sent = 0
        self.bytes_recv = 0

    async def setup(self, target: str) -> bool:
        """建立到服务器的连接"""
        # 创建新的 WebSocket 连接
        self.ws = SecureWebSocket()

        # 尝试连接（带重试）
        for attempt in range(config.max_reconnect_attempts):
            if await self.ws.connect():
                # 发送 CONNECT 命令
                if await self.ws.send_connect(target):
                    return True

                # CONNECT 失败，关闭并重试
                await self.ws.close()

            if attempt < config.max_reconnect_attempts - 1:
                await asyncio.sleep(config.reconnect_delay)

        return False

    async def forward_local_to_remote(self):
        """转发：本地 -> 远程"""
        try:
            while not self.closed:
                # 读取本地数据（使用标准的 read 方法）
                data = await self.reader.read(config.buffer_size)

                if not data:
                    break

                # 发送到远程
                await self.ws.send(data)

                self.bytes_sent += len(data)

        except asyncio.CancelledError:
            raise
        except Exception:
            pass

    async def forward_remote_to_local(self):
        """转发：远程 -> 本地"""
        try:
            while not self.closed:
                # 接收远程数据
                data = await self.ws.recv()

                if not data:
                    break

                # 写入本地
                self.writer.write(data)
                await self.writer.drain()

                self.bytes_recv += len(data)

        except asyncio.CancelledError:
            raise
        except Exception:
            pass

    async def cleanup(self):
        """清理资源"""
        if self.closed:
            return

        self.closed = True

        # 记录流量
        await stats.add_traffic(self.bytes_sent, self.bytes_recv)

        # 关闭 WebSocket
        if self.ws:
            await self.ws.close()

        # 关闭本地连接
        if not self.writer.is_closing():
            try:
                self.writer.close()
                await asyncio.wait_for(self.writer.wait_closed(), timeout=1)
            except:
                pass

# ==================== SOCKS5 处理 ====================
async def handle_socks5(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """处理 SOCKS5 连接"""
    await stats.connection_start()

    conn = ProxyConnection(reader, writer)

    try:
        # SOCKS5 握手
        data = await asyncio.wait_for(reader.readexactly(2), timeout=5)
        if data[0] != 0x05:
            return

        nmethods = data[1]
        await reader.readexactly(nmethods)

        writer.write(b"\x05\x00")
        await writer.drain()

        # 读取请求
        data = await asyncio.wait_for(reader.readexactly(4), timeout=5)
        if data[1] != 0x01:  # 只支持 CONNECT
            return

        addr_type = data[3]

        # 解析地址
        if addr_type == 1:  # IPv4
            addr = socket.inet_ntoa(await reader.readexactly(4))
        elif addr_type == 3:  # 域名
            length = ord(await reader.readexactly(1))
            addr = (await reader.readexactly(length)).decode('utf-8')
        else:
            return

        port = int.from_bytes(await reader.readexactly(2), "big")
        target = f"{addr}:{port}"

        # 建立代理连接
        if not await conn.setup(target):
            # 连接失败
            writer.write(b"\x05\x05\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            await writer.drain()
            await stats.add_error()
            return

        # 连接成功
        writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
        await writer.drain()

        # 双向转发
        forward_tasks = [
            asyncio.create_task(conn.forward_local_to_remote()),
            asyncio.create_task(conn.forward_remote_to_local())
        ]

        done, pending = await asyncio.wait(
            forward_tasks,
            return_when=asyncio.FIRST_COMPLETED
        )

        for task in pending:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    except Exception:
        await stats.add_error()

    finally:
        await conn.cleanup()
        await stats.connection_end()

# ==================== HTTP 处理 ====================
async def handle_http(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """处理 HTTP CONNECT"""
    await stats.connection_start()

    conn = ProxyConnection(reader, writer)

    try:
        # 读取请求行
        line = await asyncio.wait_for(reader.readline(), timeout=5)

        if not line or not line.startswith(b"CONNECT"):
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            await writer.drain()
            return

        # 解析目标
        parts = line.decode('utf-8').strip().split()
        if len(parts) < 2:
            return

        host_port = parts[1]
        if ":" in host_port:
            host, port = host_port.split(":", 1)
        else:
            host = host_port
            port = "443"

        target = f"{host}:{port}"

        # 跳过请求头
        while True:
            header = await reader.readline()
            if header in (b'\r\n', b'\n', b''):
                break

        # 建立代理连接
        if not await conn.setup(target):
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await writer.drain()
            await stats.add_error()
            return

        # 连接成功
        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()

        # 双向转发
        forward_tasks = [
            asyncio.create_task(conn.forward_local_to_remote()),
            asyncio.create_task(conn.forward_remote_to_local())
        ]

        done, pending = await asyncio.wait(
            forward_tasks,
            return_when=asyncio.FIRST_COMPLETED
        )

        for task in pending:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    except Exception:
        await stats.add_error()

    finally:
        await conn.cleanup()
        await stats.connection_end()

# ==================== 监控 ====================
async def stats_monitor():
    """定期输出统计信息"""
    last_time = time.time()
    last_sent = 0
    last_recv = 0

    while True:
        await asyncio.sleep(10)

        current_stats = await stats.get_stats()
        current_time = time.time()
        elapsed = current_time - last_time

        # 计算速率
        sent_rate = (current_stats['sent_mb'] * 1024 - last_sent) / elapsed
        recv_rate = (current_stats['recv_mb'] * 1024 - last_recv) / elapsed

        print(f"📊 活跃: {current_stats['active']} | "
              f"总计: {current_stats['total']} | "
              f"↑{sent_rate:.1f}KB/s ↓{recv_rate:.1f}KB/s | "
              f"错误: {current_stats['errors']}")

        last_time = current_time
        last_sent = current_stats['sent_mb'] * 1024
        last_recv = current_stats['recv_mb'] * 1024

# ==================== 启动服务器 ====================
async def start_servers():
    """启动代理服务器"""
    socks_server = await asyncio.start_server(
        handle_socks5,
        "127.0.0.1",
        config.socks_port,
        backlog=128
    )

    http_server = await asyncio.start_server(
        handle_http,
        "127.0.0.1",
        config.http_port,
        backlog=128
    )

    print("=" * 70)
    print("🚀 SecureProxy Client v2.2")
    print("=" * 70)
    print(f"✅ SOCKS5: 127.0.0.1:{config.socks_port}")
    print(f"✅ HTTP: 127.0.0.1:{config.http_port}")
    print(f"🔐 加密: AES-256-GCM")
    print(f"\n🔧 优化配置:")
    print(f"   • 缓冲区大小: {config.buffer_size // 1024}KB (固定)")
    print(f"   • 读取超时: {'无限制' if config.read_timeout == 0 else f'{config.read_timeout}秒'}")
    print(f"   • 自动重连: 最多 {config.max_reconnect_attempts} 次")
    print(f"   • WebSocket 心跳: {config.ws_ping_interval}秒")
    print(f"\n💡 核心改进:")
    print(f"   • 固定缓冲区，零动态分配")
    print(f"   • 自动重连机制")
    print(f"   • 简化错误处理")
    print(f"   • ✨ 底层 TCP 直连（彻底绕过代理检测）")
    print(f"   • ✨ 手动实现 WebSocket 协议（不依赖 websockets 库）")
    print("=" * 70)

    async with socks_server, http_server:
        await asyncio.gather(
            socks_server.serve_forever(),
            http_server.serve_forever()
        )

# ==================== 主函数 ====================
async def main():
    """主协程"""
    await asyncio.gather(
        start_servers(),
        stats_monitor()
    )

if __name__ == "__main__":
    import sys

    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

    print("\n🔧 SecureProxy Client v2.2 启动中...")
    print("=" * 70)

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\n👋 用户停止")
    except Exception as e:
        print(f"\n❌ 启动失败: {e}")
        import traceback
        traceback.print_exc()
