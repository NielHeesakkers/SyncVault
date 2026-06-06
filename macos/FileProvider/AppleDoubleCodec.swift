import Foundation

/// Pure file→file transforms for preserving macOS resource forks across upload.
///
/// Classic Mac files (old fonts: suitcases, .suit, .fam, FFIL, …) keep their
/// content in the RESOURCE fork with a 0-byte data fork. A data-fork-only upload
/// therefore stores 0 bytes and loses the content. This helper bundles the data
/// fork + resource fork + FinderInfo into a single AppleDouble byte stream
/// (using the OS primitive copyfile(3), not a hand-rolled encoder) so the whole
/// file round-trips through a plain byte store. Detection on the way back is the
/// AppleDouble magic number — no server flag needed.
///
/// No dependency on the API client, cache, or FileProvider types: just files.
enum AppleDoubleCodec {
    /// AppleDouble v2 signature: magic 0x00051607 + version 0x00020000 (8 bytes).
    /// We check all 8 (not just the 4-byte magic) on download so a plain data-fork
    /// file that coincidentally starts with the magic isn't mistaken for an
    /// AppleDouble and run through UNPACK → corruption. There is no server-side
    /// "packed" flag (by design), so this signature is the only discriminator;
    /// 8 bytes makes a false positive effectively impossible.
    static let signature: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]

    enum CodecError: Error { case packFailed(Int32), unpackFailed(Int32) }

    /// True if the file carries a non-empty resource fork.
    static func hasResourceFork(_ url: URL) -> Bool {
        return url.path.withCString { p in
            "com.apple.ResourceFork".withCString { name in
                getxattr(p, name, nil, 0, 0, 0) > 0
            }
        }
    }

    /// Whether to pack this file as an AppleDouble blob on upload.
    ///
    /// CRITICAL: copyfile(COPYFILE_PACK) writes an AppleDouble, which by design
    /// carries the resource fork + FinderInfo but NOT the data fork (that stays
    /// in the main file). So we only pack when the data fork is empty — exactly
    /// the classic-Mac-font case (0-byte data fork, content in the resource
    /// fork). A file with BOTH a non-empty data fork and a resource fork would
    /// lose its data fork if packed, so it falls back to the plain data-fork
    /// upload (same as before — no regression, only the rare resource fork of
    /// such a file isn't synced). Verified by codec round-trip tests.
    static func shouldPack(_ url: URL) -> Bool {
        guard hasResourceFork(url) else { return false }
        let dataForkSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return dataForkSize == 0
    }

    /// True if `url` begins with the full 8-byte AppleDouble signature.
    static func isAppleDouble(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8), head.count == 8 else { return false }
        return Array(head) == signature
    }

    /// PACK {data fork + resource fork + FinderInfo + xattrs} of `url` into a new
    /// temp AppleDouble file. Returns the temp URL (caller deletes it).
    static func pack(_ url: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".appledouble")
        let flags = copyfile_flags_t(COPYFILE_PACK | COPYFILE_DATA | COPYFILE_METADATA)
        let rc = url.path.withCString { src in
            out.path.withCString { dst in
                copyfile(src, dst, nil, flags)
            }
        }
        guard rc == 0 else { throw CodecError.packFailed(errno) }
        return out
    }

    /// UNPACK an AppleDouble file back into a real file carrying both forks +
    /// FinderInfo. Returns the temp URL of the reconstructed file.
    static func unpack(_ url: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".unpacked")
        let flags = copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_DATA | COPYFILE_METADATA)
        let rc = url.path.withCString { src in
            out.path.withCString { dst in
                copyfile(src, dst, nil, flags)
            }
        }
        guard rc == 0 else { throw CodecError.unpackFailed(errno) }
        return out
    }
}
