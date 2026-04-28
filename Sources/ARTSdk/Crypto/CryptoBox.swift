//
//  CryptoBox.swift
//  ADK_iOS
//  Created by SSA on 02/02/26.
//

import Foundation
import TweetNacl

// MARK: -Errors
public enum CryptoBoxError: LocalizedError {
   case invalidBase64
   case invalidKeyLength
   case dataTooShort
   case utf8DecodeFailed
   
   public var errorDescription: String? {
       switch self {
       case .invalidBase64:
           return "Failed to decode base64 string."
       case .invalidKeyLength:
           return "Invalid key length for TweetNaCl."
       case .dataTooShort:
           return "Encrypted data is too short to contain a valid nonce."
       case .utf8DecodeFailed:
           return "Failed to decode decrypted data into a UTF-8 string."
       }
   }
}


// MARK: - CryptoBox Utility
public final class CryptoBox {

   // Standard TweetNaCl byte lengths
   public static let publicKeyLength = 32
   public static let secretKeyLength = 32
   public static let nonceLength = 24

   // MARK: - Generate Key Pair (Curve25519)
   public static func generateKeyPair() throws -> KeyPairType {
       let keyPair = try NaclBox.keyPair()

       let publicKeyBase64 = keyPair.publicKey.base64EncodedString()
       let privateKeyBase64 = keyPair.secretKey.base64EncodedString()

       return KeyPairType(
           publicKey: publicKeyBase64,
           privateKey: privateKeyBase64
       )
   }

   // MARK: - Encrypt
       public static func encrypt(
           message: String,
           publicKey: String,
           privateKey: String
       ) throws -> String {

           guard let pub = Data(base64Encoded: publicKey),
                 let priv = Data(base64Encoded: privateKey) else {
               throw CryptoBoxError.invalidBase64
           }

           guard pub.count == CryptoBox.publicKeyLength,
                 priv.count == CryptoBox.secretKeyLength else {
               throw CryptoBoxError.invalidKeyLength
           }

           let messageData = Data(message.utf8)
           
           // --- NEW: Generate Random Nonce using Security Framework ---
           var nonce = Data(count: CryptoBox.nonceLength)
           let result = nonce.withUnsafeMutableBytes {
               SecRandomCopyBytes(kSecRandomDefault, CryptoBox.nonceLength, $0.baseAddress!)
           }
           
           guard result == errSecSuccess else {
               throw NSError(domain: "CryptoBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Random generation failed"])
           }

           let cipher = try NaclBox.box(
               message: messageData,
               nonce: nonce,
               publicKey: pub,
               secretKey: priv
           )

           var full = Data()
           full.append(nonce)
           full.append(cipher)

           return full.base64EncodedString()
       }

   // MARK: - Decrypt
   public static func decrypt(
       encryptedData: String,
       publicKey: String,
       privateKey: String
   ) throws -> String {

       guard let full = Data(base64Encoded: encryptedData),
             let pub = Data(base64Encoded: publicKey),
             let priv = Data(base64Encoded: privateKey) else {
           throw CryptoBoxError.invalidBase64
       }

       // Use our local standard nonce length
       guard full.count >= CryptoBox.nonceLength else {
           throw CryptoBoxError.dataTooShort
       }

       let nonce = Data(full.prefix(CryptoBox.nonceLength))
       let cipher = Data(full.dropFirst(CryptoBox.nonceLength))

       let decrypted = try NaclBox.open(
        message: cipher,
           nonce: nonce,
           publicKey: pub,
           secretKey: priv
       )

       guard let message = String(data: decrypted, encoding: .utf8) else {
           throw CryptoBoxError.utf8DecodeFailed
       }

       return message
   }
}

