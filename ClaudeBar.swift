import Cocoa
import Foundation

// ============================================================================
//  Claude Bar — лимиты подписки Claude (Pro/Max) в менюбаре Mac.
//  Тянет недокументированный эндпоинт /api/oauth/usage (то же, что /usage
//  внутри Claude Code) OAuth-токеном из Keychain «Claude Code-credentials».
//  Показывает 5-часовое окно сессии и недельный лимит; панель — LED-шкалы
//  со стрелкой (стиль семейства TempBar/BreakBar/NetBar/RadioBar) и таймеры
//  до сброса. Пятый инструмент семейства.
// ============================================================================

// --- Источник данных ---
let USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
let KEYCHAIN_SERVICE = "Claude Code-credentials"
let POLL_SECONDS = 180.0        // безопасный интервал (без User-Agent словишь 429)

// --- Палитра (семейная, адаптивная светлая/тёмная) ---
struct Palette {
    let bg, title, rowText, rowValue, dim, unlit, separator: NSColor
    let green, yellow, orange, red, accent: NSColor
    let glowBlur: CGFloat
    let glowAlpha: CGFloat
}

func palette(dark: Bool) -> Palette {
    if dark {
        return Palette(
            bg: NSColor(white: 0.11, alpha: 1), title: .white,
            rowText: NSColor(white: 0.85, alpha: 1), rowValue: NSColor(white: 0.9, alpha: 1),
            dim: NSColor(white: 0.55, alpha: 1), unlit: NSColor(white: 0.4, alpha: 0.22),
            separator: NSColor(white: 1, alpha: 0.08),
            green: NSColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1),
            yellow: NSColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),
            orange: NSColor(red: 1.00, green: 0.58, blue: 0.05, alpha: 1),
            red: NSColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1),
            accent: NSColor(red: 0.85, green: 0.46, blue: 0.33, alpha: 1),   // Claude clay
            glowBlur: 5, glowAlpha: 0.9)
    } else {
        return Palette(
            bg: NSColor(white: 0.97, alpha: 1), title: NSColor(white: 0.10, alpha: 1),
            rowText: NSColor(white: 0.25, alpha: 1), rowValue: NSColor(white: 0.12, alpha: 1),
            dim: NSColor(white: 0.45, alpha: 1), unlit: NSColor(white: 0, alpha: 0.10),
            separator: NSColor(white: 0, alpha: 0.10),
            green: NSColor(red: 0.16, green: 0.66, blue: 0.28, alpha: 1),
            yellow: NSColor(red: 0.88, green: 0.66, blue: 0.00, alpha: 1),
            orange: NSColor(red: 0.92, green: 0.48, blue: 0.00, alpha: 1),
            red: NSColor(red: 0.86, green: 0.16, blue: 0.13, alpha: 1),
            accent: NSColor(red: 0.78, green: 0.38, blue: 0.24, alpha: 1),   // Claude clay
            glowBlur: 3, glowAlpha: 0.5)
    }
}

// Позиционный цвет LED-сегмента: зелёный → жёлтый → оранжевый → красный.
func segColor(_ p: CGFloat, _ pal: Palette) -> NSColor {
    let stops: [(CGFloat, NSColor)] = [
        (0.00, pal.green), (0.40, pal.green), (0.55, pal.yellow),
        (0.75, pal.orange), (0.92, pal.red), (1.00, pal.red)
    ]
    var lo = stops[0], hi = stops.last!
    for i in 0..<stops.count-1 where p >= stops[i].0 && p <= stops[i+1].0 { lo = stops[i]; hi = stops[i+1]; break }
    let span = hi.0 - lo.0
    let f = span == 0 ? 0 : (p - lo.0) / span
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
    let l = lo.1.usingColorSpace(.deviceRGB)!, h = hi.1.usingColorSpace(.deviceRGB)!
    return NSColor(red: mix(l.redComponent, h.redComponent), green: mix(l.greenComponent, h.greenComponent),
                   blue: mix(l.blueComponent, h.blueComponent), alpha: 1)
}

// Цвет-предупреждение по загрузке лимита: чем ближе к 100%, тем тревожнее.
func warnColor(_ pct: Double, base: NSColor, _ pal: Palette) -> NSColor {
    if pct >= 95 { return pal.red }
    if pct >= 80 { return pal.orange }
    return base
}

func drawText(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ w: NSFont.Weight,
              _ color: NSColor, right: Bool = false, center: Bool = false, mono: Bool = false) {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: w)
                    : NSFont.systemFont(ofSize: size, weight: w)
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let sz = str.size()
    var px = x
    if right { px = x - sz.width } else if center { px = x - sz.width/2 }
    str.draw(at: NSPoint(x: px, y: y))
}

// --- Мини-шкала для менюбара (стиль индикатора батареи macOS) ---
// Насыщенные цвета, читаемые на полупрозрачном тёмном баре: green→red.
func meterColor(_ f: CGFloat) -> NSColor {
    let stops: [(CGFloat, NSColor)] = [
        (0.00, NSColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)),
        (0.50, NSColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)),
        (0.70, NSColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1)),
        (0.85, NSColor(red: 1.00, green: 0.58, blue: 0.05, alpha: 1)),
        (1.00, NSColor(red: 1.00, green: 0.27, blue: 0.22, alpha: 1)),
    ]
    let p = max(0, min(1, f))
    var lo = stops[0], hi = stops.last!
    for i in 0..<stops.count-1 where p >= stops[i].0 && p <= stops[i+1].0 { lo = stops[i]; hi = stops[i+1]; break }
    let span = hi.0 - lo.0
    let t = span == 0 ? 0 : (p - lo.0) / span
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
    let l = lo.1.usingColorSpace(.deviceRGB)!, h = hi.1.usingColorSpace(.deviceRGB)!
    return NSColor(red: mix(l.redComponent, h.redComponent), green: mix(l.greenComponent, h.greenComponent),
                   blue: mix(l.blueComponent, h.blueComponent), alpha: 1)
}

// --- Формы шкалы для менюбара ---
// Цвет зажжённого сегмента (по позиции, green→red) / монохром / пустой.
func litColor(_ pos: CGFloat, mono: Bool, dark: Bool) -> NSColor {
    if mono { return dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.20, alpha: 1) }
    return meterColor(pos)
}
func dimColor(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.20) : NSColor(white: 0, alpha: 0.15) }
func litCount(_ frac: CGFloat, _ n: Int) -> Int {
    let f = max(0, min(1, frac))
    return f <= 0 ? 0 : max(1, Int((f * CGFloat(n)).rounded()))     // >0% → хотя бы один сегмент
}

// Форма 0 (прямые) / 1 (параллелограммы): 10 сегментов, skew задаёт наклон.
func drawSegments(_ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool, skew: CGFloat) {
    let n = 10, gap: CGFloat = 1.4
    let bw = (rect.width - CGFloat(n-1)*gap) / CGFloat(n)
    let lit = litCount(frac, n)
    let y0 = rect.minY, y1 = rect.maxY
    for i in 0..<n {
        let x = rect.minX + CGFloat(i)*(bw+gap)
        let path: NSBezierPath
        if skew <= 0 {
            path = NSBezierPath(roundedRect: NSRect(x: x, y: y0, width: bw, height: rect.height), xRadius: 0.8, yRadius: 0.8)
        } else {
            path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y0))
            path.line(to: NSPoint(x: x + bw - skew, y: y0))
            path.line(to: NSPoint(x: x + bw, y: y1))
            path.line(to: NSPoint(x: x + skew, y: y1))
            path.close()
        }
        (i < lit ? litColor(CGFloat(i)/CGFloat(n-1), mono: mono, dark: dark) : dimColor(dark: dark)).setFill()
        path.fill()
    }
}

// Форма 2 (сигнал): 5 столбиков растущей высоты, как индикатор сети телефона.
func drawSignal(_ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool) {
    let n = 5, gap: CGFloat = 2.0
    let bw = (rect.width - CGFloat(n-1)*gap) / CGFloat(n)
    let lit = litCount(frac, n)
    let minH = rect.height * 0.34
    for i in 0..<n {
        let h = minH + (rect.height - minH) * CGFloat(i) / CGFloat(n-1)
        let x = rect.minX + CGFloat(i)*(bw+gap)
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY, width: bw, height: h), xRadius: 1.2, yRadius: 1.2)
        (i < lit ? litColor(CGFloat(i)/CGFloat(n-1), mono: mono, dark: dark) : dimColor(dark: dark)).setFill()
        path.fill()
    }
}

// Форма 3 (батарея): корпус macOS-батарейки с носиком, заливка по доле (моя версия).
func drawBattery(_ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool) {
    let nubW = max(1.4, rect.height * 0.16)
    let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width - nubW - 1, height: rect.height)
    let stroke = dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.45)
    let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
    outline.lineWidth = 1
    stroke.setStroke(); outline.stroke()
    let nub = NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.5, y: rect.minY + rect.height*0.3, width: nubW, height: rect.height*0.4),
                           xRadius: nubW/2, yRadius: nubW/2)
    stroke.setFill(); nub.fill()
    let inset = body.insetBy(dx: 2, dy: 1.3)
    let f = max(0, min(1, frac))
    let fw = f <= 0 ? 0 : max(inset.height * 0.4, inset.width * f)
    let fill = NSBezierPath(roundedRect: NSRect(x: inset.minX, y: inset.minY, width: fw, height: inset.height), xRadius: 1, yRadius: 1)
    (mono ? (dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.20, alpha: 1)) : meterColor(f)).setFill()
    fill.fill()
}

// Диспетчер формы шкалы.
func drawShape(_ shape: Int, _ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool) {
    switch shape {
    case 0: drawSegments(rect, frac, dark: dark, mono: mono, skew: 0)
    case 2: drawSignal(rect, frac, dark: dark, mono: mono)
    case 3: drawBattery(rect, frac, dark: dark, mono: mono)
    default: drawSegments(rect, frac, dark: dark, mono: mono, skew: min(rect.height * 0.34, 1.9))
    }
}

// ============================================================================
//  Модель данных
// ============================================================================
struct Usage {
    var fiveHourPct: Double? = nil
    var fiveHourReset: Date? = nil
    var sevenDayPct: Double? = nil
    var sevenDayReset: Date? = nil
    var scopedPct: Double? = nil
    var scopedLabel: String? = nil
    var subscription: String? = nil
    var ok: Bool = false
    var error: String? = nil
    var fetchedAt: Date? = nil
}

// --- Разбор дат ISO-8601 (в ответе микросекунды + смещение +00:00) ---
let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()
func parseDate(_ s: String) -> Date? {
    if let d = isoFrac.date(from: s) { return d }
    if let d = isoPlain.date(from: s) { return d }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {   // срезать дробные секунды
        var t = s; t.removeSubrange(r); return isoPlain.date(from: t)
    }
    return nil
}

// «сброс через 2ч 14м» / «через 45м» / «через 3д 4ч»
func untilText(_ d: Date) -> String {
    let secs = d.timeIntervalSinceNow
    if secs <= 0 { return "скоро" }
    let total = Int(secs), h = total / 3600, m = (total % 3600) / 60
    if h >= 24 { return "через \(h/24)д \(h%24)ч" }
    if h > 0 { return "через \(h)ч \(m)м" }
    return "через \(m)м"
}
// «12.07 01:30» — читаемая дата для Германа (ДД.ММ)
let ruTime: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"; f.locale = Locale(identifier: "ru_RU"); return f
}()
func absText(_ d: Date) -> String { ruTime.string(from: d) }
func hmText(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
}

// ============================================================================
//  Keychain + сеть
// ============================================================================
// Токен подписки лежит в Keychain (item «Claude Code-credentials», acct = логин).
// Читаем через /usr/bin/security — headless, без промпта (item уже доступен).
func readCredentials() -> (token: String, sub: String?)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", NSUserName(), "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    return (token, oauth["subscriptionType"] as? String)
}

func fetchUsage(_ completion: @escaping (Usage) -> Void) {
    guard let cred = readCredentials() else {
        completion(Usage(error: "нет токена")); return
    }
    var req = URLRequest(url: URL(string: USAGE_URL)!)
    req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")   // без этого — стойкие 429
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 8

    URLSession.shared.dataTask(with: req) { data, resp, err in
        var u = Usage(); u.subscription = cred.sub
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            u.error = "токен истёк"; DispatchQueue.main.async { completion(u) }; return
        }
        guard let data = data, err == nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            u.error = "нет связи"; DispatchQueue.main.async { completion(u) }; return
        }
        func window(_ key: String) -> (Double, Date?)? {
            guard let d = obj[key] as? [String: Any],
                  let util = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return (util, (d["resets_at"] as? String).flatMap(parseDate))
        }
        if let f = window("five_hour") { u.fiveHourPct = f.0; u.fiveHourReset = f.1 }
        if let s = window("seven_day") { u.sevenDayPct = s.0; u.sevenDayReset = s.1 }
        // недельный лимит по конкретной модели — из массива limits[]
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                if let pct = (l["percent"] as? NSNumber)?.doubleValue {
                    u.scopedPct = pct
                    u.scopedLabel = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                }
            }
        }
        u.ok = (u.fiveHourPct != nil || u.sevenDayPct != nil)
        if !u.ok && u.error == nil { u.error = "нет данных" }
        DispatchQueue.main.async { completion(u) }
    }.resume()
}

// ============================================================================
//  Панель (попап по клику)
// ============================================================================
final class PanelView: NSView {
    var usage = Usage()
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    // LED-шкала с красной стрелкой (фирменный стиль семейства)
    private func ledBar(_ ctx: CGContext, _ bar: CGRect, frac: CGFloat, _ pal: Palette) {
        let n = 40, gap: CGFloat = 2
        let segW = (bar.width - CGFloat(n-1)*gap) / CGFloat(n)
        let f = max(0, min(1, frac))
        let lit = Int((f * CGFloat(n)).rounded())
        for i in 0..<n {
            let x = bar.minX + CGFloat(i)*(segW+gap)
            let seg = CGRect(x: x, y: bar.minY, width: segW, height: bar.height)
            let rr = CGPath(roundedRect: seg, cornerWidth: min(segW/2, 1.5), cornerHeight: min(segW/2, 1.5), transform: nil)
            if i < lit {
                let col = segColor(CGFloat(i)/CGFloat(n-1), pal)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: pal.glowBlur, color: col.withAlphaComponent(pal.glowAlpha).cgColor)
                ctx.addPath(rr); ctx.setFillColor(col.cgColor); ctx.fillPath()
                ctx.restoreGState()
            } else {
                ctx.addPath(rr); ctx.setFillColor(pal.unlit.cgColor); ctx.fillPath()
            }
        }
        let tx = bar.minX + bar.width * f
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4, color: pal.red.withAlphaComponent(0.8).cgColor)
        let needle = CGPath(roundedRect: CGRect(x: tx - 1, y: bar.minY - 5, width: 2, height: bar.height + 10),
                            cornerWidth: 1, cornerHeight: 1, transform: nil)
        ctx.addPath(needle); ctx.setFillColor(pal.red.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }

    // Один блок лимита: подпись, процент, LED-шкала, строка сброса.
    private func drawLimit(_ ctx: CGContext, _ title: String, _ pct: Double?, _ reset: Date?,
                           _ y: CGFloat, _ pal: Palette, _ W: CGFloat, _ pad: CGFloat) {
        let p = pct ?? 0
        drawText(title, pad, y + 4, 12, .medium, pal.rowText)
        drawText("\(Int(p.rounded()))%", W - pad, y, 16, .bold, warnColor(p, base: pal.title, pal), right: true, mono: true)
        ledBar(ctx, CGRect(x: pad, y: y + 24, width: W - 2*pad, height: 14), frac: CGFloat(p / 100), pal)
        if let r = reset {
            drawText("сброс " + untilText(r), pad, y + 44, 9, .medium, pal.dim)
            drawText(absText(r), W - pad, y + 44, 9, .medium, pal.dim, right: true)
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width, pad: CGFloat = 18
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        let pal = palette(dark: dark)

        ctx.setFillColor(pal.bg.cgColor); ctx.fill(bounds)

        drawText("Claude Bar", pad, 12, 13, .bold, pal.title)
        if let sub = usage.subscription {
            drawText(sub.uppercased(), W - pad, 13, 10, .bold, pal.accent, right: true)
        }

        // состояния без данных
        if !usage.ok {
            let msg = usage.error ?? "загрузка…"
            drawText(msg, W/2, 88, 13, .semibold, pal.dim, center: true)
            if usage.error != nil {
                drawText("правый клик → Обновить", W/2, 110, 10, .regular, pal.dim, center: true)
            }
            return
        }

        drawLimit(ctx, "Сессия · 5 часов", usage.fiveHourPct, usage.fiveHourReset, 34, pal, W, pad)
        drawLimit(ctx, "Неделя · все модели", usage.sevenDayPct, usage.sevenDayReset, 96, pal, W, pad)

        ctx.setFillColor(pal.separator.cgColor)
        ctx.fill(CGRect(x: pad, y: 160, width: W - 2*pad, height: 1))

        // подвал: недельный лимит по модели (если есть), иначе время обновления
        if let sp = usage.scopedPct {
            let lbl = usage.scopedLabel.map { "Неделя · \($0)" } ?? "Неделя · модель"
            drawText(lbl, pad, 173, 11, .medium, pal.rowText)
            drawText("\(Int(sp.rounded()))%", W - pad, 172, 11, .semibold, warnColor(sp, base: pal.rowValue, pal), right: true, mono: true)
        } else if let at = usage.fetchedAt {
            drawText("обновлено", pad, 174, 10, .medium, pal.dim)
            drawText(hmText(at), W - pad, 174, 10, .medium, pal.dim, right: true)
        }
    }
}

// ============================================================================
//  Режим превью: ClaudeBar --panel out.png [light|dark]
// ============================================================================
let argv = CommandLine.arguments
if argv.count >= 3 && argv[1] == "--panel" {
    let light = argv.contains("light")
    let v = PanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    var u = Usage()
    u.fiveHourPct = 62; u.fiveHourReset = Date().addingTimeInterval(2*3600 + 14*60)
    u.sevenDayPct = 35; u.sevenDayReset = Date().addingTimeInterval(2*86400 + 4*3600)
    u.scopedPct = 22; u.scopedLabel = "Fable"
    u.subscription = "max"; u.ok = true; u.fetchedAt = Date()
    v.usage = u
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argv[2]))
    }
    print("превью готово: \(argv[2])")
    exit(0)
}

// Превью всех форм шкалы: ClaudeBar --shapes out.png [light|dark]
if argv.count >= 3 && argv[1] == "--shapes" {
    let dark = !argv.contains("light")
    let shapes: [(Int, String)] = [(0, "Прямые"), (1, "Параллелограммы"), (2, "Сигнал"), (3, "Батарея")]
    let fracs: [CGFloat] = [0.28, 0.62, 0.93]
    let rowH: CGFloat = 26, labelCol: CGFloat = 130, cellW: CGFloat = 90, pad: CGFloat = 12
    let W = pad*2 + labelCol + cellW*CGFloat(fracs.count)
    let H = pad*2 + rowH*CGFloat(shapes.count)
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()
    let txt = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.15, alpha: 1)
    for (si, (shape, name)) in shapes.enumerated() {
        let yMid = H - pad - CGFloat(si)*rowH - rowH/2
        let la = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: txt])
        la.draw(at: NSPoint(x: pad, y: yMid - la.size().height/2))
        for (fi, frac) in fracs.enumerated() {
            drawShape(shape, NSRect(x: pad + labelCol + CGFloat(fi)*cellW, y: yMid - 4.5, width: 58, height: 9),
                      frac, dark: dark, mono: false)
        }
    }
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argv[2]))
    }
    print("превью форм готово: \(argv[2])")
    exit(0)
}

// ============================================================================
//  Приложение
// ============================================================================
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let panel = PanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    var timer: Timer?
    var usage = Usage()
    var lastFetch: Date?
    // форма шкалы: 0 прямые · 1 параллелограммы · 2 сигнал · 3 батарея
    var barShape: Int = {
        let d = UserDefaults.standard
        return d.object(forKey: "barShape") == nil ? 1 : d.integer(forKey: "barShape")
    }()
    // какие окна в баре: 0 обе (5ч+7д) · 1 только 5ч · 2 только 7д
    var rowMode = UserDefaults.standard.integer(forKey: "rowMode")
    // цвет шкалы: 0 цветной (green→red) · 1 монохром (белый)
    var colorMode = UserDefaults.standard.integer(forKey: "colorMode")
    // показывать подпись (5ч/7д) и проценты
    var showLabel: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: "showLabel") == nil ? true : d.bool(forKey: "showLabel")
    }()
    var showPercent: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: "showPercent") == nil ? true : d.bool(forKey: "showPercent")
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(click)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.alignment = .center

        let vc = NSViewController()
        vc.view = panel
        popover.contentViewController = vc
        popover.contentSize = panel.frame.size
        popover.behavior = .transient

        render()                         // «Claude…» пока не пришёл первый ответ
        refresh(force: true)             // сразу тянем
        let t = Timer.scheduledTimer(withTimeInterval: POLL_SECONDS, repeats: true) { [weak self] _ in
            self?.refresh(force: true)
        }
        t.tolerance = 10
        timer = t
    }

    func refresh(force: Bool) {
        let now = Date()
        if !force, let last = lastFetch, now.timeIntervalSince(last) < 60 { return }   // троттлинг ручных
        lastFetch = now
        fetchUsage { [weak self] u in
            guard let self = self else { return }
            if u.ok {
                var g = u; g.fetchedAt = Date(); self.usage = g       // новые данные
            } else if !self.usage.ok {
                self.usage = u                                        // ошибка только если данных ещё не было
            }
            self.render()
        }
    }

    // Рисуем сегментные шкалы (5ч/7д) блоками; строки и проценты — по настройкам.
    func renderMenuImage(dark: Bool) -> NSImage {
        var rows: [(String, Double)] = []
        if rowMode != 2 { rows.append(("5ч", usage.fiveHourPct ?? 0)) }
        if rowMode != 1 { rows.append(("7д", usage.sevenDayPct ?? 0)) }
        if rows.isEmpty { rows.append(("5ч", usage.fiveHourPct ?? 0)) }
        let single = rows.count == 1
        let mono = colorMode == 1

        let labelColor = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.15, alpha: 1)
        let labelFont = NSFont.systemFont(ofSize: single ? 9 : 7.5, weight: .semibold)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: single ? 9.5 : 8, weight: .medium)
        let labelW: CGFloat = showLabel ? 15 : 0
        let labelGap: CGFloat = showLabel ? 4 : 0
        let barW: CGFloat = 58
        let numGap: CGFloat = showPercent ? 4 : 0
        let numW: CGFloat = showPercent ? 25 : 0
        let W = ceil(labelW + labelGap + barW + numGap + numW)
        let H: CGFloat = 18
        let barH: CGFloat = single ? 9 : 6
        let yMids: [CGFloat] = single ? [9] : [13, 5]

        let img = NSImage(size: NSSize(width: max(W, 12), height: H))
        img.lockFocus()
        for (idx, r) in rows.enumerated() {
            let (label, pct) = r, yMid = yMids[idx]
            if showLabel {
                let la = NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: labelColor])
                let lsz = la.size()
                la.draw(at: NSPoint(x: labelW - lsz.width, y: yMid - lsz.height/2))
            }
            drawShape(barShape, NSRect(x: labelW + labelGap, y: yMid - barH/2, width: barW, height: barH),
                      CGFloat(pct / 100), dark: dark, mono: mono)
            if showPercent {
                let col: NSColor = mono ? labelColor
                    : (pct >= 95 ? NSColor(red: 1, green: 0.30, blue: 0.25, alpha: 1)
                       : (pct >= 80 ? NSColor(red: 1, green: 0.60, blue: 0.10, alpha: 1) : labelColor))
                let na = NSAttributedString(string: "\(Int(pct.rounded()))%", attributes: [.font: numFont, .foregroundColor: col])
                let nsz = na.size()
                na.draw(at: NSPoint(x: W - nsz.width, y: yMid - nsz.height/2))
            }
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    func render() {
        panel.usage = usage; panel.needsDisplay = true
        guard let btn = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength
        let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua

        // нет данных — текст
        if !usage.ok {
            btn.image = nil
            let t = usage.error != nil ? "Claude ⚠" : "Claude…"
            btn.attributedTitle = NSAttributedString(string: t, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        btn.attributedTitle = NSAttributedString(string: "")
        btn.image = renderMenuImage(dark: dark)
        btn.imagePosition = .imageOnly
    }

    @objc func click() {
        guard let event = NSApp.currentEvent else { return togglePopover() }
        if event.type == .rightMouseUp {
            let menu = NSMenu()

            // форма шкалы
            let shapeMenu = NSMenu()
            for (tag, t) in [(0, "Прямые"), (1, "Параллелограммы"), (2, "Сигнал"), (3, "Батарея")] {
                let it = NSMenuItem(title: t, action: #selector(setShape(_:)), keyEquivalent: "")
                it.target = self; it.tag = tag; it.state = barShape == tag ? .on : .off
                shapeMenu.addItem(it)
            }
            let shapeItem = NSMenuItem(title: "Форма шкалы", action: nil, keyEquivalent: "")
            menu.addItem(shapeItem); menu.setSubmenu(shapeMenu, for: shapeItem)

            // какие окна показывать
            let rowMenu = NSMenu()
            for (tag, t) in [(0, "5ч и 7д"), (1, "Только 5ч"), (2, "Только 7д")] {
                let it = NSMenuItem(title: t, action: #selector(setRowMode(_:)), keyEquivalent: "")
                it.target = self; it.tag = tag; it.state = rowMode == tag ? .on : .off
                rowMenu.addItem(it)
            }
            let rowItem = NSMenuItem(title: "Окна", action: nil, keyEquivalent: "")
            menu.addItem(rowItem); menu.setSubmenu(rowMenu, for: rowItem)

            menu.addItem(NSMenuItem.separator())

            // тумблеры: монохром · подпись · проценты
            let monoItem = NSMenuItem(title: "Монохром", action: #selector(toggleMono), keyEquivalent: "")
            monoItem.target = self; monoItem.state = colorMode == 1 ? .on : .off
            menu.addItem(monoItem)
            let labelItem = NSMenuItem(title: "Подпись 5ч / 7д", action: #selector(toggleLabel), keyEquivalent: "")
            labelItem.target = self; labelItem.state = showLabel ? .on : .off
            menu.addItem(labelItem)
            let pctItem = NSMenuItem(title: "Проценты", action: #selector(togglePercent), keyEquivalent: "")
            pctItem.target = self; pctItem.state = showPercent ? .on : .off
            menu.addItem(pctItem)

            let upd = NSMenuItem(title: "Обновить сейчас", action: #selector(manualRefresh), keyEquivalent: "r")
            upd.target = self; menu.addItem(upd)
            menu.addItem(NSMenuItem.separator())

            let quit = NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)

            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc func setShape(_ sender: NSMenuItem) {
        barShape = sender.tag
        UserDefaults.standard.set(barShape, forKey: "barShape")
        render()
    }
    @objc func setRowMode(_ sender: NSMenuItem) {
        rowMode = sender.tag
        UserDefaults.standard.set(rowMode, forKey: "rowMode")
        render()
    }
    @objc func toggleMono() {
        colorMode = colorMode == 1 ? 0 : 1
        UserDefaults.standard.set(colorMode, forKey: "colorMode")
        render()
    }
    @objc func toggleLabel() {
        showLabel.toggle()
        UserDefaults.standard.set(showLabel, forKey: "showLabel")
        render()
    }
    @objc func togglePercent() {
        showPercent.toggle()
        UserDefaults.standard.set(showPercent, forKey: "showPercent")
        render()
    }
    @objc func manualRefresh() { refresh(force: true) }
    @objc func quitApp() { NSApp.terminate(nil) }

    func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            refresh(force: false)        // подтянуть свежее при открытии (троттлинг 60с)
            render()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
