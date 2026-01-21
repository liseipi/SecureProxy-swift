// CryptoManager.swift
import Foundation
import CryptoKit

// 移除 @MainActor，使其可以在任何上下文中调用
final class CryptoManager {
    
    // MARK: - Key Derivation
    
    /// 使用 HKDF 派生密钥
    static func deriveKeys(sharedKey: Data, salt: Data) -> (sendKey: Data, recvKey: Data) {
        let info = "secure-proxy-v1".data(using: .utf8)!
        
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedKey),
            salt: salt,
            info: info,
            outputByteCount: 64
        )
        
        let keyData = derivedKey.withUnsafeBytes { Data($0) }
        let sendKey = keyData.prefix(32)
        let recvKey = keyData.suffix(32)
        
        return (Data(sendKey), Data(recvKey))
    }
    
    // MARK: - AES-256-GCM Encryption/Decryption
    
    /// 加密数据
    static func encrypt(key: Data, plaintext: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        
        // 组合: nonce(12) + ciphertext + tag(16)
        var result = Data()
        result.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        
        return result
    }
    
    /// 解密数据
    static func decrypt(key: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 28 else {
            throw CryptoError.invalidDataLength
        }
        
        let symmetricKey = SymmetricKey(data: key)
        
        // 分离: nonce(12) + ciphertext + tag(16)
        let nonceData = ciphertext.prefix(12)
        let tag = ciphertext.suffix(16)
        let ciphertextData = ciphertext.dropFirst(12).dropLast(16)
        
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertextData,
            tag: tag
        )
        
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
    // MARK: - HMAC
    
    /// 生成 HMAC-SHA256
    static func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
        return Data(hmac)
    }
    
    /// 安全比较两个数据
    static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        
        var result: UInt8 = 0
        for i in 0..<lhs.count {
            result |= lhs[i] ^ rhs[i]
        }
        
        return result == 0
    }
}

// MARK: - Errors

enum CryptoError: Error {
    case invalidDataLength
    case encryptionFailed
    case decryptionFailed
    case invalidNonce
    
    var localizedDescription: String {
        switch self {
        case .invalidDataLength:
            return "Invalid data length for decryption"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .invalidNonce:
            return "Invalid nonce"
        }
    }
}
