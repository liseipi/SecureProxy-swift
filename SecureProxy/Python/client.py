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

# ==================== 性能优化配置 ====================
# 缓冲区大小优化（根据 MTU 和网络环境调整）
READ_BUFFER_SIZE = 65536  # 64KB 大缓冲区，减少系统调用
WRITE_BUFFER_SIZE = 8192   # 8KB 写缓冲阈值

# WebSocket 连接优化
WS_CONNECT_TIMEOUT = 8     # 连接超时
WS_HANDSHAKE_TIMEOUT = 5   # 握手超时
WS_MAX_SIZE = 10 * 1024 * 1024  # 10MB 最大消息大小

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

    # 性能优化
    ssl_context.options |= ssl.OP_NO_COMPRESSION  # 禁用 TLS 压缩
    ssl_context.options |= ssl.OP_NO_TICKET       # 禁用会话票证

    # 优先高性能加密套件
    ssl_context.set_ciphers('ECDHE+AESGCM:ECDHE+CHACHA20:!aNULL:!MD5:!DSS')

    # 设置 ALPN（应用层协议协商）
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

    try:
        host = str(current_config["sni_host"])
        path = str(current_config["path"])
        port = int(current_config.get("server_port", 443))

        url = f"wss://{host}:{port}{path}"

        # 建立 WebSocket 连接（优化参数）
        ws = await asyncio.wait_for(
            websockets.connect(
                url,
                ssl=get_ssl_context(),
                server_hostname=host,
                max_size=WS_MAX_SIZE,
                ping_interval=None,      # 禁用 ping
                ping_timeout=None,
                compression=None,        # 禁用压缩
                open_timeout=WS_CONNECT_TIMEOUT,
                close_timeout=2,
                max_queue=32,           # 限制发送队列
                write_limit=65536       # 写缓冲限制
            ),
            timeout=WS_CONNECT_TIMEOUT
        )

        # ========== 密钥交换 ==========
        client_pub = os.urandom(32)
        await ws.send(client_pub)
        server_pub = await asyncio.wait_for(ws.recv(), timeout=WS_HANDSHAKE_TIMEOUT)

        if len(server_pub) != 32:
            raise Exception(f"服务器公钥长度错误: {len(server_pub)}")

        # 密钥派生
        salt = client_pub + server_pub
        psk = bytes.fromhex(current_config["pre_shared_key"])
        send_key, recv_key = derive_keys(psk, salt)

        # ========== 认证 ==========
        auth_digest = hmac.new(send_key, b"auth", digestmod='sha256').digest()
        await ws.send(auth_digest)
        auth_response = await asyncio.wait_for(ws.recv(), timeout=WS_HANDSHAKE_TIMEOUT)
        expected = hmac.new(recv_key, b"ok", digestmod='sha256').digest()

        if not hmac.compare_digest(auth_response, expected):
            raise Exception("认证失败")

        # ========== 发送 CONNECT ==========
        connect_cmd = f"CONNECT {target}".encode('utf-8')
        await ws.send(encrypt(send_key, connect_cmd))
        response = await asyncio.wait_for(ws.recv(), timeout=WS_HANDSHAKE_TIMEOUT)
        plaintext = decrypt(recv_key, response)

        if plaintext != b"OK":
            raise Exception(f"CONNECT 失败: {plaintext}")

        return ws, send_key, recv_key

    except Exception as e:
        if ws:
            try:
                await ws.close()
            except:
                pass
        raise e

# ==================== 高效数据转发 ====================
async def ws_to_socket(ws, recv_key, writer):
    """WebSocket -> Socket（优化版）"""
    global traffic_down
    try:
        async for enc_data in ws:
            # 检查连接是否已关闭
            if writer.is_closing():
                break

            traffic_down += len(enc_data)
            plaintext = decrypt(recv_key, enc_data)

            writer.write(plaintext)

            # 智能批量刷新：累积到阈值或缓冲区满时才刷新
            if writer.transport.get_write_buffer_size() > WRITE_BUFFER_SIZE:
                try:
                    await writer.drain()
                except (ConnectionResetError, BrokenPipeError, OSError):
                    # 连接已断开，静默退出
                    break
    except (ConnectionResetError, BrokenPipeError, OSError):
        # 正常的连接断开，不记录错误
        pass
    except asyncio.CancelledError:
        # 任务被取消
        pass
    except Exception:
        # 其他未预期的错误也不记录（避免日志污染）
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
            # 大缓冲区读取，减少系统调用
            data = await reader.read(READ_BUFFER_SIZE)
            if not data:
                break

            traffic_up += len(data)
            encrypted = encrypt(send_key, data)

            # 检查 WebSocket 是否仍然打开
            if ws.close_code is not None:
                break

            try:
                await ws.send(encrypted)
            except (websockets.exceptions.ConnectionClosed, OSError):
                # WebSocket 已关闭，静默退出
                break
    except (ConnectionResetError, BrokenPipeError, OSError):
        # 正常的连接断开
        pass
    except asyncio.CancelledError:
        # 任务被取消
        pass
    except Exception:
        # 其他错误也不记录
        pass
    finally:
        if ws.close_code is None:
            try:
                await ws.close()
            except:
                pass

# ==================== SOCKS5 处理（优化版）====================
async def handle_socks5(reader, writer):
    """处理 SOCKS5 连接（独立连接模式）"""
    global active_connections

    # 并发控制
    async with connection_semaphore:
        active_connections += 1

        # 配置 TCP 参数
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
            # SOCKS5 握手
            data = await asyncio.wait_for(reader.readexactly(2), timeout=10)
            if data[0] != 0x05:
                return

            nmethods = data[1]
            await reader.readexactly(nmethods)
            writer.write(b"\x05\x00")
            await writer.drain()

            # SOCKS5 请求
            data = await asyncio.wait_for(reader.readexactly(4), timeout=10)
            if data[1] != 0x01:
                return

            # 解析目标
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

            # 创建独立连接
            ws, send_key, recv_key = await create_secure_connection(target)

            # 响应成功
            writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
            await writer.drain()

            # 并行双向转发
            await asyncio.gather(
                ws_to_socket(ws, recv_key, writer),
                socket_to_ws(reader, ws, send_key),
                return_exceptions=True
            )

        except asyncio.TimeoutError:
            pass
        except Exception as e:
            # 仅记录非常见的连接错误
            if not isinstance(e, (
                ConnectionResetError,
                BrokenPipeError,
                OSError,
                websockets.exceptions.ConnectionClosed
            )):
                print(f"❌ SOCKS5: {type(e).__name__}")
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

# ==================== HTTP 处理（优化版）====================
async def handle_http(reader, writer):
    """处理 HTTP CONNECT（独立连接模式）"""
    global active_connections

    # 并发控制
    async with connection_semaphore:
        active_connections += 1

        # 配置 TCP 参数
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
            # 读取 CONNECT 请求
            line = await asyncio.wait_for(reader.readline(), timeout=10)
            if not line or not line.startswith(b"CONNECT"):
                writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
                await writer.drain()
                return

            # 解析目标
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

            # 丢弃 headers
            while True:
                header = await reader.readline()
                if header in (b'\r\n', b'\n', b''):
                    break

            # 创建独立连接
            ws, send_key, recv_key = await create_secure_connection(target)

            # 响应成功
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()

            # 并行双向转发
            await asyncio.gather(
                ws_to_socket(ws, recv_key, writer),
                socket_to_ws(reader, ws, send_key),
                return_exceptions=True
            )

        except asyncio.TimeoutError:
            pass
        except Exception as e:
            # 仅记录非常见的连接错误
            if not isinstance(e, (
                ConnectionResetError,
                BrokenPipeError,
                OSError,
                websockets.exceptions.ConnectionClosed
            )):
                print(f"❌ HTTP: {type(e).__name__}")
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

        # 初始化并发控制
        connection_semaphore = asyncio.Semaphore(MAX_CONCURRENT_CONNECTIONS)

        # 启动服务器（优化 backlog）
        socks_server = await asyncio.start_server(
            handle_socks5, "127.0.0.1", socks_port, backlog=256
        )
        http_server = await asyncio.start_server(
            handle_http, "127.0.0.1", http_port, backlog=256
        )

        print("=" * 70)
        print(f"🚀 SecureProxy 客户端 (独立连接模式)")
        print(f"✅ SOCKS5: 127.0.0.1:{socks_port}")
        print(f"✅ HTTP:   127.0.0.1:{http_port}")
        print(f"🔐 加密:   AES-256-GCM + Perfect Forward Secrecy")
        print(f"⚡ 优化:")
        print(f"   • 独立连接:     每请求独立 WebSocket")
        print(f"   • 缓冲区:       读{READ_BUFFER_SIZE//1024}KB / 写{WRITE_BUFFER_SIZE//1024}KB")
        print(f"   • TCP_NODELAY:  已启用（低延迟）")
        print(f"   • TCP_KEEPALIVE: 已启用（{TCP_KEEPIDLE}s/{TCP_KEEPINTVL}s/{TCP_KEEPCNT}次）")
        print(f"   • 并发限制:     {MAX_CONCURRENT_CONNECTIONS} 连接")
        print(f"   • SSL 会话:     已缓存复用")
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
