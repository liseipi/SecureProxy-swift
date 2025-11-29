# client.py - 修改版，支持从环境变量读取配置
import asyncio
import json
import os
import sys
import hmac
import socket
import struct
import websockets
import time
import traceback
from pathlib import Path

# 核心模块导入
from crypto import derive_keys, encrypt, decrypt
from tls_fingerprint import get_tls_session

# ==================== 资源路径 ====================
def resource_path(relative_path):
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    return os.path.join(os.path.abspath("."), relative_path)

# 从环境变量或默认路径读取配置目录
CONFIG_FILE = os.environ.get('SECURE_PROXY_CONFIG')
if CONFIG_FILE and os.path.exists(CONFIG_FILE):
    CONFIG_DIR = os.path.dirname(CONFIG_FILE)
else:
    CONFIG_DIR = resource_path("config")

# ==================== 全局状态 ====================
status = "disconnected"
current_config = None
configs = {}
active_config_name = None
traffic_up = traffic_down = 0
last_traffic_time = time.time()
tunnel = None

# ==================== 加载配置 ====================
def load_configs():
    global configs, current_config
    configs = {}
    
    # 优先从环境变量指定的配置文件加载
    if CONFIG_FILE and os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                cfg = json.load(f)
                configs[cfg["name"]] = cfg
                current_config = cfg
                print(f"✅ 加载配置: {cfg['name']}")
                return configs
        except Exception as e:
            print(f"❌ 加载配置文件失败: {e}")
    
    # 备用：从 config 目录加载
    if not os.path.exists(CONFIG_DIR):
        os.makedirs(CONFIG_DIR)
    
    for file in os.listdir(CONFIG_DIR):
        if file.endswith(".json"):
            try:
                with open(os.path.join(CONFIG_DIR, file), "r") as f:
                    cfg = json.load(f)
                    configs[cfg["name"]] = cfg
            except:
                pass
    
    if configs:
        # 使用第一个配置
        first_config = list(configs.values())[0]
        current_config = first_config
        print(f"✅ 加载配置: {first_config['name']}")
    
    return configs

def switch_config(name):
    global active_config_name, current_config
    if name in configs:
        active_config_name = name
        current_config = configs[name]

# ==================== 加密隧道 ====================
class SecureTunnel:
    def __init__(self):
        self.ws = None
        self.send_key = self.recv_key = None

    async def connect(self):
        global status
        status = "connecting"
        print("正在连接隧道...")
        try:
            host = str(current_config["sni_host"])
            path = str(current_config["path"])
            port = str(current_config.get("server_port", 443))
            
            headers, ssl_context = get_tls_session(host)
            url = f"wss://{host}:{port}{path}"
            print(f"连接 URL: {url}")

            self.ws = await asyncio.wait_for(
                websockets.connect(
                    url,
                    ssl=ssl_context,
                    server_hostname=host,
                    max_size=None,
                    ping_interval=None
                ),
                timeout=10
            )
            
            # 密钥协商
            client_pub = os.urandom(32)
            await self.ws.send(client_pub)
            server_pub = await self.ws.recv()
            
            salt = client_pub + server_pub
            psk = bytes.fromhex(current_config["pre_shared_key"])
            self.send_key, self.recv_key = derive_keys(psk, salt)
            
            auth_digest = hmac.new(self.send_key, b"auth", digestmod='sha256').digest()
            await self.ws.send(auth_digest)
            
            await self.ws.recv()  # 接收 "ok"
            status = "connected"
            print("隧道连接成功")
            return True
            
        except Exception as e:
            print(f"连接失败: {repr(e)}")
            traceback.print_exc()
            status = "disconnected"
            return False

    async def heartbeat(self):
        while status == "connected":
            try:
                await self.ws.send(encrypt(self.send_key, b"PING"))
                resp = await asyncio.wait_for(self.ws.recv(), timeout=10)
                if decrypt(self.recv_key, resp) != b"PONG":
                    raise Exception("心跳校验失败")
            except:
                status = "disconnected"
                print("心跳超时或错误，准备重连...")
                break
            await asyncio.sleep(15)

    async def ws_to_socket(self, ws, writer, key):
        global traffic_down
        try:
            async for msg in ws:
                traffic_down += len(msg)
                decrypted = decrypt(key, msg)
                writer.write(decrypted)
                await writer.drain()
        except:
            pass
        finally:
            writer.close()

    async def socket_to_ws(self, reader, ws, key):
        global traffic_up
        try:
            while True:
                data = await reader.read(32768)
                if not data: break
                traffic_up += len(data)
                encrypted = encrypt(key, data)
                await ws.send(encrypted)
        except:
            pass

    async def close(self):
        if self.ws:
            try:
                await self.ws.close()
            except:
                pass

# ==================== 代理处理 (SOCKS5 + HTTP) ====================
async def handle_socks5(reader, writer):
    tunnel = SecureTunnel()
    try:
        # 握手
        data = await reader.readexactly(2)
        if data[0] != 0x05:
            writer.close()
            return
        nmethods = data[1]
        await reader.readexactly(nmethods)
        writer.write(b"\x05\x00")
        await writer.drain()

        # 请求
        data = await reader.readexactly(4)
        if data[1] != 0x01:
            writer.close()
            return
            
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

        if not await tunnel.connect():
            writer.close()
            return

        await tunnel.ws.send(encrypt(tunnel.send_key, f"CONNECT {target}".encode('utf-8')))
        resp = await tunnel.ws.recv()
        if decrypt(tunnel.recv_key, resp) != b"OK":
            writer.close()
            return

        writer.write(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
        await writer.drain()

        await asyncio.gather(
            tunnel.ws_to_socket(tunnel.ws, writer, tunnel.recv_key),
            tunnel.socket_to_ws(reader, tunnel.ws, tunnel.send_key)
        )
    except Exception as e:
        pass
    finally:
        await tunnel.close()
        try: writer.close()
        except: pass

async def handle_http(reader, writer):
    tunnel = SecureTunnel()
    try:
        line = await reader.readline()
        if not line or not line.startswith(b"CONNECT"):
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            await writer.drain()
            writer.close()
            return

        line_str = line.decode('utf-8').strip()
        _, host_port, _ = line_str.split()
        if ":" in host_port:
            host, port = host_port.split(":", 1)
        else:
            host = host_port
            port = 443
        
        target = f"{host}:{port}"

        while True:
            header = await reader.readline()
            if header == b'\r\n' or header == b'\n' or not header:
                break

        if not await tunnel.connect():
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await writer.drain()
            writer.close()
            return

        await tunnel.ws.send(encrypt(tunnel.send_key, f"CONNECT {target}".encode('utf-8')))
        resp = await tunnel.ws.recv()
        if decrypt(tunnel.recv_key, resp) != b"OK":
            writer.close()
            return

        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()

        await asyncio.gather(
            tunnel.ws_to_socket(tunnel.ws, writer, tunnel.recv_key),
            tunnel.socket_to_ws(reader, tunnel.ws, tunnel.send_key)
        )
    except Exception as e:
        pass
    finally:
        await tunnel.close()
        try: writer.close()
        except: pass

# ==================== 主循环 ====================
async def start_servers():
    if not current_config:
        print("❌ 无有效配置，退出")
        return
    
    try:
        socks_port = int(current_config["socks_port"])
        http_port = int(current_config["http_port"])
        
        socks = await asyncio.start_server(handle_socks5, "127.0.0.1", socks_port)
        http = await asyncio.start_server(handle_http, "127.0.0.1", http_port)
        
        print(f"SOCKS5 监听: 127.0.0.1:{socks_port}")
        print(f"HTTP   监听: 127.0.0.1:{http_port}")
        print("----------------------------------------------")
        
        async with socks, http:
            await asyncio.gather(socks.serve_forever(), http.serve_forever())
    except OSError as e:
        print(f"端口被占用或权限不足: {e}")

# ==================== 启动 ====================
if __name__ == "__main__":
    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

    load_configs()
    
    if not current_config:
        print("❌ 无配置！请确保配置文件存在")
        sys.exit(1)

    print("🚀 SecureProxy 客户端启动中...")
    print(f"🌐 当前配置: {current_config['name']}")

    try:
        asyncio.run(start_servers())
    except KeyboardInterrupt:
        print("\n用户停止")
