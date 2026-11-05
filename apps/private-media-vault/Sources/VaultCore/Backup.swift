import Crypto
import Foundation

enum BackupArchive {
    static func create(vaultDirectory: URL, masterKey: MasterKey, to destination: URL, quota: ByteQuota?) throws -> RecoveryKey {
        if FileManager.default.fileExists(atPath: destination.path) { throw VaultError.alreadyExists }
        let recovery = RecoveryKey.generate()
        var backupDEK = MasterKey.generate()
        defer { backupDEK.wipe() }
        let payload = destination.appendingPathExtension("payload")
        let source = try ArchiveByteSource(vaultDirectory: vaultDirectory, masterKey: masterKey)
        defer { source.wipe() }
        _ = try ChunkContainer.encrypt(
            source: source,
            to: payload,
            masterKey: backupDEK,
            chunkSize: ChunkContainer.defaultChunkSize,
            quota: quota
        )
        defer { shredFile(payload) }
        let salt = randomBytes(count: 32)
        let wrapped = try recovery.withSymmetricKey { recoveryKey in
            let kek = try CryptoBox.derive(ikm: recoveryKey, salt: salt, info: "pmv-backup-dek-v1")
            return try backupDEK.withSymmetricKey { dek in
                let bytes = dek.withUnsafeBytes { Data($0) }
                return try CryptoBox.seal(bytes, key: kek, aad: Data("PMVB-DEK".utf8) + salt)
            }
        }
        var header = Data("PMVB".utf8)
        Binary.append(UInt16(1), to: &header)
        header.append(salt)
        header.append(wrapped.nonce)
        header.append(wrapped.ciphertext)
        header.append(wrapped.tag)
        guard header.count == 98 else { throw VaultError.malformed }
        try quota?.reserve(header.count)
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            try output.write(contentsOf: header)
            let input = try FileHandle(forReadingFrom: payload)
            defer { try? input.close() }
            while true {
                guard let chunk = try input.read(upToCount: ChunkContainer.defaultChunkSize) else { break }
                if chunk.isEmpty { break }
                try quota?.reserve(chunk.count)
                try output.write(contentsOf: chunk)
            }
            try syncFile(output)
            try output.close()
        } catch {
            try? output.close()
            shredFile(destination)
            throw error
        }
        return recovery
    }

    static func restore(from backup: URL, recoveryKey: RecoveryKey, to vaultDirectory: URL) throws -> MasterKey {
        if FileManager.default.fileExists(atPath: vaultDirectory.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: vaultDirectory.path)
            guard contents.isEmpty else { throw VaultError.alreadyExists }
        } else {
            try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
        }
        let headerCount = 98
        let handle = try FileHandle(forReadingFrom: backup)
        guard let header = try handle.read(upToCount: headerCount), header.count == headerCount else {
            try? handle.close()
            throw VaultError.truncated
        }
        guard header.prefix(4) == Data("PMVB".utf8) else {
            try? handle.close()
            throw VaultError.malformed
        }
        var offset = 4
        let version = try Binary.readUInt16(header, &offset)
        guard version == 1 else { throw VaultError.unsupportedVersion(Int(version)) }
        let salt = header.subdata(in: offset ..< offset + 32)
        offset += 32
        let nonce = header.subdata(in: offset ..< offset + 12)
        offset += 12
        let cipher = header.subdata(in: offset ..< offset + 32)
        offset += 32
        let tag = header.subdata(in: offset ..< offset + 16)
        let backupDEK = try recoveryKey.withSymmetricKey { recovery -> MasterKey in
            let kek = try CryptoBox.derive(ikm: recovery, salt: salt, info: "pmv-backup-dek-v1")
            let plain = try CryptoBox.open(
                ciphertext: cipher,
                tag: tag,
                nonce: nonce,
                key: kek,
                aad: Data("PMVB-DEK".utf8) + salt
            )
            guard plain.count == 32 else { throw VaultError.authenticationFailed }
            return MasterKey(data: plain)
        }
        let payload = vaultDirectory.appendingPathComponent(".backup-payload")
        _ = FileManager.default.createFile(atPath: payload.path, contents: nil)
        let payloadHandle = try FileHandle(forWritingTo: payload)
        do {
            while true {
                guard let chunk = try handle.read(upToCount: ChunkContainer.defaultChunkSize) else { break }
                if chunk.isEmpty { break }
                try payloadHandle.write(contentsOf: chunk)
            }
            try syncFile(payloadHandle)
            try payloadHandle.close()
            try handle.close()
        } catch {
            try? payloadHandle.close()
            try? handle.close()
            shredFile(payload)
            throw error
        }
        defer { shredFile(payload) }
        let reader = try ChunkedReader(url: payload, masterKey: backupDEK)
        defer { reader.close() }
        let parser = SequentialPlaintext(reader: reader)
        var master: MasterKey?
        var sawCatalog = false
        var sawEnd = false
        var names = Set<String>()
        while !sawEnd {
            let type = try parser.readUInt8()
            let nameLength = Int(try parser.readUInt16())
            guard nameLength <= 200 else { throw VaultError.pathRejected }
            let nameData = try parser.read(nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else { throw VaultError.pathRejected }
            let payloadLength64 = try parser.readUInt64()
            guard payloadLength64 <= UInt64(Int.max) else { throw VaultError.limitExceeded }
            let payloadLength = Int(payloadLength64)
            if type == 255 {
                guard nameLength == 0, payloadLength == 0 else { throw VaultError.malformed }
                sawEnd = true
                break
            }
            guard names.insert(name).inserted else { throw VaultError.pathRejected }
            switch type {
            case 1:
                guard name == "vmk", payloadLength == 32 else { throw VaultError.malformed }
                let bytes = try parser.read(32)
                master = MasterKey(data: bytes)
            case 2:
                guard name == "catalog" else { throw VaultError.pathRejected }
                try parser.copy(payloadLength, to: vaultDirectory.appendingPathComponent(VaultPaths.catalogName))
                sawCatalog = true
            case 3, 4:
                let folder = type == 3 ? VaultPaths.blobDirectory : VaultPaths.thumbDirectory
                let prefix = type == 3 ? "blob/" : "thumb/"
                guard name.hasPrefix(prefix) else { throw VaultError.pathRejected }
                let blobName = String(name.dropFirst(prefix.count))
                guard VaultPaths.isSafeBlobName(blobName), !blobName.contains("/") else { throw VaultError.pathRejected }
                let directory = vaultDirectory.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try parser.copy(payloadLength, to: directory.appendingPathComponent(blobName))
            default:
                throw VaultError.malformed
            }
        }
        guard sawEnd, parser.finished, sawCatalog, let master else {
            shredTree(vaultDirectory)
            throw VaultError.malformed
        }
        try FileManager.default.createDirectory(
            at: vaultDirectory.appendingPathComponent(VaultPaths.stagingDirectory, isDirectory: true),
            withIntermediateDirectories: true
        )
        do {
            _ = try VaultStore(directory: vaultDirectory, masterKey: master)
        } catch {
            shredTree(vaultDirectory)
            throw error
        }
        return master
    }
}

final class ArchiveByteSource: ByteSource {
    struct Piece {
        var type: UInt8
        var name: String
        var memory: Data?
        var file: URL?
    }

    private var pieces: [Piece]
    private var index = 0
    private var header: Data = Data()
    private var headerOffset = 0
    private var payloadLeft = 0
    private var handle: FileHandle?
    private var ended = false
    private var vmkBytes: [UInt8]

    init(vaultDirectory: URL, masterKey: MasterKey) throws {
        vmkBytes = masterKey.copyBytes()
        var pieces: [Piece] = [
            Piece(type: 1, name: "vmk", memory: Data(vmkBytes), file: nil),
            Piece(type: 2, name: "catalog", memory: nil, file: vaultDirectory.appendingPathComponent(VaultPaths.catalogName)),
        ]
        let blobs = try FileManager.default.contentsOfDirectory(atPath: vaultDirectory.appendingPathComponent(VaultPaths.blobDirectory).path).sorted()
        for name in blobs where VaultPaths.isSafeBlobName(name) {
            pieces.append(Piece(type: 3, name: "blob/\(name)", memory: nil, file: vaultDirectory.appendingPathComponent(VaultPaths.blobDirectory).appendingPathComponent(name)))
        }
        let thumbs = try FileManager.default.contentsOfDirectory(atPath: vaultDirectory.appendingPathComponent(VaultPaths.thumbDirectory).path).sorted()
        for name in thumbs where VaultPaths.isSafeBlobName(name) {
            pieces.append(Piece(type: 4, name: "thumb/\(name)", memory: nil, file: vaultDirectory.appendingPathComponent(VaultPaths.thumbDirectory).appendingPathComponent(name)))
        }
        self.pieces = pieces
        try prepareHeader()
    }

    func wipe() {
        insecureWipe(&vmkBytes)
        for index in pieces.indices {
            pieces[index].memory = nil
        }
    }

    func read(maxLength: Int) throws -> Data {
        guard maxLength > 0 else { return Data() }
        var output = Data()
        while output.count < maxLength {
            if headerOffset < header.count {
                let take = min(maxLength - output.count, header.count - headerOffset)
                output.append(header.subdata(in: headerOffset ..< headerOffset + take))
                headerOffset += take
                continue
            }
            if payloadLeft > 0 {
                let take = min(maxLength - output.count, payloadLeft)
                if let handle {
                    guard let chunk = try handle.read(upToCount: take), chunk.count == take else {
                        throw VaultError.truncated
                    }
                    output.append(chunk)
                } else if let memory = pieces[index - 1].memory {
                    let start = memory.count - payloadLeft
                    output.append(memory.subdata(in: start ..< start + take))
                } else {
                    throw VaultError.malformed
                }
                payloadLeft -= take
                if payloadLeft == 0 {
                    try handle?.close()
                    handle = nil
                    if index >= pieces.count, !ended {
                        try appendEnd()
                    } else if index < pieces.count {
                        try prepareHeader()
                    }
                }
                continue
            }
            if ended { break }
            if index >= pieces.count {
                try appendEnd()
                continue
            }
            try prepareHeader()
        }
        return output
    }

    private func prepareHeader() throws {
        guard index < pieces.count else { return }
        let piece = pieces[index]
        index += 1
        let name = Data(piece.name.utf8)
        var data = Data()
        data.append(piece.type)
        Binary.append(UInt16(name.count), to: &data)
        data.append(name)
        let length: UInt64
        if let memory = piece.memory {
            length = UInt64(memory.count)
            handle = nil
        } else if let file = piece.file {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? (attributes[.size] as? UInt64) ?? 0
            length = size
            handle = try FileHandle(forReadingFrom: file)
        } else {
            throw VaultError.malformed
        }
        Binary.append(length, to: &data)
        header = data
        headerOffset = 0
        payloadLeft = Int(length)
    }

    private func appendEnd() throws {
        var data = Data()
        data.append(255)
        Binary.append(UInt16(0), to: &data)
        Binary.append(UInt64(0), to: &data)
        header = data
        headerOffset = 0
        payloadLeft = 0
        ended = true
        index = pieces.count + 1
    }
}

final class SequentialPlaintext {
    let reader: ChunkedReader
    private var offset = 0
    var finished: Bool { offset == reader.plaintextLength }

    init(reader: ChunkedReader) { self.reader = reader }

    func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= reader.plaintextLength else { throw VaultError.truncated }
        if count == 0 { return Data() }
        let data = try reader.plaintext(byteRange: offset ..< offset + count)
        offset += count
        return data
    }

    func readUInt8() throws -> UInt8 {
        let data = try read(1)
        return data[0]
    }

    func readUInt16() throws -> UInt16 {
        let data = try read(2)
        var cursor = 0
        return try Binary.readUInt16(data, &cursor)
    }

    func readUInt64() throws -> UInt64 {
        let data = try read(8)
        var cursor = 0
        return try Binary.readUInt64(data, &cursor)
    }

    func copy(_ count: Int, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { throw VaultError.alreadyExists }
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var left = count
        do {
            while left > 0 {
                let n = min(left, ChunkContainer.defaultChunkSize)
                let piece = try read(n)
                try handle.write(contentsOf: piece)
                left -= n
            }
            try syncFile(handle)
            try handle.close()
        } catch {
            try? handle.close()
            shredFile(url)
            throw error
        }
    }
}
