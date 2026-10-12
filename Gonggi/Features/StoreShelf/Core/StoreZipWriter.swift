import Foundation

/// Minimal ZIP writer (method "stored", no compression: JPEG and JSON of this size need none). Used to package a
/// diagnostics bundle into one file. Pure Swift.
struct StoreZipWriter {
    private struct Entry {
        var name: String
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private(set) var data = Data()
    private var entries: [Entry] = []

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private mutating func u32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    /// Files larger than 4 GB are not supported (never the case here).
    mutating func add(name: String, contents: Data) {
        let nameBytes = Array(name.utf8)
        let crc = Self.crc32(contents)
        let offset = UInt32(data.count)
        u32(0x0403_4B50)           // local file header
        u16(20)                    // version needed
        u16(0x0800)                // flags: UTF-8 names
        u16(0)                     // method: stored
        u16(0)                     // time
        u16(0x21)                  // date (1980-01-01)
        u32(crc)
        u32(UInt32(contents.count))
        u32(UInt32(contents.count))
        u16(UInt16(nameBytes.count))
        u16(0)                     // extra length
        data.append(contentsOf: nameBytes)
        data.append(contents)
        entries.append(Entry(name: name, crc: crc, size: UInt32(contents.count), offset: offset))
    }

    /// Writes the central directory and returns the finished archive.
    mutating func finish() -> Data {
        let start = UInt32(data.count)
        for e in entries {
            let nameBytes = Array(e.name.utf8)
            u32(0x0201_4B50)       // central directory header
            u16(20)                // version made by
            u16(20)                // version needed
            u16(0x0800)
            u16(0)
            u16(0)
            u16(0x21)
            u32(e.crc)
            u32(e.size)
            u32(e.size)
            u16(UInt16(nameBytes.count))
            u16(0)                 // extra
            u16(0)                 // comment
            u16(0)                 // disk
            u16(0)                 // internal attrs
            u32(0)                 // external attrs
            u32(e.offset)
            data.append(contentsOf: nameBytes)
        }
        let size = UInt32(data.count) - start
        u32(0x0605_4B50)           // end of central directory
        u16(0)
        u16(0)
        u16(UInt16(entries.count))
        u16(UInt16(entries.count))
        u32(size)
        u32(start)
        u16(0)
        return data
    }
}
