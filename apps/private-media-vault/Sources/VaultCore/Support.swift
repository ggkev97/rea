import Crypto
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum VaultError: Error, Equatable, CustomStringConvertible {
    case locked
    case authenticationFailed
    case truncated
    case malformed
    case unsupportedVersion(Int)
    case integrityFailed
    case diskFull
    case interrupted
    case notFound
    case alreadyExists
    case invalidName
    case limitExceeded
    case journalCorrupt
    case catalogCorrupt
    case pathRejected
    case emptyImport
    case simulatedCrash
    case storageFailed
    case previousVaultExists

    public var description: String {
        switch self {
        case .locked:
            return "The vault is locked."
        case .authenticationFailed:
            return "Authentication failed."
        case .truncated:
            return "The encrypted container is truncated."
        case .malformed:
            return "The encrypted container is malformed."
        case .unsupportedVersion(let version):
            return "Unsupported data version \(version)."
        case .integrityFailed:
            return "Integrity verification failed."
        case .diskFull:
            return "There is not enough space to finish this operation."
        case .interrupted:
            return "The operation was interrupted."
        case .notFound:
            return "The item was not found."
        case .alreadyExists:
            return "The destination already exists."
        case .invalidName:
            return "The name is not valid."
        case .limitExceeded:
            return "The size limit was exceeded."
        case .journalCorrupt:
            return "The import journal could not be authenticated. Vault files were left in place."
        case .catalogCorrupt:
            return "The catalog could not be authenticated. Vault files were left in place."
        case .pathRejected:
            return "A path in the archive was rejected."
        case .emptyImport:
            return "The import was empty."
        case .simulatedCrash:
            return "The operation stopped at a crash checkpoint."
        case .storageFailed:
            return "The file could not be stored."
        case .previousVaultExists:
            return "A previous vault copy is already present. Move it away before replacing the vault again."
        }
    }
}

public protocol VaultLog: AnyObject {
    func log(_ message: String)
}

public final class SilentLog: VaultLog {
    public init() {}
    public func log(_ message: String) {}
}

public final class MemoryLog: VaultLog {
    public private(set) var lines: [String] = []
    public init() {}
    public func log(_ message: String) {
        lines.append(message)
    }
}

public protocol VaultClock {
    func now() -> Date
}

public struct SystemClock: VaultClock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class ManualClock: VaultClock {
    public var date: Date
    public init(_ date: Date) { self.date = date }
    public func now() -> Date { date }
}

public final class ByteQuota {
    public private(set) var remaining: Int
    public init(bytes: Int) { remaining = bytes }
    public func reserve(_ bytes: Int) throws {
        guard bytes >= 0 else { throw VaultError.malformed }
        guard bytes <= remaining else { throw VaultError.diskFull }
        remaining -= bytes
    }
}

public protocol VaultFileHooks {
    func didCreate(_ url: URL) throws
}

public struct NoVaultFileHooks: VaultFileHooks {
    public init() {}
    public func didCreate(_ url: URL) throws {}
}

public final class RecordingFileHooks: VaultFileHooks {
    public private(set) var urls: [URL] = []
    public init() {}
    public func didCreate(_ url: URL) throws { urls.append(url) }
}

public enum ImportPoint: String, Equatable {
    case beforeJournal
    case journalReady
    case catalogCommitted
}

public protocol ImportInterruption {
    func after(_ point: ImportPoint) throws
}

public struct NoImportInterruption: ImportInterruption {
    public init() {}
    public func after(_ point: ImportPoint) throws {}
}

public final class CrashAt: ImportInterruption {
    public let point: ImportPoint
    public init(_ point: ImportPoint) { self.point = point }
    public func after(_ point: ImportPoint) throws {
        if point == self.point { throw VaultError.simulatedCrash }
    }
}

public protocol ByteSource: AnyObject {
    func read(maxLength: Int) throws -> Data
}

public final class DataByteSource: ByteSource {
    private let data: Data
    private var offset = 0
    public init(_ data: Data) { self.data = data }
    public func read(maxLength: Int) throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(data.count, offset + maxLength)
        let slice = data.subdata(in: offset ..< end)
        offset = end
        return slice
    }
}

public final class FileByteSource: ByteSource {
    private let handle: FileHandle
    public init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }
    public func read(maxLength: Int) throws -> Data {
        try handle.read(upToCount: maxLength) ?? Data()
    }
    public func close() {
        try? handle.close()
    }
    deinit { close() }
}

public struct MasterKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var bytes: [UInt8]

    public var description: String { "MasterKey(redacted)" }
    public var debugDescription: String { "MasterKey(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public static func generate() -> MasterKey {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Array($0) }
        return MasterKey(bytes)
    }

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == 32, "Master key must be 32 bytes")
        self.bytes = bytes
    }

    public init(data: Data) {
        self.init([UInt8](data))
    }

    public var isWiped: Bool { bytes.isEmpty }

    public func copyBytes() -> [UInt8] { bytes }

    func withSymmetricKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        guard bytes.count == 32 else { throw VaultError.locked }
        return try bytes.withUnsafeBytes { raw in
            try body(SymmetricKey(data: Data(raw)))
        }
    }

    public mutating func wipe() {
        insecureWipe(&bytes)
    }
}

public struct RecoveryKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var bytes: [UInt8]

    public var description: String { "RecoveryKey(redacted)" }
    public var debugDescription: String { "RecoveryKey(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public static func generate() -> RecoveryKey {
        let key = SymmetricKey(size: .bits256)
        return RecoveryKey(key.withUnsafeBytes { Array($0) })
    }

    init(_ bytes: [UInt8]) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    public var display: String {
        RecoveryKeyCodec.grouped(RecoveryKeyCodec.encode(bytes))
    }

    public static func parse(_ text: String) throws -> RecoveryKey {
        let decoded = try RecoveryKeyCodec.decode(text)
        guard decoded.count == 32 else { throw VaultError.authenticationFailed }
        return RecoveryKey(decoded)
    }

    func withSymmetricKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        guard bytes.count == 32 else { throw VaultError.authenticationFailed }
        return try bytes.withUnsafeBytes { raw in
            try body(SymmetricKey(data: Data(raw)))
        }
    }

    public func rawBytesForBackupWrap() -> [UInt8] { bytes }

    public mutating func wipe() {
        insecureWipe(&bytes)
    }
}

enum RecoveryKeyCodec {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ bytes: [UInt8]) -> String {
        var buffer = 0
        var bits = 0
        var output = ""
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 {
            output.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return output
    }

    static func grouped(_ encoded: String) -> String {
        stride(from: 0, to: encoded.count, by: 4).map { index in
            let start = encoded.index(encoded.startIndex, offsetBy: index)
            let end = encoded.index(start, offsetBy: min(4, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start ..< end])
        }.joined(separator: "-")
    }

    static func decode(_ text: String) throws -> [UInt8] {
        var values: [Int] = []
        for scalar in text.uppercased().unicodeScalars {
            if scalar == "-" || scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                continue
            }
            let mapped: UnicodeScalar
            switch scalar {
            case "I", "L": mapped = "1"
            case "O": mapped = "0"
            default: mapped = scalar
            }
            guard let index = alphabet.firstIndex(of: Character(mapped)) else {
                throw VaultError.authenticationFailed
            }
            values.append(index)
        }
        var buffer = 0
        var bits = 0
        var output: [UInt8] = []
        for value in values {
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        if bits > 0 && ((buffer << (8 - bits)) & 0xff) != 0 && output.count != 32 {
            throw VaultError.authenticationFailed
        }
        guard output.count >= 32 else { throw VaultError.authenticationFailed }
        return Array(output.prefix(32))
    }
}

enum SecretCompare {
    static func equal(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }

    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        equal([UInt8](lhs), [UInt8](rhs))
    }
}

func insecureWipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        #if canImport(Darwin)
        _ = memset_s(base, buffer.count, 0, buffer.count)
        #elseif canImport(Glibc)
        explicit_bzero(base, buffer.count)
        #else
        memset(base, 0, buffer.count)
        #endif
    }
    bytes.removeAll(keepingCapacity: false)
}

enum Binary {
    static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    static func append(_ value: UInt32, to data: inout Data) {
        var copy = value.littleEndian
        withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
    }

    static func append(_ value: UInt64, to data: inout Data) {
        var copy = value.littleEndian
        withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
    }

    static func readUInt16(_ data: Data, _ offset: inout Int) throws -> UInt16 {
        guard offset >= 0, data.count >= offset + 2 else { throw VaultError.truncated }
        let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        return value
    }

    static func readUInt32(_ data: Data, _ offset: inout Int) throws -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else { throw VaultError.truncated }
        let bytes = [UInt8](data[offset ..< offset + 4])
        offset += 4
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    static func readUInt64(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        guard offset >= 0, data.count >= offset + 8 else { throw VaultError.truncated }
        let bytes = [UInt8](data[offset ..< offset + 8])
        offset += 8
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (UInt64(index) * 8)
        }
        return value
    }
}

func syncFile(_ handle: FileHandle) throws {
    #if canImport(Darwin)
    try handle.synchronize()
    #else
    if fsync(handle.fileDescriptor) != 0 {
        throw VaultError.storageFailed
    }
    #endif
}

public func shredFile(_ url: URL) {
    guard let handle = try? FileHandle(forWritingTo: url) else {
        try? FileManager.default.removeItem(at: url)
        return
    }
    let length = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: 0)
    var left = Int(length)
    let block = Data(repeating: 0, count: 1024 * 1024)
    while left > 0 {
        let count = min(left, block.count)
        try? handle.write(contentsOf: block.prefix(count))
        left -= count
    }
    try? syncFile(handle)
    try? handle.close()
    try? FileManager.default.removeItem(at: url)
}

enum CryptoBox {
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> (nonce: Data, ciphertext: Data, tag: Data) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return (Data(nonce), Data(sealed.ciphertext), Data(sealed.tag))
    }

    static func open(ciphertext: Data, tag: Data, nonce: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            let nonceValue = try AES.GCM.Nonce(data: nonce)
            let box = try AES.GCM.SealedBox(nonce: nonceValue, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.authenticationFailed
        }
    }

    static func derive(ikm: SymmetricKey, salt: Data, info: String) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

func randomBytes(count: Int) -> Data {
    precondition(count > 0)
    let key = SymmetricKey(size: SymmetricKeySize(bitCount: count * 8))
    return key.withUnsafeBytes { Data($0) }
}
