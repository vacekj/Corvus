import CommonCrypto
import Foundation
@_exported import CryptoKit

func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let outCount = out.count
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { i in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, i.baseAddress, d.baseAddress, data.count,
                            o.baseAddress, outCount, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { throw ImportError("The attachment could not be decrypted.") }
    out.count = moved
    return out
}
