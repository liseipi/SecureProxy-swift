# crypto.py - 统一使用 AES-256-GCM（兼容 CF Workers 和 VPS）
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import os

def derive_keys(shared_key: bytes, salt: bytes):
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=64,
        salt=salt,
        info=b'secure-proxy-v1',
    )
    key_material = hkdf.derive(shared_key)
    return key_material[:32], key_material[32:64]  # send_key, recv_key

def encrypt(key: bytes, plaintext: bytes, aad: bytes = b"") -> bytes:
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    ct = aesgcm.encrypt(nonce, plaintext, aad)
    return nonce + ct

def decrypt(key: bytes, ciphertext: bytes, aad: bytes = b"") -> bytes:
    aesgcm = AESGCM(key)
    nonce, ct = ciphertext[:12], ciphertext[12:]
    return aesgcm.decrypt(nonce, ct, aad)