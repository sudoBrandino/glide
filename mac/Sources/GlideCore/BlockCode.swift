import CoreGraphics
import Foundation

/// Machine-readable clock "block code" for glass-to-glass latency tests (docs/LATENCY.md).
/// One row of 56 square cells (white = 1, black = 0) on a black quiet zone:
/// sync 10110010 | value (32 bits, MSB first) | kind (4) | counter (4) | CRC-8/SMBUS over
/// [value big-endian, kind << 4 | counter]. The viewer (`windows/src/blockcode.rs`) finds and
/// decodes it in the decoded frame; `value` is the low 32 bits of a host time in µs.
public enum BlockCode {
    public static let sync: UInt8 = 0b1011_0010
    public static let cells = 56
    /// Black cells around the code on every side.
    public static let quiet = 2
    /// `value` = draw time.
    public static let kindDraw: UInt8 = 0
    /// `value` = display link target timestamp (when the frame is due on the display).
    public static let kindTarget: UInt8 = 1

    public static func crc8(_ data: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for b in data {
            c ^= b
            for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        }
        return c
    }

    public static func bits(value: UInt32, kind: UInt8, counter: UInt8) -> [Bool] {
        let p: [UInt8] = [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF), (kind & 15) << 4 | (counter & 15)]
        let bytes = [sync] + p + [crc8(p)]
        return (0..<cells).map { bytes[$0 / 8] >> (7 - UInt8($0 % 8)) & 1 == 1 }
    }

    /// Pattern size in cells: (56 + 2 × quiet) wide, 4 tall (black row, 2-cell code strip, black row).
    public static var widthCells: Int { cells + 2 * quiet }
    public static let heightCells = 4

    /// Draws the pattern into `ctx` (origin bottom-left, as in AppKit) with `cell`-point cells.
    public static func draw(in ctx: CGContext, origin: CGPoint, cell: CGFloat, value: UInt32, kind: UInt8, counter: UInt8) {
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: origin.x, y: origin.y, width: CGFloat(widthCells) * cell, height: CGFloat(heightCells) * cell))
        ctx.setFillColor(gray: 1, alpha: 1)
        for (i, b) in bits(value: value, kind: kind, counter: counter).enumerated() where b {
            ctx.fill(CGRect(x: origin.x + CGFloat(quiet + i) * cell, y: origin.y + cell, width: cell, height: 2 * cell))
        }
    }
}
