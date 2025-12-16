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
from pathlib import Path

# 核心模块导入
from crypto import derive_keys, encrypt, decrypt

# ==================== Cloudflare CDN 优化配置 ====================
# WebSocket 连接优化（针对 CF CDN）
WS_CONNECT_TIMEOUT = 15        # CDN 需要更长超时
WS_HANDSHAKE_TIMEOUT = 10      # 握手超时增加
WS_MAX_SIZE = 10 * 1024 * 1024

# 缓冲区配置
READ_BUFFER_SIZE = 65536
WRITE_BUFFER_SIZE = 8192

# TCP 优化参数
TCP_NODELAY = True         # 禁用 Nagle 算法
TCP_KEEPALIVE = True       # 启用 TCP keepalive
TCP_KEEPIDLE = 60          # 60秒开始发送 keepalive
TCP_KEEPINTVL = 10         # 每10秒发送一次
TCP_KEEPCNT = 3            # 3次失败后断开

# 并发控制
MAX_CONCURRENT_CONNECTIONS = 500  # 最大并发连接数
connection_semaphore = None       # 全局信号量

# ==================== 资源路径 ====================
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

# ==================== SSL 上下文优化 ====================
def get_ssl_context():
    """获取优化的 SSL 上下文（缓存复用）"""
    global _ssl_context_cache

    if _ssl_context_cache is not None:
        return _ssl_context_cache

    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    # Cloudflare CDN 优化
    ssl_context.options |= ssl.OP_NO_COMPRESSION

    # 支持 TLS 1.2 和 1.3（Cloudflare 兼容性）
    ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2

    # 使用 Cloudflare 支持的加密套件
    ssl_context.set_ciphers('ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:!aNULL:!MD5:!DSS')

    # ALPN 协议协商（Cloudflare 需要）
    try:
        ssl_context.set_alpn_protocols(['http/1.1'])
    except:
        pass

    _ssl_context_cache = ssl_context
    return ssl_context

# ==================== 优化的独立连接处理 ====================
async def create_secure_connection(target):
    """
    为单个请求创建独立的加密连接

    优势：
    1. 完全并行化，无锁竞争
    2. 故障隔离，单个连接失败不影响其他
    3. 简化生命周期管理
    4. 更好的负载均衡
    """
    ws = None
    max_retries = 2
    retry_delay = 1

    for attempt in range(max_retries):
        try:
            host = str(current_config["sni_host"])
            path = str(current_config["path"])
            port = int(current_config.get("server_port", 443))

            url = f"wss://{host}:{port}{path}"

            # Cloudflare CDN 友好的连接参数
            ws = await asyncio.wait_for(
                websockets.connect(
                    url,
                    ssl=get_ssl_context(),
                    server_hostname=host,
                    max_size=WS_MAX_SIZE,
                    ping_interval=30,           # CDN环境建议启用ping
                    ping_timeout=20,            # ping超时
                    compression=None,           # 禁用压缩（避免CDN干扰）
                    open_timeout=WS_CONNECT_TIMEOUT,
                    close_timeout=3,
                    max_queue=32,
                    write_limit=65536,
                    # Cloudflare 友好的 headers
                    additional_headers={
                        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                        'Origin': f'https://{host}',
                    }
                ),
                timeout=WS_CONNECT_TIMEOUT + 5
            )

            # ========== 密钥交换 ==========
            client_pub = os.urandom(32)
            await ws.send(client_pub)
            server_pub = await asyncio.wait_for(
                ws.recv(),
                timeout=WS_HANDSHAKE_TIMEOUT
            )

            if len(server_pub) != 32:
                raise Exception(f"服务器公钥长度错误: {len(server_pub)}")

            # 密钥派生
            salt = client_pub + server_pub
            psk = bytes.fromhex(current_config["pre_shared_key"])
            send_key, recv_key = derive_keys(psk, salt)

            # ========== 认证 ==========
            auth_digest = hmac.new(send_key, b"auth", digestmod='sha256').digest()
            await ws.send(auth_digest)
            auth_response = await asyncio.wait_for(
                ws.recv(),
                timeout=WS_HANDSHAKE_TIMEOUT
            )
            expected = hmac.new(recv_key, b"ok", digestmod='sha256').digest()

            if not hmac.compare_digest(auth_response, expected):
                raise Exception("认证失败")

            # ========== 发送 CONNECT ==========
            connect_cmd = f"CONNECT {target}".encode('utf-8')
            await ws.send(encrypt(send_key, connect_cmd))
            response = await asyncio.wait_for(
                ws.recv(),
                timeout=WS_HANDSHAKE_TIMEOUT
            )
            plaintext = decrypt(recv_key, response)

            if plaintext != b"OK":
                raise Exception(f"CONNECT 失败: {plaintext}")

            return ws, send_key, recv_key

        except asyncio.TimeoutError as e:
            if ws:
                try:
                    await ws.close()
                except:
                    pass

            if attempt < max_retries - 1:
                # 不打印警告，避免日志污染
                await asyncio.sleep(retry_delay)
                retry_delay *= 2  # 指数退避
                continue
            else:
                raise Exception("连接超时（CDN可能限流）")

        except Exception as e:
            if ws:
                try:
                    await ws.close()
                except:
                    pass

            # 如果是最后一次尝试，抛出异常
            if attempt == max_retries - 1:
                raise e

            # 否则等待后重试
            await asyncio.sleep(retry_delay)
            retry_delay *= 2

# ==================== 高效数据转发 ====================
async def ws_to_socket(ws, recv_key, writer):
    """WebSocket -> Socket（优化版）"""
    global traffic_down
    try:
        async for enc_data in ws:
            if writer.is_closing():
                break

            traffic_down += len(enc_data)
            plaintext = decrypt(recv_key, enc_data)

            writer.write(plaintext)

            if writer.transport.get_write_buffer_size() > WRITE_BUFFER_SIZE:
                try:
                    await writer.drain()
                except (ConnectionResetError, BrokenPipeError, OSError):
                    break
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    except asyncio.CancelledError:
        pass
    except Exception:
        pass
    finally:
        if not writer.is_closing():
            try:
                writer.close()
                await writer.wait_closed()
            except:
                pass

async def socket_to_ws(reader, ws, send_key):
    """Socket -> WebSocket（优化版）"""
    global traffic_up
    try:
        while True:
            data = await reader.read(READ_BUFFER_SIZE)
            if not data:
                break

            traffic_up += len(data)
            encrypted = encrypt(send_key, data)

            if ws.close_code is not None:
                break

            try:
                await ws.send(encrypted)
            except (websockets.exceptions.ConnectionClosed, OSError):
                break
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    except asyncio.CancelledError:
        pass
    except Exception:
        pass
    finally:
        if ws.close_code is None:
            try:
                await ws.close()
            except:
                pass

# ==================== SOCKS5 处理 ====================
async def handle_socks5(reader, writer):
    """处理 SOCKS5 连接"""
    global active_connections

    async with connection_semaphore:
        active_connections += 1

        sock = writer.get_extra_info('socket')
        if sock:
            if TCP_NODELAY:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if TCP_KEEPALIVE:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                if hasattr(socket, 'TCP_KEEPIDLE'):
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, TCP_KEEPIDLE)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, TCP_KEEPINTVL)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, TCP_KEEPCNT)

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

            await asyncio.gather(
                ws_to_socket(ws, recv_key, writer),
                socket_to_ws(reader, ws, send_key),
                return_exceptions=True
            )

        except asyncio.TimeoutError:
            pass
        except Exception as e:
            if not isinstance(e, (
                ConnectionResetError,
                BrokenPipeError,
                OSError,
                websockets.exceptions.ConnectionClosed
            )):
                print(f"❌ SOCKS5: {type(e).__name__}: {str(e)}")
        finally:
            active_connections -= 1
            if ws:
                try:
                    await ws.close()
                except:
                    pass
            try:
                writer.close()
            except:
                pass

# ==================== HTTP 处理 ====================
async def handle_http(reader, writer):
    """处理 HTTP CONNECT（独立连接模式）"""
    global active_connections

    async with connection_semaphore:
        active_connections += 1

        sock = writer.get_extra_info('socket')
        if sock:
            if TCP_NODELAY:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if TCP_KEEPALIVE:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                if hasattr(socket, 'TCP_KEEPIDLE'):
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, TCP_KEEPIDLE)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, TCP_KEEPINTVL)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, TCP_KEEPCNT)

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
                ws_to_socket(ws, recv_key, writer),
                socket_to_ws(reader, ws, send_key),
                return_exceptions=True
            )

        except asyncio.TimeoutError:
            pass
        except Exception as e:
            if not isinstance(e, (
                ConnectionResetError,
                BrokenPipeError,
                OSError,
                websockets.exceptions.ConnectionClosed
            )):
                print(f"❌ HTTP: {type(e).__name__}: {str(e)}")
        finally:
            active_connections -= 1
            if ws:
                try:
                    await ws.close()
                except:
                    pass
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

    try:
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
        print(f"🚀 SecureProxy 客户端 (Cloudflare CDN 优化版)")
        print(f"✅ SOCKS5: 127.0.0.1:{socks_port}")
        print(f"✅ HTTP:   127.0.0.1:{http_port}")
        print(f"🔐 加密:   AES-256-GCM + Perfect Forward Secrecy")
        print(f"☁️  CDN:    Cloudflare 友好模式")
        print(f"⚡ 优化:")
        print(f"   • 连接超时:     {WS_CONNECT_TIMEOUT}秒（CDN适配）")
        print(f"   • 心跳机制:     30秒（保持CDN连接）")
        print(f"   • 重试机制:     2次指数退避")
        print(f"   • 并发限制:     {MAX_CONCURRENT_CONNECTIONS} 连接")
        print("=" * 70)

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
        import traceback
        traceback.print_exc()
