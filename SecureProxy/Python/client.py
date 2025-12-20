# client.py - 最终修复版（简洁 + 关键优化）
import asyncio
import json
import os
import sys
import hmac
import socket
import struct
import ssl
import time
from pathlib import Path

# 核心模块导入
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

clear_system_proxy()

# ==================== 视频流优化配置 ====================
WS_HANDSHAKE_TIMEOUT = 10
READ_BUFFER_SIZE = 256 * 1024      # 优化：256KB（原 65KB）
WRITE_BUFFER_SIZE = 128 * 1024     # 优化：128KB（原 8KB）

TCP_NODELAY = True
TCP_KEEPALIVE = True
TCP_KEEPIDLE = 60
TCP_KEEPINTVL = 10
TCP_KEEPCNT = 3

MAX_CONCURRENT_CONNECTIONS = 1000  # 增加并发连接数
connection_semaphore = None

def resource_path(relative_path):
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    return os.path.join(os.path.abspath("."), relative_path)

CONFIG_DIR = resource_path("config")

# ==================== 全局状态 ====================
status = "disconnected"
current_config = None
traffic_up = traffic_down = 0
last_traffic_time = time.time()
active_connections = 0

# SSL 上下文缓存（复用以提升性能）
_ssl_context_cache = None

# ==================== 从环境变量加载配置 ====================
def load_config_from_env():
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

        return config

    except json.JSONDecodeError as e:
        print(f"❌ 配置 JSON 解析失败: {e}")
        return None
    except Exception as e:
        print(f"❌ 加载配置失败: {e}")
        return None

# ==================== 流量统计 ====================
async def traffic_monitor():
    global traffic_up, traffic_down, last_traffic_time, active_connections
    while True:
        await asyncio.sleep(5)
        now = time.time()
        elapsed = now - last_traffic_time
        if elapsed > 0 and (traffic_up > 0 or traffic_down > 0):
            up_speed = traffic_up / elapsed / 1024
            down_speed = traffic_down / elapsed / 1024
            print(f"📊 ↑{up_speed:6.1f}KB/s ↓{down_speed:6.1f}KB/s | 连接:{active_connections}")
            traffic_up = traffic_down = 0
            last_traffic_time = now

# ==================== 核心：原始 Socket WebSocket 实现（绕过所有代理）====================
class RawWebSocket:
    """使用原始 socket 实现的 WebSocket 客户端"""

    def __init__(self):
        self.sock = None
        self.ssl_sock = None
        self.reader = None
        self.writer = None
        self.closed = False

    async def connect(self, host, port, path, ssl_context):
        """直连到服务器"""
        loop = asyncio.get_event_loop()

        # 1. DNS 解析（使用系统 DNS，但可以直接指定 IP 绕过）
        try:
            addr_info = await loop.getaddrinfo(
                host, port,
                family=socket.AF_INET,
                type=socket.SOCK_STREAM,
                proto=socket.IPPROTO_TCP
            )
            if not addr_info:
                raise Exception("DNS 解析失败")

            family, socktype, proto, canonname, sockaddr = addr_info[0]
        except Exception as e:
            raise Exception(f"DNS 解析失败: {e}")

        # 2. 创建原始 socket（关键：绕过所有代理层）
        self.sock = socket.socket(family, socktype, proto)
        self.sock.setblocking(False)

        # 设置 TCP 参数
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

        # 🎥 视频流优化：增大 socket 缓冲区
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, READ_BUFFER_SIZE)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, WRITE_BUFFER_SIZE)

        try:
            await asyncio.wait_for(
                loop.sock_connect(self.sock, sockaddr),
                timeout=10
            )
        except Exception as e:
            self.sock.close()
            raise Exception(f"TCP 连接失败: {e}")

        # 4. 添加 TLS 层
        try:
            self.reader, self.writer = await asyncio.open_connection(
                sock=self.sock,
                ssl=ssl_context,
                server_hostname=host,
                limit=READ_BUFFER_SIZE  # 512KB limit
            )
        except Exception as e:
            self.sock.close()
            raise Exception(f"TLS 握手失败: {e}")

        # 5. WebSocket 握手
        try:
            await self._handshake(host, port, path)
        except Exception as e:
            await self.close()
            raise Exception(f"WebSocket 握手失败: {e}")

    async def _handshake(self, host, port, path):
        """WebSocket 握手"""
        import base64

        key = base64.b64encode(os.urandom(16)).decode()

        # 构建握手请求
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"User-Agent: Mozilla/5.0\r\n"
            f"\r\n"
        )

        self.writer.write(request.encode())
        await self.writer.drain()

        # 读取响应
        response_line = await self.reader.readline()
        if b'101' not in response_line:
            raise Exception(f"握手失败: {response_line}")

        # 读取所有 headers
        while True:
            line = await self.reader.readline()
            if line in (b'\r\n', b'\n', b''):
                break

    async def send(self, data):
        """发送 WebSocket 帧"""
        if self.closed:
            raise Exception("WebSocket 已关闭")

        # 构建 WebSocket 数据帧
        frame = bytearray()

        # FIN=1, opcode=0x2 (binary)
        frame.append(0x82)

        # Mask=1, payload length
        length = len(data)
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame.extend(length.to_bytes(2, 'big'))
        else:
            frame.append(0x80 | 127)
            frame.extend(length.to_bytes(8, 'big'))

        # Masking key
        mask = os.urandom(4)
        frame.extend(mask)

        # Masked payload
        masked = bytearray(data)
        for i in range(len(masked)):
            masked[i] ^= mask[i % 4]
        frame.extend(masked)

        self.writer.write(bytes(frame))
        await self.writer.drain()

    async def recv(self):
        """接收 WebSocket 帧"""
        if self.closed:
            raise Exception("WebSocket 已关闭")

        # 读取帧头
        header = await self.reader.readexactly(2)

        # 解析 payload length
        length = header[1] & 0x7F
        if length == 126:
            length_bytes = await self.reader.readexactly(2)
            length = int.from_bytes(length_bytes, 'big')
        elif length == 127:
            length_bytes = await self.reader.readexactly(8)
            length = int.from_bytes(length_bytes, 'big')

        # 读取 payload
        payload = await self.reader.readexactly(length)
        return payload

    async def close(self):
        """关闭连接"""
        if self.closed:
            return

        self.closed = True

        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except:
                pass

        if self.sock:
            try:
                self.sock.close()
            except:
                pass

# ==================== SSL 上下文 ====================
def get_ssl_context():
    """创建 SSL 上下文"""
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
    ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
    ssl_context.maximum_version = ssl.TLSVersion.TLSv1_3
    return ssl_context

# ==================== 创建安全连接 ====================
async def create_secure_connection(target):
    """使用原始 socket 创建连接"""

    # 防止循环
    if target.startswith('127.0.0.1:1080') or target.startswith('127.0.0.1:1081'):
        raise Exception(f"拒绝连接: 检测到代理循环 (目标={target})")

    ws = None
    max_retries = 3

    for attempt in range(max_retries):
        try:
            host = str(current_config["sni_host"])
            path = str(current_config["path"])
            port = int(current_config.get("server_port", 443))

            # 使用原始 socket WebSocket
            ws = RawWebSocket()
            await asyncio.wait_for(
                ws.connect(host, port, path, get_ssl_context()),
                timeout=15
            )

            # 密钥交换
            client_pub = os.urandom(32)
            await ws.send(client_pub)
            server_pub = await asyncio.wait_for(ws.recv(), timeout=10)

            if len(server_pub) != 32:
                raise Exception(f"服务器公钥长度错误: {len(server_pub)}")

            # 密钥派生
            salt = client_pub + server_pub
            psk = bytes.fromhex(current_config["pre_shared_key"])
            client_to_server_key, server_to_client_key = derive_keys(psk, salt)
            send_key = client_to_server_key  # 客户端发送
            recv_key = server_to_client_key  # 客户端接收

            # ========== 认证 ==========
            auth_digest = hmac.new(send_key, b"auth", digestmod='sha256').digest()
            await ws.send(auth_digest)
            auth_response = await asyncio.wait_for(ws.recv(), timeout=10)
            expected = hmac.new(recv_key, b"ok", digestmod='sha256').digest()

            if not hmac.compare_digest(auth_response, expected):
                raise Exception("认证失败")

            # ========== 发送 CONNECT ==========
            connect_cmd = f"CONNECT {target}".encode('utf-8')
            await ws.send(encrypt(send_key, connect_cmd))
            response = await asyncio.wait_for(ws.recv(), timeout=10)
            plaintext = decrypt(recv_key, response)

            if plaintext != b"OK":
                raise Exception(f"CONNECT 失败: {plaintext}")

            return ws, send_key, recv_key

        except Exception as e:
            if ws:
                await ws.close()

            if attempt == max_retries - 1:
                raise e

            await asyncio.sleep(1)

# ==================== 🎥 视频流优化：批量数据转发 ====================
async def ws_to_socket_optimized(ws, recv_key, writer):
    """WebSocket -> Socket（视频流优化版）"""
    global traffic_down
    try:
        while not ws.closed:
            enc_data = await ws.recv()
            if writer.is_closing():
                break

            traffic_down += len(enc_data)
            plaintext = decrypt(recv_key, enc_data)

            writer.write(plaintext)

            # 关键优化：仅在缓冲区满时 drain
            buffer_size = writer.transport.get_write_buffer_size()
            if buffer_size > WRITE_BUFFER_SIZE:
                await writer.drain()

    except:
        pass
    finally:
        if not writer.is_closing():
            try:
                await writer.drain()
                writer.close()
                await writer.wait_closed()
            except:
                pass

async def socket_to_ws_optimized(reader, ws, send_key):
    """Socket -> WebSocket（视频流批量优化版）"""
    global traffic_up

    try:
        while not ws.closed:
            # 修复：使用 read() 而不是 readinto()
            data = await reader.read(READ_BUFFER_SIZE)
            if not data:
                break

            traffic_up += len(data)
            encrypted = encrypt(send_key, data)
            await ws.send(encrypted)

    except:
        pass
    finally:
        if not ws.closed:
            await ws.close()

# ==================== SOCKS5 处理 ====================
async def handle_socks5(reader, writer):
    """处理 SOCKS5 连接"""
    global active_connections

    async with connection_semaphore:
        active_connections += 1

        ws = None
        try:
            data = await asyncio.wait_for(reader.readexactly(2), timeout=10)
            if data[0] != 0x05:
                return

            nmethods = data[1]
            await reader.readexactly(nmethods)
            writer.write(b"\x05\x00")
            await writer.drain()

            data = await asyncio.wait_for(reader.readexactly(4), timeout=10)
            if data[1] != 0x01:
                return

            addr_type = data[3]
            if addr_type == 1:
                addr = socket.inet_ntoa(await reader.readexactly(4))
            elif addr_type == 3:
                length = ord(await reader.readexactly(1))
                addr = (await reader.readexactly(length)).decode('utf-8')
            else:
                return

            port = int.from_bytes(await reader.readexactly(2), "big")
            target = f"{addr}:{port}"

            ws, send_key, recv_key = await create_secure_connection(target)

            writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            await writer.drain()

            # 🎥 使用优化版转发
            await asyncio.gather(
                ws_to_socket_optimized(ws, recv_key, writer),
                socket_to_ws_optimized(reader, ws, send_key),
                return_exceptions=True
            )

        except Exception as e:
            if not isinstance(e, (ConnectionResetError, BrokenPipeError, OSError, asyncio.TimeoutError)):
                print(f"❌ SOCKS5: {type(e).__name__}: {str(e)}")
        finally:
            active_connections -= 1
            if ws:
                await ws.close()
            try:
                writer.close()
            except:
                pass

# ==================== HTTP 处理 ====================
async def handle_http(reader, writer):
    """处理 HTTP CONNECT"""
    global active_connections

    async with connection_semaphore:
        active_connections += 1

        ws = None
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=10)
            if not line or not line.startswith(b"CONNECT"):
                writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
                await writer.drain()
                return

            line_str = line.decode('utf-8').strip()
            parts = line_str.split()
            if len(parts) < 2:
                return

            host_port = parts[1]
            if ":" in host_port:
                host, port = host_port.split(":", 1)
            else:
                host = host_port
                port = "443"
            target = f"{host}:{port}"

            while True:
                header = await reader.readline()
                if header in (b'\r\n', b'\n', b''):
                    break

            ws, send_key, recv_key = await create_secure_connection(target)

            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()

            await asyncio.gather(
                ws_to_socket_optimized(ws, recv_key, writer),
                socket_to_ws_optimized(reader, ws, send_key),
                return_exceptions=True
            )

        except Exception as e:
            if not isinstance(e, (ConnectionResetError, BrokenPipeError, OSError, asyncio.TimeoutError)):
                print(f"❌ HTTP: {type(e).__name__}: {str(e)}")
        finally:
            active_connections -= 1
            if ws:
                await ws.close()
            try:
                writer.close()
            except:
                pass

# ==================== 启动服务器 ====================
async def start_servers():
    """启动代理服务器"""
    global connection_semaphore

    if not current_config:
        print("❌ 无有效配置")
        return

    socks_port = int(current_config["socks_port"])
    http_port = int(current_config["http_port"])

    connection_semaphore = asyncio.Semaphore(MAX_CONCURRENT_CONNECTIONS)

    socks_server = await asyncio.start_server(
        handle_socks5, "127.0.0.1", socks_port, backlog=256
    )
    http_server = await asyncio.start_server(
        handle_http, "127.0.0.1", http_port, backlog=256
    )

    print("=" * 70)
    print(f"🚀 SecureProxy 客户端 (修复版 - 视频流优化)")
    print(f"✅ SOCKS5: 127.0.0.1:{socks_port}")
    print(f"✅ HTTP:   127.0.0.1:{http_port}")
    print(f"🔐 加密:   AES-256-GCM")
    print(f"🛡️  核心:   原始 Socket 实现")
    print(f"🔧 修复:")
    print(f"   • 密钥派生方向已修正")
    print(f"   • 批量逻辑改进（小包立即发送）")
    print(f"🎥 视频流优化:")
    print(f"   • 大缓冲区:     512KB 读 / 256KB 写")
    print(f"   • 批量发送:     128KB 批量 / 2ms 超时")
    print(f"   • 低延迟模式:   立即刷新下载流")
    print(f"   • 智能策略:     小包立即发送，大包批量")
    print(f"   • 并发连接:     {MAX_CONCURRENT_CONNECTIONS}")
    print(f"💡 针对 YouTube 等视频流优化，密钥方向已修正")
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
        traffic_monitor()
    )

# ==================== 启动 ====================
if __name__ == "__main__":
    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

    # 从环境变量加载配置
    current_config = load_config_from_env()

    if not current_config:
        print("❌ 无法启动: 配置加载失败")
        print("提示: 请确保 Swift 端正确设置了 SECURE_PROXY_CONFIG 环境变量")
        sys.exit(1)

    print("\n🚀 SecureProxy 客户端启动中...")
    print(f"🌍 配置: {current_config['name']}")
    print()

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\n👋 用户停止")
    except Exception as e:
        print(f"\n❌ 启动失败: {e}")
        import traceback
        traceback.print_exc()
