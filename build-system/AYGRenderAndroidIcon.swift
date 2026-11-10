import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Minimal SVG path-data parser: the subset Android vector drawables actually emit.
struct PathParser {
    let s: [Character]
    var i = 0
    init(_ str: String) { s = Array(str) }

    mutating func skipSep() {
        while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
    }
    mutating func number() -> CGFloat? {
        skipSep()
        var start = i
        if i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
        var sawDigit = false, sawDot = false
        while i < s.count {
            let c = s[i]
            if c.isNumber { sawDigit = true; i += 1 }
            else if c == "." && !sawDot { sawDot = true; i += 1 }
            else if (c == "e" || c == "E"), sawDigit {
                i += 1
                if i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
            } else { break }
        }
        guard sawDigit else { i = start; return nil }
        return CGFloat(Double(String(s[start..<i])) ?? 0)
    }
    mutating func command() -> Character? {
        skipSep()
        guard i < s.count else { return nil }
        let c = s[i]
        if c.isLetter { i += 1; return c }
        return nil
    }
    var atEnd: Bool { mutating get { skipSep(); return i >= s.count } }
}

func buildPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var p = PathParser(d)
    var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
    var cmd: Character = "M"
    while !p.atEnd {
        if let c = p.command() { cmd = c }
        let rel = cmd.isLowercase
        switch Character(cmd.lowercased()) {
        case "m":
            guard let x = p.number(), let y = p.number() else { break }
            cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            path.move(to: cur); start = cur; lastCtrl = nil
            cmd = rel ? "l" : "L"
        case "l":
            guard let x = p.number(), let y = p.number() else { break }
            cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            path.addLine(to: cur); lastCtrl = nil
        case "h":
            guard let x = p.number() else { break }
            cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
            path.addLine(to: cur); lastCtrl = nil
        case "v":
            guard let y = p.number() else { break }
            cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
            path.addLine(to: cur); lastCtrl = nil
        case "c":
            guard let x1 = p.number(), let y1 = p.number(), let x2 = p.number(),
                  let y2 = p.number(), let x = p.number(), let y = p.number() else { break }
            let c1 = rel ? CGPoint(x: cur.x + x1, y: cur.y + y1) : CGPoint(x: x1, y: y1)
            let c2 = rel ? CGPoint(x: cur.x + x2, y: cur.y + y2) : CGPoint(x: x2, y: y2)
            let e  = rel ? CGPoint(x: cur.x + x,  y: cur.y + y)  : CGPoint(x: x,  y: y)
            path.addCurve(to: e, control1: c1, control2: c2)
            cur = e; lastCtrl = c2
        case "s":
            guard let x2 = p.number(), let y2 = p.number(), let x = p.number(), let y = p.number() else { break }
            let c2 = rel ? CGPoint(x: cur.x + x2, y: cur.y + y2) : CGPoint(x: x2, y: y2)
            let e  = rel ? CGPoint(x: cur.x + x,  y: cur.y + y)  : CGPoint(x: x,  y: y)
            let c1 = lastCtrl.map { CGPoint(x: 2*cur.x - $0.x, y: 2*cur.y - $0.y) } ?? cur
            path.addCurve(to: e, control1: c1, control2: c2)
            cur = e; lastCtrl = c2
        case "q":
            guard let x1 = p.number(), let y1 = p.number(), let x = p.number(), let y = p.number() else { break }
            let c1 = rel ? CGPoint(x: cur.x + x1, y: cur.y + y1) : CGPoint(x: x1, y: y1)
            let e  = rel ? CGPoint(x: cur.x + x,  y: cur.y + y)  : CGPoint(x: x,  y: y)
            path.addQuadCurve(to: e, control: c1); cur = e; lastCtrl = c1
        case "t":
            guard let x = p.number(), let y = p.number() else { break }
            let e = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            let c1 = lastCtrl.map { CGPoint(x: 2*cur.x - $0.x, y: 2*cur.y - $0.y) } ?? cur
            path.addQuadCurve(to: e, control: c1); cur = e; lastCtrl = c1
        case "z":
            path.closeSubpath(); cur = start; lastCtrl = nil
        default:
            _ = p.number()
        }
    }
    return path
}

// AYG: renders an Android adaptive-icon layer stack to one square PNG.
//
// args: out.png pixelSize viewport  then one "#aarrggbb:pathdata" per path, in
// document order — background layer first, foreground second.
//
// Each `<path>` is filled independently for the same reason `AYGRenderVectorPath`
// does it: merging them XORs overlapping shapes.
let outPath = CommandLine.arguments[1]
let px = Int(CommandLine.arguments[2])!
let viewport = CGFloat(Double(CommandLine.arguments[3])!)
let specs = Array(CommandLine.arguments.dropFirst(4))

func parseColor(_ s: String) -> CGColor {
    var hex = s
    if hex.hasPrefix("#") { hex.removeFirst() }
    let value = UInt32(hex, radix: 16) ?? 0xFFFFFFFF
    let a = CGFloat((value >> 24) & 0xFF) / 255.0
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
ctx.translateBy(x: 0, y: CGFloat(px))
ctx.scaleBy(x: CGFloat(px) / viewport, y: -CGFloat(px) / viewport)

for spec in specs {
    guard let sep = spec.firstIndex(of: ":") else { continue }
    let color = parseColor(String(spec[spec.startIndex ..< sep]))
    let d = String(spec[spec.index(after: sep)...])
    ctx.setFillColor(color)
    ctx.addPath(buildPath(d))
    ctx.fillPath(using: .evenOdd)
}

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath)
let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, img, nil)
CGImageDestinationFinalize(dst)
print("wrote \(url.lastPathComponent) \(px)x\(px)")
