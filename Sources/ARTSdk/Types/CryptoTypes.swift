// Sources/ARTSdk/Types/CryptoTypes.swift

import Foundation

public struct KeyPairType {
    public var publicKey: String
    public var privateKey: String

    public init(publicKey: String, privateKey: String) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}
