import Cocoa
import Foundation

// ============================================================================
//  Claude Bar — лимиты подписки Claude (Pro/Max) в менюбаре Mac.
//  Тянет недокументированный эндпоинт /api/oauth/usage (то же, что /usage
//  внутри Claude Code) OAuth-токеном из Keychain «Claude Code-credentials».
//  Показывает 5-часовое окно сессии и недельный лимит; панель — LED-шкалы
//  со стрелкой (стиль семейства TempBar/BreakBar/NetBar/RadioBar) и таймеры
//  до сброса. Шестой инструмент семейства.
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
// Цвет зажжённой части по УРОВНЮ ОСТАТКА (вся горящая часть одним цветом, как заряд
// батареи): много осталось → зелёный, мало → красный. Вызывающий передаёт pos = 1-frac.
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
func drawSegments(_ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool, skew: CGFloat, remaining: Bool) {
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
        // остаток → единый цвет по уровню (1-frac); расход → позиционный градиент (как раньше)
        (i < lit ? litColor(remaining ? 1 - frac : CGFloat(i)/CGFloat(n-1), mono: mono, dark: dark) : dimColor(dark: dark)).setFill()
        path.fill()
    }
}

// Форма 2 (сигнал): 4 узких столбика растущей высоты, компактно — как сеть iPhone.
// Кластер приподнят на yOff, чтобы его оптический центр был по середине строки
// (столбики прижаты к низу → без сдвига «висели» бы низко относительно текста).
func drawSignal(_ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool, remaining: Bool) {
    let n = 4, gap: CGFloat = 1.6
    let bw = (rect.width - CGFloat(n-1)*gap) / CGFloat(n)
    let lit = litCount(frac, n)
    let minH = rect.height * 0.42
    let yOff = rect.height * 0.07
    for i in 0..<n {
        let h = minH + (rect.height - minH) * CGFloat(i) / CGFloat(n-1)
        let x = rect.minX + CGFloat(i)*(bw+gap)
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + yOff, width: bw, height: h),
                                xRadius: min(bw/2, 1.3), yRadius: min(bw/2, 1.3))
        // остаток → единый цвет по уровню (1-frac); расход → позиционный градиент (как раньше)
        (i < lit ? litColor(remaining ? 1 - frac : CGFloat(i)/CGFloat(n-1), mono: mono, dark: dark) : dimColor(dark: dark)).setFill()
        path.fill()
    }
}

// Естественная ширина шкалы под форму: сегменты широкие, сигнал компактный.
func shapeWidth(_ shape: Int, _ h: CGFloat) -> CGFloat {
    switch shape {
    case 2: return max(16, h * 1.5)  // сигнал — узкие высокие столбики; пол 16px, чтобы
                                     // в две строки (h=6) столбики не выродились в 1px
    default: return 58               // сегменты (10 блоков)
    }
}

// Высота шкалы под форму. Сигнал чуть крупнее, сегменты тоньше; в две строки компактно.
func shapeHeight(_ shape: Int, single: Bool) -> CGFloat {
    if !single { return 6 }
    switch shape {
    case 2: return 13     // сигнал (картинка под него поднимается до 20px)
    default: return 9     // сегменты
    }
}

// Диспетчер формы шкалы.
func drawShape(_ shape: Int, _ rect: NSRect, _ frac: CGFloat, dark: Bool, mono: Bool, remaining: Bool = true) {
    switch shape {
    case 0: drawSegments(rect, frac, dark: dark, mono: mono, skew: 0, remaining: remaining)
    case 2: drawSignal(rect, frac, dark: dark, mono: mono, remaining: remaining)
    default: drawSegments(rect, frac, dark: dark, mono: mono, skew: min(rect.height * 0.34, 1.9), remaining: remaining)
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
//  Последние сессии Claude Code
// ============================================================================
// Сканируем ~/.claude/projects/*/*.jsonl (транскрипты сессий), берём 4 самых
// свежих по mtime. Название — из записи {"type":"ai-title"} (то, что Claude Code
// показывает в заголовке вкладки), cwd — из первой записи. Клик по строке в
// панели копирует «cd <cwd> && claude --resume <id>» в буфер обмена.
struct SessionInfo {
    let id: String       // uuid сессии (имя файла без .jsonl)
    let name: String     // ai-title либо имя папки проекта
    let summary: String  // первый запрос пользователя («о чём просил») — для тултипа
    let cwd: String      // рабочая папка сессии ("" если не нашли)
    let created: Date    // когда сессия создана (birth time файла)
    let mtime: Date      // последняя активность (для сортировки)
    var isLive: Bool = false   // транскрипт сейчас открыт живым процессом claude
    var resumeCommand: String {
        cwd.isEmpty ? "claude --resume \(id)" : "cd '\(cwd)' && claude --resume \(id)"
    }
}

// Достать строковое значение JSON-ключа из сырых байт транскрипта (mmap, без
// полного JSON-парса — файлы бывают по 30 МБ). Читаем до неэкранированной «"».
func extractJSONString(_ data: Data, key: String, backwards: Bool) -> String? {
    guard let pat = "\"\(key)\":\"".data(using: .utf8),
          let r = data.range(of: pat, options: backwards ? .backwards : []) else { return nil }
    var bytes: [UInt8] = []
    var i = r.upperBound
    while i < data.endIndex && bytes.count < 400 {              // endIndex, не count — работает и для слайсов
        let b = data[i]
        if b == 0x22 { break }                                  // закрывающая "
        if b == 0x5C && data.index(after: i) < data.endIndex {  // экранирование \x
            let n = data[data.index(after: i)]
            bytes.append(n == 0x6E || n == 0x74 ? 0x20 : n)     // \n,\t → пробел; \" \\ → байт
            i = data.index(i, offsetBy: 2); continue
        }
        bytes.append(b); i = data.index(after: i)
    }
    return String(bytes: bytes, encoding: .utf8)
}

// Содержательные запросы пользователя из сессии — для тултипа «о чём просил».
// Один проход по транскрипту: первые 2 и последние 2 сообщения (gapped = между
// ними были ещё). Служебное пропускаем: <command>, Caveat, сайдчейны, tool_result
// (выводы инструментов в транскрипте тоже помечены type:user).
func userTexts(_ data: Data) -> (first: [String], last: [String], gapped: Bool) {
    var first: [String] = [], last: [String] = [], total = 0
    var start = data.startIndex
    while start < data.endIndex {
        let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
        let line = data[start..<nl]
        start = nl == data.endIndex ? data.endIndex : data.index(after: nl)
        guard line.range(of: Data("\"type\":\"user\"".utf8)) != nil,
              line.range(of: Data("\"isSidechain\":true".utf8)) == nil,
              line.range(of: Data("\"tool_result\"".utf8)) == nil,
              line.range(of: Data("\"toolUseResult\"".utf8)) == nil else { continue }
        var txt = extractJSONString(line, key: "content", backwards: false)
        if txt == nil || txt!.isEmpty || txt!.hasPrefix("{") {
            txt = extractJSONString(line, key: "text", backwards: false)
        }
        guard var t = txt else { continue }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat"),
              !t.hasPrefix("[Request interrupted") else { continue }
        total += 1
        if first.count < 2 { first.append(t) }
        else { last.append(t); if last.count > 2 { last.removeFirst() } }
    }
    return (first, last, total > 4)
}

// Кэш разбора: транскрипт живой сессии меняется постоянно, но старые — нет.
var sessionParseCache: [String: (mtime: Date, info: SessionInfo)] = [:]

func parseSession(_ path: String, created: Date, mtime: Date) -> SessionInfo? {
    if let c = sessionParseCache[path], c.mtime == mtime { return c.info }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
    let id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
    let cwd = extractJSONString(data, key: "cwd", backwards: false) ?? ""
    var name = extractJSONString(data, key: "aiTitle", backwards: true)   // последний ai-title
    if name == nil || name!.isEmpty {
        name = cwd.isEmpty ? "Сессия " + id.prefix(8) : (cwd as NSString).lastPathComponent
    }
    // Тултип: первые 2 + последние 2 сообщения пользователя, «⋯» если между ними пропуск
    let msgs = userTexts(data)
    func clip(_ s: String) -> String { s.count > 110 ? String(s.prefix(110)) + "…" : s }
    var parts = msgs.first.map { "«\(clip($0))»" }
    if msgs.gapped { parts.append("⋯") }
    parts += msgs.last.map { "«\(clip($0))»" }
    let summary = parts.joined(separator: "\n")
    let info = SessionInfo(id: id, name: name!, summary: summary, cwd: cwd, created: created, mtime: mtime)
    sessionParseCache[path] = (mtime, info)
    return info
}

// Сессия «активна», если транскрипт обновлялся только что: живой claude пишет
// в него постоянно. (lsof не годится — файл не держат открытым, append+close.)
let LIVE_WINDOW: TimeInterval = 120

func scanSessions(limit: Int = 4) -> [SessionInfo] {
    let fm = FileManager.default
    let root = NSHomeDirectory() + "/.claude/projects"
    var files: [(path: String, created: Date, mtime: Date)] = []
    for proj in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
        let dir = root + "/" + proj
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
            let p = dir + "/" + f
            guard let a = try? fm.attributesOfItem(atPath: p),
                  let mt = a[.modificationDate] as? Date,
                  let sz = a[.size] as? Int, sz > 2048 else { continue }   // пустые форки-заглушки мимо
            files.append((p, (a[.creationDate] as? Date) ?? mt, mt))
        }
    }
    files.sort { $0.mtime > $1.mtime }
    var out: [SessionInfo] = []
    for f in files.prefix(16) {
        if out.count >= limit { break }
        if var s = parseSession(f.path, created: f.created, mtime: f.mtime) {
            s.isLive = -f.mtime.timeIntervalSinceNow < LIVE_WINDOW
            out.append(s)
        }
    }
    return out
}

// «5 мин назад» / «2 ч назад» / «3 д назад»
func agoText(_ d: Date) -> String {
    let s = max(0, Int(-d.timeIntervalSinceNow))
    if s < 60 { return "только что" }
    if s < 3600 { return "\(s/60) мин назад" }
    if s < 86400 { return "\(s/3600) ч назад" }
    return "\(s/86400) д назад"
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
    var showRemaining = true          // true — остаток лимита, false — расход
    var sessions: [SessionInfo] = [] { didSet { rebuildTooltips() } }  // клик → resume-команда в буфер
    var sessionsOpen = true { didSet { rebuildTooltips() } }          // клик по заголовку сворачивает (стрелка)
    // Строки рисуются, пока идёт анимация сворачивания (клип по высоте даёт «шторку»);
    // прячутся только по её завершении.
    var rowsVisible = true { didSet { rebuildTooltips(); needsDisplay = true } }
    var onToggleSessions: (() -> Void)?
    private var tooltipOwners: [NSString] = []   // addToolTip не ретейнит owner — держим сами
    private var rowRects: [NSRect] = []   // хитбоксы строк сессий (координаты flipped)
    private var headerRect = NSRect.zero  // хитбокс заголовка «СЕССИИ» (клик = свернуть/раскрыть)
    private var hoverIdx: Int? = nil
    private var copiedIdx: Int? = nil     // строка с бейджем «✓ скопировано»
    private var copiedTimer: Timer?
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    // --- мышь: hover-подсветка и клик-копирование ---
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    private func rowIndex(at p: NSPoint) -> Int? { rowRects.firstIndex { $0.contains(p) } }
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let idx = rowIndex(at: p)
        if idx != hoverIdx { hoverIdx = idx; needsDisplay = true }
        if idx != nil || headerRect.contains(p) { NSCursor.pointingHand.set() }
        else { NSCursor.arrow.set() }
    }
    override func mouseExited(with e: NSEvent) {
        if hoverIdx != nil { hoverIdx = nil; needsDisplay = true }
        NSCursor.arrow.set()
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if headerRect.contains(p) { onToggleSessions?(); return }
        guard let idx = rowIndex(at: p), idx < sessions.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sessions[idx].resumeCommand, forType: .string)
        copiedIdx = idx; needsDisplay = true
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.copiedIdx = nil; self?.needsDisplay = true
        }
    }

    // Тултипы: задержал мышь на строке ~1 с — показывается полное название.
    // Ректы совпадают с хитбоксами строк в drawSessions.
    private func rebuildTooltips() {
        removeAllToolTips()
        tooltipOwners = []
        guard sessionsOpen && rowsVisible else { return }
        for (i, s) in sessions.prefix(4).enumerated() {
            let y: CGFloat = 224 + CGFloat(i) * 29
            // полное название + первые/последние сообщения пользователя
            let tip = s.summary.isEmpty ? s.name : "\(s.name)\n\n\(s.summary)"
            let owner = tip as NSString
            tooltipOwners.append(owner)
            addToolTip(NSRect(x: 10, y: y - 5, width: bounds.width - 20, height: 26),
                       owner: owner, userData: nil)
        }
    }

    // Обрезка строки с «…» под максимальную ширину.
    private func fit(_ s: String, _ font: NSFont, _ maxW: CGFloat) -> String {
        let a: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: a).width <= maxW { return s }
        var t = s
        while t.count > 1 && ((t + "…") as NSString).size(withAttributes: a).width > maxW { t.removeLast() }
        return t + "…"
    }

    // LED-шкала с красной стрелкой (фирменный стиль семейства)
    private func ledBar(_ ctx: CGContext, _ bar: CGRect, frac: CGFloat, _ pal: Palette, remaining: Bool) {
        let n = 40, gap: CGFloat = 2
        let segW = (bar.width - CGFloat(n-1)*gap) / CGFloat(n)
        let f = max(0, min(1, frac))
        let lit = Int((f * CGFloat(n)).rounded())
        for i in 0..<n {
            let x = bar.minX + CGFloat(i)*(segW+gap)
            let seg = CGRect(x: x, y: bar.minY, width: segW, height: bar.height)
            let rr = CGPath(roundedRect: seg, cornerWidth: min(segW/2, 1.5), cornerHeight: min(segW/2, 1.5), transform: nil)
            if i < lit {
                let col = segColor(remaining ? 1 - f : CGFloat(i)/CGFloat(n-1), pal)   // остаток: уровень; расход: позиция
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
        let use = pct ?? 0
        let shown = showRemaining ? 100 - use : use   // остаток или расход — по настройке
        drawText(title, pad, y + 4, 12, .medium, pal.rowText)
        drawText("\(Int(shown.rounded()))%", W - pad, y, 16, .bold, warnColor(use, base: pal.title, pal), right: true, mono: true)
        ledBar(ctx, CGRect(x: pad, y: y + 24, width: W - 2*pad, height: 14), frac: CGFloat(shown / 100), pal, remaining: showRemaining)
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
            drawText("\(Int((showRemaining ? 100 - sp : sp).rounded()))%", W - pad, 172, 11, .semibold, warnColor(sp, base: pal.rowValue, pal), right: true, mono: true)
        } else if let at = usage.fetchedAt {
            drawText("обновлено", pad, 174, 10, .medium, pal.dim)
            drawText(hmText(at), W - pad, 174, 10, .medium, pal.dim, right: true)
        }

        drawSessions(ctx, pal, W, pad)
    }

    // --- Секция «Сессии»: последние транскрипты, клик копирует resume-команду.
    //     Клик по заголовку сворачивает/раскрывает секцию. ---
    private func drawSessions(_ ctx: CGContext, _ pal: Palette, _ W: CGFloat, _ pad: CGFloat) {
        rowRects = []
        ctx.setFillColor(pal.separator.cgColor)
        ctx.fill(CGRect(x: pad, y: 196, width: W - 2*pad, height: 1))

        drawText(sessionsOpen ? "СЕССИИ ▾" : "СЕССИИ ▸", pad, 206, 9, .semibold, pal.dim)
        headerRect = NSRect(x: 0, y: 197, width: W, height: 24)
        guard rowsVisible else { return }

        if sessions.isEmpty {
            drawText("сканирую…", W/2, 260, 11, .medium, pal.dim, center: true)
            return
        }

        let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        for (i, s) in sessions.prefix(4).enumerated() {
            let y: CGFloat = 224 + CGFloat(i) * 29
            let row = NSRect(x: pad - 8, y: y - 5, width: W - 2*pad + 16, height: 26)
            rowRects.append(row)

            if hoverIdx == i {   // hover-подсветка
                let rr = CGPath(roundedRect: row, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.addPath(rr)
                ctx.setFillColor((pal.title == NSColor.white
                    ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.06)).cgColor)
                ctx.fillPath()
            }

            // справа: «✓ скопировано» > «● активна» (сессия открыта в терминале) >
            // возраст сессии (когда создана)
            let right = copiedIdx == i ? "✓ скопировано" : (s.isLive ? "● активна" : agoText(s.created))
            let rightCol = copiedIdx == i ? pal.green : (s.isLive ? pal.green : pal.dim)
            let rightW = (right as NSString).size(withAttributes:
                [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium)]).width

            drawText(fit(s.name, nameFont, W - 2*pad - rightW - 10), pad, y, 11.5, .medium, pal.rowText)
            drawText(right, W - pad, y + 2, 9.5, .medium, rightCol, right: true)
        }
    }
}

// ============================================================================
//  Режим превью: ClaudeBar --panel out.png [light|dark] [spent]
// ============================================================================
let argv = CommandLine.arguments
if argv.count >= 3 && argv[1] == "--panel" {
    let light = argv.contains("light")
    let v = PanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 346))
    v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    v.showRemaining = !argv.contains("spent")   // spent → режим расхода для проверки
    var u = Usage()
    u.fiveHourPct = 62; u.fiveHourReset = Date().addingTimeInterval(2*3600 + 14*60)
    u.sevenDayPct = 35; u.sevenDayReset = Date().addingTimeInterval(2*86400 + 4*3600)
    u.scopedPct = 22; u.scopedLabel = "Fable"
    u.subscription = "max"; u.ok = true; u.fetchedAt = Date()
    v.usage = u
    if argv.contains("collapsed") {
        v.sessionsOpen = false
        v.rowsVisible = false
        v.setFrameSize(NSSize(width: 300, height: 226))
    }
    var fake = [
        SessionInfo(id: "9f7c66b0", name: "Откликаться на задания по веб-разработке на Kwork", summary: "смотри у нас есть биржа",
                    cwd: "/Users/lebedev/LebedevClaude", created: Date().addingTimeInterval(-320), mtime: Date()),
        SessionInfo(id: "d3421ead", name: "Проверить видео FailTier и классификацию падений", summary: "проверь клипы",
                    cwd: "/Users/lebedev/LebedevClaude", created: Date().addingTimeInterval(-2900), mtime: Date()),
        SessionInfo(id: "3b179940", name: "Claude Bar — сессии в попапе", summary: "сделай приложение",
                    cwd: "/Users/lebedev", created: Date().addingTimeInterval(-9000), mtime: Date()),
        SessionInfo(id: "884a4e88", name: "Пересборка иконки Ghostty", summary: "иконка терминала",
                    cwd: "/Users/lebedev", created: Date().addingTimeInterval(-190000), mtime: Date()),
    ]
    fake[0].isLive = true
    v.sessions = argv.contains("real") ? scanSessions() : fake
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argv[2]))
    }
    print("превью готово: \(argv[2])")
    exit(0)
}

// Отладка сканера сессий: ClaudeBar --sessions
if argv.count >= 2 && argv[1] == "--sessions" {
    for s in scanSessions() {
        print("[\(s.isLive ? "LIVE" : agoText(s.created))] \(s.name)")
        print("   summary: \(s.summary.prefix(120))")
        print("   cmd: \(s.resumeCommand)")
    }
    exit(0)
}

// Превью всех форм шкалы: ClaudeBar --shapes out.png [light|dark]
if argv.count >= 3 && argv[1] == "--shapes" {
    let dark = !argv.contains("light")
    let shapes: [(Int, String)] = [(0, "Прямые"), (1, "Параллелограммы"), (2, "Сигнал")]
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
        let ph = shapeHeight(shape, single: true)
        for (fi, frac) in fracs.enumerated() {
            drawShape(shape, NSRect(x: pad + labelCol + CGFloat(fi)*cellW, y: yMid - ph/2, width: shapeWidth(shape, ph), height: ph),
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
    let panel = PanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 346))
    var timer: Timer?
    var usage = Usage()
    var lastFetch: Date?
    // форма шкалы: 0 прямые · 1 параллелограммы · 2 сигнал
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
    // семантика значений: true — ОСТАТОК лимита (по умолчанию), false — расход
    var showRemaining: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: "showRemaining") == nil ? true : d.bool(forKey: "showRemaining")
    }()
    // секция «Сессии» в попапе раскрыта
    var sessionsOpen: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: "sessionsOpen") == nil ? true : d.bool(forKey: "sessionsOpen")
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
        popover.behavior = .transient
        panel.onToggleSessions = { [weak self] in
            guard let self = self else { return }
            self.sessionsOpen.toggle()
            UserDefaults.standard.set(self.sessionsOpen, forKey: "sessionsOpen")
            self.applySessionsState(animated: true)
        }
        applySessionsState()

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

    // Рисуем шкалы (5ч/7д) выбранной формой; строки и проценты — по настройкам.
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
        // под крупный сигнал в одну строку поднимаем картинку до 20px
        let H: CGFloat = (single && barShape == 2) ? 20 : 18
        let barH: CGFloat = shapeHeight(barShape, single: single)
        let barW: CGFloat = shapeWidth(barShape, barH)
        let numGap: CGFloat = showPercent ? 4 : 0
        let numW: CGFloat = showPercent ? 25 : 0
        let W = ceil(labelW + labelGap + barW + numGap + numW)
        let yMids: [CGFloat] = single ? [9] : [13, 5]

        let img = NSImage(size: NSSize(width: max(W, 12), height: H))
        img.lockFocus()
        for (idx, r) in rows.enumerated() {
            let (label, pct) = r, yMid = yMids[idx]
            // текст центрируем по cap-height (а не по рамке — иначе кажется выше).
            // Сам сигнал приподнят внутри drawSignal, так что центр всех форм = yMid.
            let tMid = yMid
            if showLabel {
                let la = NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: labelColor])
                la.draw(at: NSPoint(x: labelW - la.size().width, y: tMid + labelFont.descender - labelFont.capHeight/2))
            }
            let shownPct = showRemaining ? 100 - pct : pct   // остаток или расход — по настройке
            drawShape(barShape, NSRect(x: labelW + labelGap, y: yMid - barH/2, width: barW, height: barH),
                      CGFloat(shownPct / 100), dark: dark, mono: mono, remaining: showRemaining)
            if showPercent {
                // цвет-тревога считается по РАСХОДУ (pct) в обоих режимах
                let col: NSColor = mono ? labelColor
                    : (pct >= 95 ? NSColor(red: 1, green: 0.30, blue: 0.25, alpha: 1)
                       : (pct >= 80 ? NSColor(red: 1, green: 0.60, blue: 0.10, alpha: 1) : labelColor))
                let na = NSAttributedString(string: "\(Int(shownPct.rounded()))%", attributes: [.font: numFont, .foregroundColor: col])
                na.draw(at: NSPoint(x: W - na.size().width, y: tMid + numFont.descender - numFont.capHeight/2))
            }
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    func render() {
        panel.usage = usage; panel.showRemaining = showRemaining; panel.needsDisplay = true
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
            for (tag, t) in [(0, "Прямые"), (1, "Параллелограммы"), (2, "Сигнал")] {
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

            // тумблеры: остаток/расход · монохром · подпись · проценты
            let remItem = NSMenuItem(title: "Показывать остаток", action: #selector(toggleRemaining), keyEquivalent: "")
            remItem.target = self; remItem.state = showRemaining ? .on : .off
            menu.addItem(remItem)
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
    @objc func toggleRemaining() {
        showRemaining.toggle()
        UserDefaults.standard.set(showRemaining, forKey: "showRemaining")
        render()
    }
    @objc func manualRefresh() { refresh(force: true) }
    @objc func quitApp() { NSApp.terminate(nil) }

    func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            refresh(force: false)        // подтянуть свежее при открытии (троттлинг 60с)
            refreshSessions()            // и список последних сессий
            render()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    // Высота панели: секция сессий раскрыта → полная, свёрнута → только шкалы+заголовок.
    var sessionsAnimTimer: Timer?
    func applySessionsState(animated: Bool = false) {
        let h: CGFloat = sessionsOpen ? 346 : 226
        panel.sessionsOpen = sessionsOpen                 // стрелка ▾/▸ — сразу
        if sessionsOpen { panel.rowsVisible = true }      // при раскрытии строки видны с первого кадра
        if animated && popover.isShown {
            animatePopoverHeight(to: h) { [weak self] in
                guard let self = self else { return }
                if !self.sessionsOpen { self.panel.rowsVisible = false }
            }
        } else {
            sessionsAnimTimer?.invalidate()
            popover.contentSize = NSSize(width: 300, height: h)
            panel.setFrameSize(NSSize(width: 300, height: h))
            panel.rowsVisible = sessionsOpen
        }
        panel.needsDisplay = true
    }

    // Плавное изменение высоты попапа (~0.22 с, easeOutCubic). Попап сам ресайзит
    // panel под contentSize, строки клипаются по высоте — получается «шторка».
    func animatePopoverHeight(to h: CGFloat, done: @escaping () -> Void) {
        sessionsAnimTimer?.invalidate()
        let start = popover.contentSize.height
        guard abs(start - h) > 1 else { popover.contentSize = NSSize(width: 300, height: h); done(); return }
        let t0 = Date(), dur = 0.22
        sessionsAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            var f = CGFloat(Date().timeIntervalSince(t0) / dur)
            if f >= 1 { f = 1; tm.invalidate() }
            let e = 1 - pow(1 - f, 3)
            self.popover.contentSize = NSSize(width: 300, height: start + (h - start) * e)
            if f >= 1 { done() }
        }
    }

    // Скан сессий — в фоне (mmap+поиск по 4 файлам, но не на главном потоке).
    func refreshSessions() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s = scanSessions()
            DispatchQueue.main.async {
                self?.panel.sessions = s
                self?.panel.needsDisplay = true
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")   // тултип через 0.3 с, а не ~1.5 с
let delegate = AppDelegate()
app.delegate = delegate
app.run()
