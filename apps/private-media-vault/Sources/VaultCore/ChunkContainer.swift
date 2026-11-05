import Crypto
import Foundation

public struct ChunkPlainRange: Equatable {
    public var chunkIndex: Int
    public var plaintextStart: Int
    public var plaintextEnd: Int

    public var byteRange: Range<Int> { plaintextStart ..< plaintextEnd }
}

public enum ChunkRangePlanner {
    public static func chunks(
        covering range: Range<Int>,
        chunkSize: Int,
        plaintextLength: Int
    ) throws -> [ChunkPlainRange] {
        guard chunkSize > 0, plaintextLength >= 0 else { throw VaultError.malformed }
        guard range.lowerBound >= 0, range.upperBound <= plaintextLength, range.lowerBound <= range.upperBound else {
            throw VaultError.malformed
        }
        if range.isEmpty || plaintextLength == 0 { return [] }
        let first = range.lowerBound / chunkSize
        let last = (range.upperBound - 1) / chunkSize
        var output: [ChunkPlainRange] = []
        for index in first ... last {
            let start = index * chunkSize
            let end = min(plaintextLength, start + chunkSize)
            let sliceStart = max(range.lowerBound, start)
            let sliceEnd = min(range.upperBound, end)
            output.append(ChunkPlainRange(chunkIndex: index, plaintextStart: sliceStart, plaintextEnd: sliceEnd))
        }
        return output
    }
}

struct ChunkRecord {
    var cipherLength: Int
    var plainLength: Int
    var tag: Data
    var cipherOffset: Int
}

public final class ChunkedReader {
    public let plaintextLength: Int
    public let fileID: UUID
    let chunkSize: Int
    private let handle: FileHandle
    private var dekBytes: [UInt8]
    private let records: [ChunkRecord]
    public private(set) var isClosed = false
    private var closed: Bool {
        get { isClosed }
        set { isClosed = newValue }
    }

    public init(url: URL, masterKey: MasterKey) throws {
        handle = try FileHandle(forReadingFrom: url)
        let parsed = try ChunkContainer.parse(handle: handle, masterKey: masterKey)
        plaintextLength = parsed.plaintextLength
        fileID = parsed.fileID
        chunkSize = parsed.chunkSize
        dekBytes = parsed.dek
        records = parsed.records
    }

    public func plaintext(byteRange: Range<Int>) throws -> Data {
        guard !closed else { throw VaultError.locked }
        guard byteRange.count <= VaultFormats.maximumPlaintextRangeBytes else { throw VaultError.limitExceeded }
        let plan = try ChunkRangePlanner.chunks(
            covering: byteRange,
            chunkSize: chunkSize,
            plaintextLength: plaintextLength
        )
        var output = Data()
        output.reserveCapacity(byteRange.count)
        for slice in plan {
            let record = records[slice.chunkIndex]
            try handle.seek(toOffset: UInt64(record.cipherOffset))
            guard let cipher = try handle.read(upToCount: record.cipherLength), cipher.count == record.cipherLength else {
                throw VaultError.truncated
            }
            let plain = try openChunk(record: record, index: slice.chunkIndex, ciphertext: cipher)
            let localStart = slice.plaintextStart - (slice.chunkIndex * chunkSize)
            let localEnd = slice.plaintextEnd - (slice.chunkIndex * chunkSize)
            guard localStart >= 0, localEnd <= plain.count, localStart <= localEnd else {
                throw VaultError.integrityFailed
            }
            output.append(plain.subdata(in: localStart ..< localEnd))
        }
        return output
    }

    public func sha256() throws -> Data {
        var hasher = SHA256()
        var offset = 0
        while offset < plaintextLength {
            let end = min(plaintextLength, offset + chunkSize)
            let piece = try plaintext(byteRange: offset ..< end)
            hasher.update(data: piece)
            offset = end
        }
        return Data(hasher.finalize())
    }

    public func close() {
        guard !closed else { return }
        closed = true
        insecureWipe(&dekBytes)
        try? handle.close()
    }

    deinit { close() }

    private func openChunk(record: ChunkRecord, index: Int, ciphertext: Data) throws -> Data {
        let nonce = ChunkContainer.nonce(for: index)
        let aad = ChunkContainer.chunkAAD(
            fileID: fileID,
            index: UInt64(index),
            plainLength: UInt32(record.plainLength)
        )
        return try dekBytes.withUnsafeBytes { raw in
            let key = SymmetricKey(data: Data(raw))
            return try CryptoBox.open(ciphertext: ciphertext, tag: record.tag, nonce: nonce, key: key, aad: aad)
        }
    }
}

enum ChunkContainer {
    static let defaultChunkSize = 1 << 20
    static let minimumChunkSize = 16
    static let maximumChunkSize = 8 << 20
    static let prefixLength = 174
    static let headerPlainLength = 64
    static let trailer = Data("PMV1END!".utf8)

    struct Parsed {
        var plaintextLength: Int
        var fileID: UUID
        var chunkSize: Int
        var dek: [UInt8]
        var records: [ChunkRecord]
    }

    struct Written {
        var plaintextLength: Int
        var sha256: Data
        var fileID: UUID
    }

    static func encrypt(
        source: any ByteSource,
        to destination: URL,
        masterKey: MasterKey,
        chunkSize: Int,
        quota: ByteQuota?
    ) throws -> Written {
        guard chunkSize >= minimumChunkSize, chunkSize <= maximumChunkSize else {
            throw VaultError.malformed
        }
        let fileID = UUID()
        var dek = [UInt8](repeating: 0, count: 32)
        SymmetricKey(size: .bits256).withUnsafeBytes { raw in
            dek = Array(raw)
        }
        defer { insecureWipe(&dek) }

        let bodyURL = destination.appendingPathExtension("bodytmp")
        if FileManager.default.fileExists(atPath: bodyURL.path) {
            try FileManager.default.removeItem(at: bodyURL)
        }
        _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let body = try FileHandle(forWritingTo: bodyURL)
        defer {
            try? body.close()
            shredFile(bodyURL)
        }

        var hasher = SHA256()
        var records: [(plainLength: Int, tag: Data)] = []
        var plaintextLength = 0
        while true {
            let piece = try source.read(maxLength: chunkSize)
            if piece.isEmpty { break }
            if piece.count > chunkSize { throw VaultError.malformed }
            hasher.update(data: piece)
            let index = records.count
            let sealed = try dek.withUnsafeBytes { raw -> (Data, Data) in
                let key = SymmetricKey(data: Data(raw))
                let aad = chunkAAD(
                    fileID: fileID,
                    index: UInt64(index),
                    plainLength: UInt32(piece.count)
                )
                let box = try AES.GCM.seal(
                    piece,
                    using: key,
                    nonce: try AES.GCM.Nonce(data: nonce(for: index)),
                    authenticating: aad
                )
                return (Data(box.ciphertext), Data(box.tag))
            }
            try quota?.reserve(sealed.0.count)
            try body.write(contentsOf: sealed.0)
            records.append((piece.count, sealed.1))
            plaintextLength += piece.count
            if plaintextLength < 0 { throw VaultError.limitExceeded }
        }
        if plaintextLength == 0 { throw VaultError.emptyImport }
        try syncFile(body)
        try body.close()
        let bodyRead = try FileHandle(forReadingFrom: bodyURL)
        defer { try? bodyRead.close() }

        let indexPlain = indexPlaintext(records)
        let indexSealed = try dek.withUnsafeBytes { raw -> (Data, Data, Data) in
            let key = SymmetricKey(data: Data(raw))
            let parts = try CryptoBox.seal(indexPlain, key: key, aad: Data("PMV1-IDX".utf8) + withUUID(fileID))
            return (parts.nonce, parts.ciphertext, parts.tag)
        }
        var indexEnvelope = Data()
        indexEnvelope.append(indexSealed.0)
        Binary.append(UInt32(indexSealed.1.count), to: &indexEnvelope)
        indexEnvelope.append(indexSealed.1)
        indexEnvelope.append(indexSealed.2)
        let indexHash = CryptoBox.sha256(indexEnvelope)

        let headerPlain = headerPlaintext(
            chunkSize: chunkSize,
            plaintextLength: plaintextLength,
            chunkCount: records.count,
            fileID: fileID,
            indexHash: indexHash
        )
        let headerSealed = try dek.withUnsafeBytes { raw -> (Data, Data, Data) in
            let key = SymmetricKey(data: Data(raw))
            let parts = try CryptoBox.seal(headerPlain, key: key, aad: Data("PMV1-HDR".utf8) + withUUID(fileID))
            return parts
        }
        guard headerSealed.1.count == headerPlainLength, headerSealed.2.count == 16, headerSealed.0.count == 12 else {
            throw VaultError.malformed
        }

        let wrapped = try wrapDEK(dek, fileID: fileID, masterKey: masterKey)
        var prefix = Data()
        prefix.append(contentsOf: [0x50, 0x4d, 0x56, 0x31])
        Binary.append(UInt16(1), to: &prefix)
        prefix.append(withUUID(fileID))
        prefix.append(wrapped.nonce)
        prefix.append(wrapped.ciphertext)
        prefix.append(wrapped.tag)
        prefix.append(headerSealed.0)
        prefix.append(headerSealed.1)
        prefix.append(headerSealed.2)
        guard prefix.count == prefixLength else {
            throw VaultError.malformed
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            throw VaultError.alreadyExists
        }
        let finalSize = prefix.count + indexEnvelope.count + bodySize(records) + trailer.count
        try quota?.reserve(prefix.count + indexEnvelope.count + trailer.count)
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            try output.write(contentsOf: prefix)
            try output.write(contentsOf: indexEnvelope)
            var left = bodySize(records)
            while left > 0 {
                let n = min(left, chunkSize)
                guard let chunk = try bodyRead.read(upToCount: n), !chunk.isEmpty else {
                    throw VaultError.truncated
                }
                try output.write(contentsOf: chunk)
                left -= chunk.count
            }
            try output.write(contentsOf: trailer)
            try syncFile(output)
            try output.close()
        } catch {
            try? output.close()
            shredFile(destination)
            throw error
        }
        _ = finalSize
        return Written(plaintextLength: plaintextLength, sha256: Data(hasher.finalize()), fileID: fileID)
    }

    static func parse(handle: FileHandle, masterKey: MasterKey) throws -> Parsed {
        let fileLength = try handle.seekToEnd()
        guard fileLength >= UInt64(prefixLength + 8) else { throw VaultError.truncated }
        try handle.seek(toOffset: fileLength - 8)
        guard let trailerBytes = try handle.read(upToCount: 8), trailerBytes == trailer else {
            throw VaultError.truncated
        }
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: prefixLength), prefix.count == prefixLength else {
            throw VaultError.truncated
        }
        guard prefix.prefix(4) == Data([0x50, 0x4d, 0x56, 0x31]) else { throw VaultError.malformed }
        var offset = 4
        let version = try Binary.readUInt16(prefix, &offset)
        guard version == 1 else { throw VaultError.unsupportedVersion(Int(version)) }
        let fileIDData = prefix.subdata(in: offset ..< offset + 16)
        offset += 16
        let fileID = try uuid(from: fileIDData)
        let dekNonce = prefix.subdata(in: offset ..< offset + 12)
        offset += 12
        let dekCipher = prefix.subdata(in: offset ..< offset + 32)
        offset += 32
        let dekTag = prefix.subdata(in: offset ..< offset + 16)
        offset += 16
        let headerNonce = prefix.subdata(in: offset ..< offset + 12)
        offset += 12
        let headerCipher = prefix.subdata(in: offset ..< offset + headerPlainLength)
        offset += headerPlainLength
        let headerTag = prefix.subdata(in: offset ..< offset + 16)
        guard offset + 16 == prefixLength else { throw VaultError.malformed }

        let dek = try masterKey.withSymmetricKey { key -> [UInt8] in
            let plain = try CryptoBox.open(
                ciphertext: dekCipher,
                tag: dekTag,
                nonce: dekNonce,
                key: key,
                aad: Data("PMV1-DEK".utf8) + fileIDData
            )
            guard plain.count == 32 else { throw VaultError.integrityFailed }
            return [UInt8](plain)
        }
        let headerPlain = try dek.withUnsafeBytes { raw -> Data in
            let key = SymmetricKey(data: Data(raw))
            return try CryptoBox.open(
                ciphertext: headerCipher,
                tag: headerTag,
                nonce: headerNonce,
                key: key,
                aad: Data("PMV1-HDR".utf8) + fileIDData
            )
        }
        guard headerPlain.count == headerPlainLength else { throw VaultError.integrityFailed }
        var headerOffset = 0
        let chunkSize = Int(try Binary.readUInt32(headerPlain, &headerOffset))
        let plaintextLength64 = try Binary.readUInt64(headerPlain, &headerOffset)
        let chunkCount = Int(try Binary.readUInt32(headerPlain, &headerOffset))
        let headerFileID = headerPlain.subdata(in: headerOffset ..< headerOffset + 16)
        headerOffset += 16
        let indexHash = headerPlain.subdata(in: headerOffset ..< headerOffset + 32)
        guard headerFileID == fileIDData else { throw VaultError.integrityFailed }
        guard chunkSize >= minimumChunkSize, chunkSize <= maximumChunkSize else { throw VaultError.malformed }
        guard plaintextLength64 <= UInt64(Int.max) else { throw VaultError.limitExceeded }
        let plaintextLength = Int(plaintextLength64)
        let expectedCount = plaintextLength == 0 ? 0 : (plaintextLength + chunkSize - 1) / chunkSize
        guard chunkCount == expectedCount else { throw VaultError.integrityFailed }

        guard let indexNonce = try handle.read(upToCount: 12), indexNonce.count == 12 else {
            throw VaultError.truncated
        }
        guard let lengthData = try handle.read(upToCount: 4), lengthData.count == 4 else {
            throw VaultError.truncated
        }
        var lengthOffset = 0
        let indexCipherLength = Int(try Binary.readUInt32(lengthData, &lengthOffset))
        guard indexCipherLength >= 0, indexCipherLength <= 32 * 1024 * 1024 else { throw VaultError.malformed }
        guard let indexCipher = try handle.read(upToCount: indexCipherLength), indexCipher.count == indexCipherLength else {
            throw VaultError.truncated
        }
        guard let indexTag = try handle.read(upToCount: 16), indexTag.count == 16 else {
            throw VaultError.truncated
        }
        var envelope = Data()
        envelope.append(indexNonce)
        envelope.append(lengthData)
        envelope.append(indexCipher)
        envelope.append(indexTag)
        guard SecretCompare.equal(CryptoBox.sha256(envelope), indexHash) else {
            throw VaultError.integrityFailed
        }
        let indexPlain = try dek.withUnsafeBytes { raw -> Data in
            let key = SymmetricKey(data: Data(raw))
            return try CryptoBox.open(
                ciphertext: indexCipher,
                tag: indexTag,
                nonce: indexNonce,
                key: key,
                aad: Data("PMV1-IDX".utf8) + fileIDData
            )
        }
        let indexStart = prefixLength
        let bodyStart = indexStart + envelope.count
        var records: [ChunkRecord] = []
        var cursor = 0
        var cipherCursor = bodyStart
        var plainSum = 0
        while cursor < indexPlain.count {
            let cipherLength = Int(try Binary.readUInt32(indexPlain, &cursor))
            guard cursor + 16 <= indexPlain.count else { throw VaultError.malformed }
            let tag = indexPlain.subdata(in: cursor ..< cursor + 16)
            cursor += 16
            let plainLength = Int(try Binary.readUInt32(indexPlain, &cursor))
            guard cipherLength == plainLength, plainLength > 0, plainLength <= chunkSize else {
                throw VaultError.integrityFailed
            }
            records.append(ChunkRecord(cipherLength: cipherLength, plainLength: plainLength, tag: tag, cipherOffset: cipherCursor))
            cipherCursor += cipherLength
            plainSum += plainLength
        }
        guard records.count == chunkCount, plainSum == plaintextLength else { throw VaultError.integrityFailed }
        let expectedEnd = UInt64(cipherCursor + trailer.count)
        guard expectedEnd == fileLength else { throw VaultError.integrityFailed }
        return Parsed(plaintextLength: plaintextLength, fileID: fileID, chunkSize: chunkSize, dek: dek, records: records)
    }

    static func nonce(for index: Int) -> Data {
        var data = Data(count: 12)
        var value = UInt64(index).bigEndian
        withUnsafeBytes(of: &value) { raw in
            data.replaceSubrange(4 ..< 12, with: raw)
        }
        return data
    }

    static func chunkAAD(fileID: UUID, index: UInt64, plainLength: UInt32) -> Data {
        var data = Data("PMV1-CHK".utf8)
        data.append(withUUID(fileID))
        var indexBE = index.bigEndian
        var lengthBE = plainLength.bigEndian
        withUnsafeBytes(of: &indexBE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lengthBE) { data.append(contentsOf: $0) }
        return data
    }

    private static func wrapDEK(_ dek: [UInt8], fileID: UUID, masterKey: MasterKey) throws -> (nonce: Data, ciphertext: Data, tag: Data) {
        try masterKey.withSymmetricKey { key in
            try CryptoBox.seal(Data(dek), key: key, aad: Data("PMV1-DEK".utf8) + withUUID(fileID))
        }
    }

    private static func indexPlaintext(_ records: [(plainLength: Int, tag: Data)]) -> Data {
        var data = Data()
        for record in records {
            Binary.append(UInt32(record.plainLength), to: &data)
            data.append(record.tag)
            Binary.append(UInt32(record.plainLength), to: &data)
        }
        return data
    }

    private static func headerPlaintext(
        chunkSize: Int,
        plaintextLength: Int,
        chunkCount: Int,
        fileID: UUID,
        indexHash: Data
    ) -> Data {
        var data = Data()
        Binary.append(UInt32(chunkSize), to: &data)
        Binary.append(UInt64(plaintextLength), to: &data)
        Binary.append(UInt32(chunkCount), to: &data)
        data.append(withUUID(fileID))
        data.append(indexHash)
        return data
    }

    private static func bodySize(_ records: [(plainLength: Int, tag: Data)]) -> Int {
        records.reduce(0) { $0 + $1.plainLength }
    }
}

func withUUID(_ id: UUID) -> Data {
    var uuid = id.uuid
    return Data(bytes: &uuid, count: MemoryLayout<uuid_t>.size)
}

func uuid(from data: Data) throws -> UUID {
    guard data.count == 16 else { throw VaultError.malformed }
    let bytes = [UInt8](data)
    let tuple = (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
    return UUID(uuid: tuple)
}
