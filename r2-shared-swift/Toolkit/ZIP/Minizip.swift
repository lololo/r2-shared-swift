//
//  Minizip.swift
//  r2-shared-swift
//
//  Created by Mickaël Menu on 15/04/2020.
//
//  Copyright 2020 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import Minizip

/// A `ZIPArchive` using the Minizip library.
final class MinizipArchive: ZIPArchive, Loggable {
    
    private let archive: unzFile

    /// Returns whether the current entry is opened.
    private var isCurrentEntryOpened = false

    init(file: URL, password: String?) throws {
        guard (try? file.checkResourceIsReachable()) ?? false,
            let archive = unzOpen64(file.path) else
        {
            throw ZIPError.openFailed
        }
        self.archive = archive
    }
    
    deinit {
        transaction {
            unzClose(archive)
        }
    }

    lazy var entries: [ZIPEntry] = transaction {
        var entries = [ZIPEntry]()
        guard goToFirstEntry() else {
            return entries
        }
        
        repeat {
            if let entry = makeEntryAtCurrentOffset() {
                entries.append(entry)
            }
        } while goToNextEntry()
        
        return entries
    }

    func entry(at path: String) -> ZIPEntry? {
        return transaction {
            guard goToEntry(at: path) else {
                return nil
            }
            return makeEntryAtCurrentOffset()
        }
    }
    
    func read(at path: String) -> Data? {
        return transaction {
            guard goToEntry(at: path),
                let entry = makeEntryAtCurrentOffset() else
            {
                return nil
            }
            
            return openCurrentEntry {
                readFromCurrentOffset(length: entry.length)
            }
        }
    }
    
    func read(at path: String, range: Range<UInt64>) -> Data? {
        return transaction {
            guard goToEntry(at: path) else {
                return nil
            }
            
            return openCurrentEntry {
                guard seek(by: range.lowerBound) else {
                    return nil
                }
                let length = (range.upperBound - range.lowerBound)
                return readFromCurrentOffset(length: length)
            }
        }
    }
    
    /// Makes the access to the Minizip archive thread-safe.
    @discardableResult
    private func transaction<T>(_ block: () -> T) -> T {
        objc_sync_enter(archive)
        defer { objc_sync_exit(archive) }
        return block()
    }
    
}

// MARK: Minizip C++ Bridge
private extension MinizipArchive {
    
    /// Length of the buffer used when reading an entry's data.
    var bufferLength: Int { 1024 * 64 }

    /// Moves offset to the first entry in the archive.
    func goToFirstEntry() -> Bool {
        return execute { unzGoToFirstFile(archive) }
    }
    
    /// Moves offset to the next entry in the archive.
    ///
    /// - Returns: `false` in case of EOF or error.
    func goToNextEntry() -> Bool {
        let status = unzGoToNextFile(archive)
        switch status {
        case UNZ_END_OF_LIST_OF_FILE:
            return false
        case UNZ_OK:
            return true
        default:
            log(.error, "Minizip error: #\(status)")
            return false
        }
    }
    
    /// Moves the offset to the entry at `path`.
    func goToEntry(at path: String) -> Bool {
        return unzLocateFile(archive, path, nil) == UNZ_OK
    }
    
    /// Creates a `ZIPEntry` from the entry at the current offset in the archive.
    func makeEntryAtCurrentOffset() -> ZIPEntry? {
        let filenameMaxSize = 1024
        var fileInfo = unz_file_info64()
        let filename = UnsafeMutablePointer<CChar>.allocate(capacity: filenameMaxSize)
        defer {
            free(filename)
        }
        memset(&fileInfo, 0, MemoryLayout<unz_file_info64>.size)
        guard execute({ unzGetCurrentFileInfo64(archive, &fileInfo, filename, UInt(filenameMaxSize), nil, 0, nil, 0) }) else {
            return nil
        }
        let path = String(cString: filename)
        return ZIPEntry(
            path: path,
            isDirectory: path.hasSuffix("/"),
            length: UInt64(fileInfo.uncompressed_size),
            compressedLength: UInt64(fileInfo.compressed_size)
        )
    }
    
    /// Opens the entry at the current offset, to read its content.
    func openCurrentEntry<T>(_ read: () -> T?) -> T? {
        guard execute({ unzOpenCurrentFile(archive) }) else {
            return nil
        }
        isCurrentEntryOpened = true
        defer {
            _ = execute { unzCloseCurrentFile(archive) }
            isCurrentEntryOpened = false
        }
        
        return read()
    }
    
    /// Advances the current position in the archive by the given `offset`.
    ///
    /// - Returns: Whether the seeking operation was successful.
    func seek(by offset: UInt64) -> Bool {
        return readFromCurrentOffset(length: offset) { _, _ in
            // Unfortunately, deflate doesn't support random access, so we need to discard the content
            // until we reach the offset.
        }
    }

    /// Reads the given `length` of data at the current offset in the archive.
    func readFromCurrentOffset(length: UInt64) -> Data? {
        var data = Data(capacity: Int(length))
        let success = readFromCurrentOffset(length: length) { (bytes, length) in
            data.append(bytes, count: Int(length))
        }
        return success ? data : nil
    }
    
    typealias Consumer = (_ bytes: UnsafePointer<UInt8>, _ length: UInt64) -> Void
    
    /// Consumes the given `length` of data at the current offset in the archive.
    func readFromCurrentOffset(length: UInt64, consumer: Consumer) -> Bool {
        assert(isCurrentEntryOpened)
        
        var buffer = Array<CUnsignedChar>(repeating: 0, count: bufferLength)

        var totalBytesRead: UInt64 = 0
        while totalBytesRead < length {
            let bytesToRead = min(UInt64(bufferLength), length - totalBytesRead)
            let bytesRead = UInt64(unzReadCurrentFile(archive, &buffer, UInt32(bytesToRead)))
            if bytesRead == 0 {
                break
            }
            if bytesRead > 0 {
                totalBytesRead += bytesRead
                consumer(buffer, bytesRead)
            } else {
                log(.error, "Minizip error: Can't read current entry")
                return false
            }
        }
        return true
    }

    /// Executes a Minizip statement and checks its status.
    ///
    /// - Returns: Whether the statement was successful.
    func execute(_ block: () -> Int32) -> Bool {
        let status = block()
        guard status == UNZ_OK else {
            log(.error, "Minizip error: #\(status)")
            return false
        }
        return true
    }

}