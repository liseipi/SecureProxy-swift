# tls_fingerprint.py (修复版 - ALPN 必须是 string list)
import ssl
import random

def get_tls_session(host: str):
    # Chrome 126 手动 headers (伪装 HTTP/2)
    headers = {
        "User-Agent": random.choice([
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        ]),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Upgrade-Insecure-Requests": "1",
    }

    # 标准 SSL 上下文 (TLS 1.3 + SNI + ALPN 伪装)
    ssl_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    ssl_context.check_hostname = False  # 跳过主机验证 (生产: True)
    ssl_context.verify_mode = ssl.CERT_NONE  # 跳过证书验证 (生产: CERT_REQUIRED)
    
    # ==================== 关键修复 ====================
    # 错误: [b'h2', b'http/1.1'] -> TypeError
    # 正确: ['h2', 'http/1.1']   -> Python ssl 模块会自动编码为 ASCII
    ssl_context.set_alpn_protocols(['h2', 'http/1.1']) 
    # =================================================
    
    ssl_context.minimum_version = ssl.TLSVersion.TLSv1_3  # 强制 TLS 1.3

    return headers, ssl_context  # 返回元组 (headers dict, ssl_context)