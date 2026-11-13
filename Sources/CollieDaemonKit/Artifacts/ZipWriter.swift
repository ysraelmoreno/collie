import Foundation
import zlib

enum ZipError: Error, Equatable { case tooLarge }

/// Store-only ZIP (method 0, no zip64): enough for a .pptx.
enum ZipWriter {
    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
    }

    static func archive(_ entries: [(name: String, data: Data)]) throws(ZipError) -> Data {
        guard entries.count <= Int(UInt16.max) else { throw .tooLarge }
        let limit = Int(UInt32.max)
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = ((2026 - 1980) << 9) | (1 << 5) | 1   // 2026-01-01
        var out = Data(), central = Data()

        func u16(_ d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        for e in entries {
            let name = Data(e.name.utf8)
            guard e.data.count <= limit, name.count <= Int(UInt16.max), out.count <= limit else { throw .tooLarge }
            let crc = crc32(e.data), size = UInt32(e.data.count), offset = UInt32(out.count)
            u32(&out, 0x04034b50); u16(&out, 20); u16(&out, 1 << 11); u16(&out, 0)
            u16(&out, dosTime); u16(&out, dosDate); u32(&out, crc); u32(&out, size); u32(&out, size)
            u16(&out, UInt16(name.count)); u16(&out, 0)
            out.append(name); out.append(e.data)

            u32(&central, 0x02014b50); u16(&central, 20); u16(&central, 20); u16(&central, 1 << 11); u16(&central, 0)
            u16(&central, dosTime); u16(&central, dosDate); u32(&central, crc); u32(&central, size); u32(&central, size)
            u16(&central, UInt16(name.count)); u16(&central, 0); u16(&central, 0); u16(&central, 0); u16(&central, 0)
            u32(&central, 0); u32(&central, offset)
            central.append(name)
        }
        guard out.count <= limit, out.count + central.count <= limit else { throw .tooLarge }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(&out, 0x06054b50); u16(&out, 0); u16(&out, 0)
        u16(&out, UInt16(entries.count)); u16(&out, UInt16(entries.count))
        u32(&out, UInt32(central.count)); u32(&out, cdOffset); u16(&out, 0)
        return out
    }
}
