import CryptoKit
import Foundation

/// OAuth 2.0 PKCE（RFC 7636）。桌面 app 無法安全保存 client secret，所以用 PKCE 登入。
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// 產生隨機的 code_verifier（64 個字元，符合 RFC 7636 的 43–128 字元限制）。
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 48)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return PKCE(verifier: base64URL(Data(bytes)))
    }

    /// code_challenge = BASE64URL(SHA256(code_verifier))
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }
}
