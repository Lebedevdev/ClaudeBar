import AppKit
import CoreGraphics

// Иконка ClaudeBar — датчик-манометр (шкала загрузки лимита) в цвете Claude
// clay/терракота, со свечением и красной стрелкой-иглой. Стилистика семейства
// Ghostty/TempBar/BreakBar/NetBar: тёмный squircle, сканлайны, глоу, глянец.

let cs = CGColorSpaceCreateDeviceRGB()
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func rad(_ deg: Double) -> CGFloat { CGFloat(deg * .pi / 180) }

func makeIcon(_ S: CGFloat) -> CGImage {
    let w = Int(S), h = Int(S)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // --- тело (squircle) ---
    let p = S * 0.085
    let body = CGRect(x: p, y: p, width: S - 2*p, height: S - 2*p)
    let r = body.width * 0.2237
    let bodyPath = CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.010), blur: S*0.03, color: c(0,0,0,0.4))
    ctx.addPath(bodyPath); ctx.setFillColor(c(0,0,0,1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()

    // фон — тёплый тёмный градиент (глина Claude на угле)
    let bg = CGGradient(colorsSpace: cs, colors: [
        c(0.20, 0.11, 0.08), c(0.06, 0.04, 0.03)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    // тёплое свечение по центру
    let glowC = CGPoint(x: S*0.5, y: S*0.52)
    let glow = CGGradient(colorsSpace: cs, colors: [
        c(0.90, 0.50, 0.35, 0.32), c(0.7, 0.35, 0.2, 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: glowC, startRadius: 0, endCenter: glowC, endRadius: S*0.40, options: [])

    // сканлайны
    ctx.setFillColor(c(1, 1, 1, 0.035))
    var y = p
    let step = S * 0.042
    while y < S - p { ctx.fill(CGRect(x: 0, y: y, width: S, height: max(1, S*0.0035))); y += step }

    // --- датчик: дуга 270° с гэпом внизу, заполнение ~62% ---
    let cx = S*0.5, cy = S*0.5, R = S*0.235, lw = S*0.085
    let a0 = -45.0, a1 = 225.0          // от SE через N до SW (гэп внизу)
    let frac = 0.62
    let aFill = a0 + (a1 - a0) * frac

    ctx.setLineCap(.round)
    // трек (тусклый)
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(c(1, 1, 1, 0.12))
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: rad(a0), endAngle: rad(a1), clockwise: false)
    ctx.strokePath()

    // заполнение (глина, со свечением)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S*0.05, color: c(0.95, 0.52, 0.36, 0.9))
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(c(0.87, 0.47, 0.33))
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: rad(a0), endAngle: rad(aFill), clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // красная стрелка-игла на конце заполнения (фирменная фишка семейства)
    let tipX = cx + R * cos(rad(aFill)), tipY = cy + R * sin(rad(aFill))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S*0.04, color: c(1.0, 0.23, 0.19, 0.9))
    ctx.setLineWidth(lw * 0.42)
    ctx.setStrokeColor(c(1.0, 0.27, 0.22))
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx + R*0.30*cos(rad(aFill)), y: cy + R*0.30*sin(rad(aFill))))
    ctx.addLine(to: CGPoint(x: tipX, y: tipY))
    ctx.strokePath()
    // ступица
    let hub = S*0.055
    ctx.setShadow(offset: .zero, blur: 0, color: c(0,0,0,0))
    ctx.setFillColor(c(0.96, 0.55, 0.40))
    ctx.fillEllipse(in: CGRect(x: cx - hub/2, y: cy - hub/2, width: hub, height: hub))
    ctx.restoreGState()

    // верхний глянец
    let gloss = CGGradient(colorsSpace: cs, colors: [c(1,1,1,0.10), c(1,1,1,0.0)] as CFArray, locations: [0,1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: S - p), end: CGPoint(x: 0, y: S*0.60), options: [])

    ctx.restoreGState() // снять клип тела

    // краевой бевел
    ctx.addPath(bodyPath); ctx.setStrokeColor(c(1,1,1,0.08)); ctx.setLineWidth(max(1, S*0.004)); ctx.strokePath()

    return ctx.makeImage()!
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let map: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, sz) in map {
    let img = makeIcon(sz)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: Int(sz), height: Int(sz))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("iconset готов: \(out)")
