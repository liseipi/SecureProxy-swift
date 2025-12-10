# client.py
import asyncio
import json
import os
import sys
import hmac
import socket
import struct
import websockets
import ssl
import time
import traceback
from pathlib import Path

# 核心模块导入
from crypto import derive_keys, encrypt, decrypt

# ==================== 性能优化配置 ====================
READ_BUFFER_SIZE = 8192 #10M
WRITE_BUFFER_SIZE = 2048 #10M
MAX_QUEUE_SIZE = 100
MAX_TUNNEL_REUSE = 10
TUNNEL_IDLE_TIMEOUT = 60
TCP_NODELAY = True
TCP_KEEPALIVE = True

# ==================== 全局状态 ====================
status = "disconnected"
current_config = None
traffic_up = traffic_down = 0
last_traffic_time = time.time()
tunnel_pool = []
tunnel_lock = asyncio.Lock()

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
    global traffic_up, traffic_down, last_traffic_time
    while True:
        await asyncio.sleep(5)
        now = time.time()
        elapsed = now - last_traffic_time
        if elapsed > 0 and (traffic_up > 0 or traffic_down > 0):
            up_speed = traffic_up / elapsed / 1024
            down_speed = traffic_down / elapsed / 1024
            print(f"📊 流量: ↑ {up_speed:.1f}KB/s ↓ {down_speed:.1f}KB/s | 池: {len(tunnel_pool)}")
            traffic_up = traffic_down = 0
            last_traffic_time = now

# ==================== 优化的加密隧道 ====================
class SecureTunnel:
    def __init__(self):
        self.ws = None
        self.send_key = self.recv_key = None
        self.connected = False
        self.use_count = 0
        self.last_used = time.time()

    async def connect(self):
        """建立 WebSocket 连接并完成密钥交换"""
        try:
            host = str(current_config["sni_host"])
            path = str(current_config["path"])
            port = int(current_config.get("server_port", 443))

            # 优化的 SSL 上下文
            ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE

            # 性能优化：启用会话复用
            ssl_context.options |= ssl.OP_NO_COMPRESSION  # 禁用 TLS 压缩
            ssl_context.set_ciphers('ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM')  # 优先高性能加密套件

            url = f"wss://{host}:{port}{path}"

            # 建立 WebSocket 连接
            self.ws = await asyncio.wait_for(
                websockets.connect(
                    url,
                    ssl=ssl_context,
                    server_hostname=host,
                    max_size=None,
                    ping_interval=None,
                    compression=None,  # 禁用 WebSocket 压缩以提升性能
                    open_timeout=8,
                    close_timeout=3,
                    max_queue=MAX_QUEUE_SIZE  # 限制发送队列
                ),
                timeout=10
            )

            # 密钥交换
            client_pub = os.urandom(32)
            await self.ws.send(client_pub)
            server_pub = await asyncio.wait_for(self.ws.recv(), timeout=3.0)

            if len(server_pub) != 32:
                raise Exception(f"服务器公钥长度错误: {len(server_pub)}")

            # 密钥派生
            salt = client_pub + server_pub
            psk = bytes.fromhex(current_config["pre_shared_key"])
            temp_k1, temp_k2 = derive_keys(psk, salt)
            self.send_key = temp_k1
            self.recv_key = temp_k2

            # 认证
            auth_digest = hmac.new(self.send_key, b"auth", digestmod='sha256').digest()
            await self.ws.send(auth_digest)
            auth_response = await asyncio.wait_for(self.ws.recv(), timeout=3.0)
            expected = hmac.new(self.recv_key, b"ok", digestmod='sha256').digest()

            if not hmac.compare_digest(auth_response, expected):
                raise Exception("认证失败")

            self.connected = True
            self.last_used = time.time()
            return True

        except Exception as e:
            print(f"❌ 连接失败: {repr(e)}")
            return False

    async def send_connect(self, target):
        """发送 CONNECT 命令"""
        try:
            connect_cmd = f"CONNECT {target}".encode('utf-8')
            await self.ws.send(encrypt(self.send_key, connect_cmd))
            response = await asyncio.wait_for(self.ws.recv(), timeout=3.0)
            plaintext = decrypt(self.recv_key, response)

            if plaintext == b"OK":
                self.use_count += 1
                self.last_used = time.time()
                return True
            return False
        except Exception:
            return False

    async def ws_to_socket(self, writer):
        """WebSocket -> Socket"""
        global traffic_down
        try:
            # 批量处理以减少系统调用
            async for enc_data in self.ws:
                traffic_down += len(enc_data)
                plaintext = decrypt(self.recv_key, enc_data)
                writer.write(plaintext)
                # 使用更大的缓冲，减少 drain 调用
                if writer.transport.get_write_buffer_size() > WRITE_BUFFER_SIZE:
                    await writer.drain()
            # 最后一次 drain
            await writer.drain()
        except:
            pass
        finally:
            writer.close()

    async def socket_to_ws(self, reader):
        """Socket -> WebSocket"""
        global traffic_up
        try:
            while True:
                # 使用更大的读取缓冲
                data = await reader.read(READ_BUFFER_SIZE)
                if not data:
                    break
                traffic_up += len(data)
                encrypted = encrypt(self.send_key, data)
                await self.ws.send(encrypted)
        except:
            pass

    def is_reusable(self):
        """检查隧道是否可复用"""
        if not self.connected:
            return False
        if self.use_count >= MAX_TUNNEL_REUSE:
            return False
        if time.time() - self.last_used > TUNNEL_IDLE_TIMEOUT:
            return False
        return True

    async def close(self):
        """关闭隧道"""
        self.connected = False
        if self.ws:
            try:
                await self.ws.close()
            except:
                pass

# ==================== 隧道池管理 ====================
async def get_tunnel_from_pool():
    """从池中获取可用隧道"""
    async with tunnel_lock:
        # 清理过期隧道
        global tunnel_pool
        tunnel_pool = [t for t in tunnel_pool if t.is_reusable()]

        # 如果池中有可用隧道
        if tunnel_pool:
            tunnel = tunnel_pool.pop(0)
            return tunnel

    # 创建新隧道
    tunnel = SecureTunnel()
    if await tunnel.connect():
        return tunnel
    return None

async def return_tunnel_to_pool(tunnel):
    """归还隧道到池"""
    if tunnel and tunnel.is_reusable():
        async with tunnel_lock:
            if len(tunnel_pool) < 5:  # 池最大容量
                tunnel_pool.append(tunnel)
                return
    if tunnel:
        await tunnel.close()

# ==================== SOCKS5 处理 ====================
async def handle_socks5(reader, writer):
    """处理 SOCKS5 连接"""
    sock = writer.get_extra_info('socket')
    if sock and TCP_NODELAY:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if sock and TCP_KEEPALIVE:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

    tunnel = None
    try:
        # SOCKS5 握手
        data = await asyncio.wait_for(reader.readexactly(2), timeout=5)
        if data[0] != 0x05:
            writer.close()
            return

        nmethods = data[1]
        await reader.readexactly(nmethods)
        writer.write(b"\x05\x00")
        await writer.drain()

        # SOCKS5 请求
        data = await asyncio.wait_for(reader.readexactly(4), timeout=5)
        if data[1] != 0x01:
            writer.close()
            return

        # 解析目标
        addr_type = data[3]
        if addr_type == 1:
            addr = socket.inet_ntoa(await reader.readexactly(4))
        elif addr_type == 3:
            length = ord(await reader.readexactly(1))
            addr = (await reader.readexactly(length)).decode('utf-8')
        else:
            writer.close()
            return

        port = int.from_bytes(await reader.readexactly(2), "big")
        target = f"{addr}:{port}"

        # 从池中获取隧道
        tunnel = await get_tunnel_from_pool()
        if not tunnel:
            writer.write(b"\x05\x05\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            await writer.drain()
            writer.close()
            return

        # 发送 CONNECT
        if not await tunnel.send_connect(target):
            writer.write(b"\x05\x05\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            await writer.drain()
            writer.close()
            await tunnel.close()
            return

        # 响应成功
        writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
        await writer.drain()

        # 双向转发
        await asyncio.gather(
            tunnel.ws_to_socket(writer),
            tunnel.socket_to_ws(reader),
            return_exceptions=True
        )

    except asyncio.TimeoutError:
        pass
    except Exception as e:
        print(f"❌ SOCKS5 错误: {repr(e)}")
    finally:
        # 归还隧道到池
        if tunnel:
            await return_tunnel_to_pool(tunnel)
        try:
            writer.close()
        except:
            pass

# ==================== HTTP 处理 ====================
async def handle_http(reader, writer):
    """处理 HTTP CONNECT"""
    sock = writer.get_extra_info('socket')
    if sock and TCP_NODELAY:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if sock and TCP_KEEPALIVE:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

    tunnel = None
    try:
        # 读取 CONNECT 请求
        line = await asyncio.wait_for(reader.readline(), timeout=5)
        if not line or not line.startswith(b"CONNECT"):
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            await writer.drain()
            writer.close()
            return

        # 解析目标
        line_str = line.decode('utf-8').strip()
        parts = line_str.split()
        if len(parts) < 2:
            writer.close()
            return

        host_port = parts[1]
        if ":" in host_port:
            host, port = host_port.split(":", 1)
        else:
            host = host_port
            port = "443"
        target = f"{host}:{port}"

        # 丢弃 headers
        while True:
            header = await reader.readline()
            if header in (b'\r\n', b'\n', b''):
                break

        # 从池中获取隧道
        tunnel = await get_tunnel_from_pool()
        if not tunnel:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await writer.drain()
            writer.close()
            return

        # 发送 CONNECT
        if not await tunnel.send_connect(target):
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await writer.drain()
            writer.close()
            await tunnel.close()
            return

        # 响应成功
        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()

        # 双向转发
        await asyncio.gather(
            tunnel.ws_to_socket(writer),
            tunnel.socket_to_ws(reader),
            return_exceptions=True
        )

    except asyncio.TimeoutError:
        pass
    except Exception as e:
        print(f"❌ HTTP 错误: {repr(e)}")
    finally:
        # 归还隧道到池
        if tunnel:
            await return_tunnel_to_pool(tunnel)
        try:
            writer.close()
        except:
            pass

# ==================== 启动服务器 ====================
async def start_servers():
    """启动代理服务器"""
    if not current_config:
        print("❌ 无有效配置")
        return

    try:
        socks_port = int(current_config["socks_port"])
        http_port = int(current_config["http_port"])

        # 设置 backlog
        socks_server = await asyncio.start_server(
            handle_socks5, "127.0.0.1", socks_port, backlog=128
        )
        http_server = await asyncio.start_server(
            handle_http, "127.0.0.1", http_port, backlog=128
        )

        print("=" * 60)
        print(f"✅ SOCKS5: 127.0.0.1:{socks_port}")
        print(f"✅ HTTP:   127.0.0.1:{http_port}")
        print(f"🔐 加密: AES-256-GCM")
        print(f"⚡ 性能优化: 已启用")
        print(f"   - 缓冲区: {READ_BUFFER_SIZE//1024}KB")
        print(f"   - TCP_NODELAY: {TCP_NODELAY}")
        print(f"   - 连接池: 启用")
        print(f"💡 兼容: CF Workers & VPS Server")
        print("=" * 60)

        async with socks_server, http_server:
            await asyncio.gather(
                socks_server.serve_forever(),
                http_server.serve_forever()
            )

    except OSError as e:
        print(f"❌ 端口占用: {e}")
        sys.exit(1)

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
        traceback.print_exc()
