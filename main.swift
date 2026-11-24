// ServerMonitor — macOS 菜单栏服务器监控小工具
// 读取 ~/.ssh/config，通过 SSH 并行采集所有机器的实时 CPU / 内存，弹出面板一览显示
// 构建：./build.sh

import AppKit
import SwiftUI

// MARK: - 配置

struct ServerConfig: Codable {
    var interval: Double = 3.0   // 采集间隔（秒）
    var columns: Int? = nil      // 面板列数；null/0 = 按机器数自动（≤6:1列 ≤14:2列 >14:3列）
    var ignore: [String] = []    // 不监控的机器：~/.ssh/config 里的别名或 HostName

    init(interval: Double = 3.0, columns: Int? = nil, ignore: [String] = []) {
        self.interval = interval
        self.columns = columns
        self.ignore = ignore
    }

    private enum CodingKeys: String, CodingKey { case interval, columns, ignore }

    // 逐字段 decodeIfPresent：缺字段的旧版 config.json 也能读
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 3.0
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
        ignore = try c.decodeIfPresent([String].self, forKey: .ignore) ?? []
    }
}

enum ConfigLoader {
    /// 按优先级查找 config.json：可执行文件同目录 → Bundle Resources → 源码目录
    static func find() -> URL? {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates: [URL?] = [
            exeDir.appendingPathComponent("config.json"),
            Bundle.main.resourceURL?.appendingPathComponent("config.json"),
            // .../build/ServerMonitor.app/Contents/MacOS → 上溯 4 级回到源码目录
            exeDir.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("config.json"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    static func load() -> ServerConfig? {
        guard let url = find(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    static func path() -> String? { find()?.path }
}

// MARK: - ~/.ssh/config 解析

struct SSHHostEntry: Identifiable, Equatable {
    var id: String { alias }
    let alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var displayName: String { hostName.map { "\(alias) · \($0)" } ?? alias }

    /// 实际连接地址：没写 HostName 时别名本身就是地址；%h 代入别名
    var address: String {
        (hostName ?? alias).replacingOccurrences(of: "%h", with: alias)
    }
}

enum SSHConfigParser {
    /// 读取 ~/.ssh/config（连同其中的 Include），返回去重、排除后的主机
    static func load(ignoring ignored: [String] = []) -> [SSHHostEntry] {
        let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        let url = sshDir.appendingPathComponent("config")
        var state = State(visited: [])
        ingest(fileURL: url, sshDir: sshDir, into: &state)
        return finalize(state.hosts, ignoring: ignored)
    }

    /// 解析一段 ssh config 文本；Include 里的相对路径按 sshDir 解析
    static func parse(_ text: String, sshDir: URL, ignoring ignored: [String] = []) -> [SSHHostEntry] {
        var state = State(visited: [])
        ingest(text: text, sshDir: sshDir, into: &state)
        return finalize(state.hosts, ignoring: ignored)
    }

    private struct State {
        var hosts: [SSHHostEntry] = []
        var blockStart: Int?        // 当前 Host 段在 hosts 里的起始下标；nil = 不在 Host 段内
        var visited: Set<String>    // 已读过的文件，防止 Include 成环
    }

    /// 文件的规范路径，用来判断「这个文件读过了」
    private static func fileKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func ingest(fileURL: URL, sshDir: URL, into state: inout State) {
        let path = fileKey(fileURL)
        // 读过的不再读，总数设上限：Include 之间互相引用时不会无限递归
        guard !state.visited.contains(path), state.visited.count < 64,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        state.visited.insert(path)
        ingest(text: text, sshDir: sshDir, into: &state)
    }

    /// 只取每台机器连接用得到的几项：Host / HostName / User / Port。Include 的文件按原位内联处理。
    private static func ingest(text: String, sshDir: URL, into state: inout State) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (key, value) = directive(rawLine) else { continue }
            switch key {
            case "host":
                state.blockStart = nil
                // 一行 Host 可以写多个名字，它们共用本段的选项。
                // 带 * / ? 的是模式，以 ! 开头的是排除项（如「Host * !foo」），都不对应具体机器
                let aliases = words(in: value).filter {
                    !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
                }
                if !aliases.isEmpty {
                    state.blockStart = state.hosts.count
                    state.hosts += aliases.map { SSHHostEntry(alias: $0, hostName: nil, user: nil, port: nil) }
                }
            case "match":
                // Match 段的选项带条件，没法静态归属到某台机器，忽略到下一个 Host 为止
                state.blockStart = nil
            case "include":
                for path in includePaths(value, sshDir: sshDir) {
                    ingest(fileURL: URL(fileURLWithPath: path), sshDir: sshDir, into: &state)
                }
            case "hostname", "user", "port":
                guard let start = state.blockStart else { continue }
                let option = unquote(value)
                for i in start..<state.hosts.count {
                    switch key {
                    case "hostname": state.hosts[i].hostName = option.isEmpty ? nil : option
                    case "user": state.hosts[i].user = option.isEmpty ? nil : option
                    default: state.hosts[i].port = Int(option)
                    }
                }
            default:
                break
            }
        }
    }

    /// 把一行拆成「关键字, 值」。关键字与值之间用空白或 = 分隔；只有整行注释。
    private static func directive(_ line: Substring) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
        guard let key = parts.first, !key.isEmpty else { return nil }
        let value = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: " \t=")) : ""
        return (key.lowercased(), value)
    }

    private static func words(in value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { unquote(String($0)) }
    }

    /// 去掉值两侧成对的引号
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Include 的路径：展开 ~，相对路径按 ssh 的规则相对于 ~/.ssh，支持 * 和 ? 通配
    private static func includePaths(_ raw: String, sshDir: URL) -> [String] {
        let value = unquote(raw)
        let pattern: String
        if value.hasPrefix("~/") {
            pattern = NSHomeDirectory() + String(value.dropFirst())
        } else if value.hasPrefix("/") {
            pattern = value
        } else {
            pattern = sshDir.appendingPathComponent(value).path
        }
        guard pattern.contains("*") || pattern.contains("?") else { return [pattern] }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0] }
            .map { String(cString: $0) }
    }

    /// 排除 + 去重，都按「机器」算（实际地址 + 端口相同的条目属于同一台）。
    /// 排除名单里写了这台机器的任何一个别名或地址，它的全部条目都不监控；
    /// 同一台有多个条目时优先留命名别名，弃用裸 IP 条目。
    private static func finalize(_ hosts: [SSHHostEntry], ignoring ignored: [String]) -> [SSHHostEntry] {
        let skipped = Set(ignored.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var machines: [String: [SSHHostEntry]] = [:]
        var order: [String] = []
        for h in hosts {
            let key = "\(h.address.lowercased()):\(h.port ?? 22)"
            if machines[key] == nil { order.append(key) }
            machines[key, default: []].append(h)
        }
        return order.compactMap { key in
            guard let entries = machines[key],
                  !entries.contains(where: {
                      skipped.contains($0.alias.lowercased()) || skipped.contains($0.address.lowercased())
                  }) else { return nil }
            return entries.first { !isBareIP($0.alias) } ?? entries[0]
        }
    }

    private static func isBareIP(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }
}

// MARK: - 采样数据

struct Sample {
    var cpuPercent: Double     // 0-100
    var memUsedGB: Double
    var memTotalGB: Double
    var memPercent: Double     // 0-100
    var load1: Double
    var timestamp: Date
}

// MARK: - SSH 采集器

enum Collector {
    /// 远程命令：读得到 /proc 就输出 cpu ×2 / MemTotal / MemAvailable / loadavg，
    /// 否则以 42 退出并报出系统名（非 Linux 主机）。
    static let remoteCommand =
        #"test -r /proc/stat || { echo __NOT_LINUX__ "$(uname -s 2>/dev/null)"; exit 42; }; "#
        + "head -1 /proc/stat; sleep 1; head -1 /proc/stat; "
        + "grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; cat /proc/loadavg"

    /// 一次 SSH 调用完成 CPU 两次采样 + 内存 + 负载。
    /// 直接用 ~/.ssh/config 里的别名连接，User/Port/密钥/主机指纹校验等全部沿用 ssh 自己的设置。
    /// 失败时抛出 HostIssue。
    static func sample(_ host: SSHHostEntry) throws -> Sample {
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            host.alias,
            remoteCommand,
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // 0 = 远程命令正常跑完。其余退出码、或出现 __NOT_LINUX__ 哨兵，都归到失败原因里
        let status = process.terminationStatus
        guard status == 0, !out.contains("__NOT_LINUX__") else {
            throw classify(status: status, stderr: err, output: out)
        }

        func cpuJiffies(_ line: String) -> (busy: Double, total: Double)? {
            let parts = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard parts.count >= 5 else { return nil }
            let idle = parts[3] + (parts.count > 4 ? parts[4] : 0) // idle + iowait
            let total = parts.reduce(0, +)
            return (total - idle, total)
        }

        func kb(_ line: String) -> Double? {
            line.split(separator: " ").compactMap { Double($0) }.first
        }

        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 5,
              let c1 = cpuJiffies(lines[0]), let c2 = cpuJiffies(lines[1]),
              let memTotal = kb(lines[2]), let memAvail = kb(lines[3]) else {
            throw HostIssue.unsupported("远程输出不是 Linux /proc 的格式，只支持 Linux")
        }
        let cpu = c2.total > c1.total ? (c2.busy - c1.busy) / (c2.total - c1.total) * 100 : 0
        let used = memTotal - memAvail
        let load1 = Double(lines[4].split(separator: " ").first ?? "") ?? 0

        return Sample(
            cpuPercent: min(max(cpu, 0), 100),
            memUsedGB: used / 1024 / 1024,
            memTotalGB: memTotal / 1024 / 1024,
            memPercent: memTotal > 0 ? used / memTotal * 100 : 0,
            load1: load1,
            timestamp: Date()
        )
    }

    /// 把 ssh 的退出码和 stderr 归成失败原因。
    /// 255 是 ssh 连接层（解析、连接、认证、主机指纹）失败的专用退出码；42 是远程命令报的「不是 Linux」。
    static func classify(status: Int32, stderr: String, output: String) -> HostIssue {
        let outputLines = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        if let line = outputLines.first(where: { $0.hasPrefix("__NOT_LINUX__") }) {
            let system = line.dropFirst("__NOT_LINUX__".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unsupported(system.isEmpty
                ? "该主机读不到 /proc，只支持 Linux"
                : "\(system) 主机读不到 /proc，只支持 Linux")
        }
        let reason = firstLine(of: stderr)
        let lower = stderr.lowercased()
        if status == 255 {
            if lower.contains("host key verification failed") || lower.contains("host identification has changed") {
                return .untrusted
            }
            if reason.isEmpty { return .unreachable("ssh 连接失败（退出码 255）") }
            if lower.contains("permission denied") {
                return .unreachable("\(reason)（本工具只支持密钥免密登录）")
            }
            return .unreachable(reason)
        }
        if status == 42 {
            return .unsupported(reason.isEmpty ? "该主机读不到 /proc，只支持 Linux" : reason)
        }
        return .unsupported(reason.isEmpty ? "远程输出无法识别（退出码 \(status)），只支持 Linux" : reason)
    }

    /// stderr 里第一行非空内容，去掉 ssh: 前缀，限长。
    /// 按行切要用 isNewline：Swift 把 \r\n 当成一个字符，分别和 "\n"、"\r" 比较是切不开的。
    private static func firstLine(of text: String) -> String {
        let line = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first ?? ""
        let stripped = line.hasPrefix("ssh: ") ? String(line.dropFirst(5)) : line
        return String(stripped.prefix(200))
    }
}

// MARK: - 主机状态

/// 一台机器采不到数据的原因
enum HostIssue: Error {
    case untrusted                 // 主机指纹未信任（或已变化）：需要用户先手动 ssh 一次
    case unreachable(String)       // 连不上或认证失败
    case unsupported(String)       // 连上了，但读不到 /proc：非 Linux 主机或受限环境

    /// 连不上和未信任需要提醒；不支持的系统只作说明，不算故障
    var isAlarm: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var title: String {
        switch self {
        case .untrusted: return "未信任主机"
        case .unreachable: return "连接失败"
        case .unsupported: return "不支持的系统"
        }
    }

    var detail: String {
        switch self {
        case .untrusted: return "主机指纹未信任或已变化，需要先在终端 ssh 一次"
        case .unreachable(let reason): return reason
        case .unsupported(let reason): return reason
        }
    }
}

/// 一台机器当前的样子，由「最近一次成功的采样」和「最近一次失败的原因」推出。
/// 两者同时有值，说明机器掉线了，手里的采样是旧数据。
struct HostState {
    let host: SSHHostEntry
    let sample: Sample?
    let issue: HostIssue?

    init(host: SSHHostEntry, sample: Sample?, issue: HostIssue?) {
        self.host = host
        self.sample = sample
        self.issue = issue
    }

    /// 最近一次采集成功，手里的采样是有效的
    var isOnline: Bool { issue == nil && sample != nil }
    /// 掉线了，但还留着掉线前的采样
    var isStale: Bool { issue != nil && sample != nil }
    var isAlarm: Bool { issue?.isAlarm ?? false }
    var isUnsupported: Bool {
        if case .unsupported = issue { return true }
        return false
    }

    /// 卡片右上角的状态标签；在线时为 nil（那时显示负载）
    var statusLabel: String? {
        guard let issue else { return nil }
        if isStale, case .unreachable = issue { return "已离线" }
        switch issue {
        case .untrusted: return "未信任"
        case .unreachable: return "连接失败"
        case .unsupported: return "不支持"
        }
    }
}

extension Array where Element == HostState {
    var onlineCount: Int { filter(\.isOnline).count }
    var alarmCount: Int { filter(\.isAlarm).count }
    var unsupportedCount: Int { filter(\.isUnsupported).count }

    /// 在线机器里最近一次成功采样的时间
    var lastUpdate: Date? {
        compactMap { $0.isOnline ? $0.sample?.timestamp : nil }.max()
    }
}

// MARK: - 状态存储

@MainActor
final class MonitorStore: ObservableObject {
    @Published var hosts: [SSHHostEntry] = []
    @Published var samples: [String: Sample] = [:]    // alias -> 最近一次成功的采样（掉线后留着当旧数据）
    @Published var issues: [String: HostIssue] = [:]  // alias -> 最近一次采集失败的原因；成功后清除
    @Published var config = ServerConfig()

    private var timer: Timer?
    private var inFlight: Set<String> = []
    private var logged: [String: String] = [:]        // 每台机器上次写日志时的状态，变了才再写

    var states: [HostState] { hosts.map(state(for:)) }
    var lastUpdate: Date? { states.lastUpdate }
    var onlineCount: Int { states.onlineCount }
    var alarmCount: Int { states.alarmCount }
    var unsupportedCount: Int { states.unsupportedCount }
    var configured: Bool { !hosts.isEmpty }

    func state(for host: SSHHostEntry) -> HostState {
        HostState(host: host, sample: samples[host.alias], issue: issues[host.alias])
    }

    func start() {
        reloadConfig()
    }

    func reloadConfig() {
        if let cfg = ConfigLoader.load() { config = cfg }
        hosts = SSHConfigParser.load(ignoring: config.ignore)
        // 已经不在监控列表里的机器，不再留着它的数据
        let alive = Set(hosts.map(\.alias))
        samples = samples.filter { alive.contains($0.key) }
        issues = issues.filter { alive.contains($0.key) }
        logged = logged.filter { alive.contains($0.key) }
        NSLog("ServerMonitor: 监控 %d 台 → %@", hosts.count, hosts.map(\.alias).joined(separator: ", "))
        scheduleTimer()
        tick()   // 重载后立刻采一次，不用等下一个周期
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(config.interval, 2)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 对所有机器并行采样；上一轮还没返回的机器这一轮跳过
    private func tick() {
        for host in hosts where !inFlight.contains(host.alias) {
            inFlight.insert(host.alias)
            Task.detached { [weak self] in
                let result = Result { try Collector.sample(host) }
                await MainActor.run { [weak self] in
                    self?.apply(result, for: host.alias)
                }
            }
        }
    }

    private func apply(_ result: Result<Sample, Error>, for alias: String) {
        inFlight.remove(alias)
        // 采样的过程中机器可能已被重载配置移除
        guard let host = hosts.first(where: { $0.alias == alias }) else { return }
        switch result {
        case .success(let s):
            samples[alias] = s
            issues[alias] = nil
        case .failure(let error):
            issues[alias] = (error as? HostIssue) ?? .unreachable(error.localizedDescription)
        }

        let state = state(for: host)
        let phase = state.isOnline
            ? "在线"
            : "\(state.issue?.title ?? "")：\(state.issue?.detail ?? "")"
        if logged[alias] != phase {
            logged[alias] = phase
            NSLog("ServerMonitor: %@ → %@", alias, phase)
        }
    }

    /// 菜单栏展示：在线机器里 CPU 最高的那台（离线机器的旧数据不参与）
    var hottest: (host: SSHHostEntry, sample: Sample)? {
        hosts.compactMap { h -> (SSHHostEntry, Sample)? in
            guard state(for: h).isOnline, let s = samples[h.alias] else { return nil }
            return (h, s)
        }
        .max { $0.1.cpuPercent < $1.1.cpuPercent }
    }

    /// 面板列数：手动配置优先，否则按机器数自动
    var columns: Int {
        if let c = config.columns, c > 0 { return min(c, 4) }
        let n = hosts.count
        if n <= 6 { return 1 }
        if n <= 14 { return 2 }
        return 3
    }

    /// 面板宽度随列数变化
    var panelWidth: CGFloat {
        switch columns {
        case 1: return 340
        case 2: return 560
        default: return 780
        }
    }
}

// MARK: - 面板 UI

func usageColor(_ v: Double) -> Color {
    v >= 90 ? Color(hex: 0xFF5A5A) : v >= 70 ? Color(hex: 0xFFA94D)
        : v >= 50 ? Color(hex: 0xFFD43B) : Color(hex: 0x3DDC84)
}

func nsUsageColor(_ v: Double) -> NSColor {
    v >= 90 ? .systemRed : v >= 70 ? .systemOrange : .labelColor
}

// MARK: - 主题

enum Theme {
    static let bgTop = Color(hex: 0x1E2028)
    static let bgBottom = Color(hex: 0x121317)
    static let card = Color(hex: 0x272932)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.34)
    static let accent = Color(hex: 0x7AB8FF)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 仪表与动效

/// 带光晕的环形仪表
struct MiniRing: View {
    let percent: Double
    var size: CGFloat = 38
    var muted = false   // true = 灰显，用于掉线后留下的旧数据

    var body: some View {
        let color = muted ? Theme.textSecondary : usageColor(percent)
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(percent / 100, 0.03))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: muted ? .clear : color.opacity(0.6), radius: 3)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: percent)
            Text(String(format: "%.0f", percent))
                .font(.system(size: size * 0.27, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
    }
}

/// 呼吸灯（面板标题左侧，表示正在实时采集）
struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulsing ? 1.5 : 0.7)
                .opacity(pulsing ? 0 : 0.9)
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

// MARK: - 机器卡片

struct HostCard: View {
    let state: HostState

    private var host: SSHHostEntry { state.host }

    /// 卡片主色：在线时按最差指标定级；离线红、未信任橙、不支持的系统灰
    private var accent: Color {
        guard let issue = state.issue else {
            if let s = state.sample { return usageColor(max(s.cpuPercent, s.memPercent)) }
            return Theme.textTertiary
        }
        switch issue {
        case .unreachable: return usageColor(95)
        case .untrusted: return usageColor(80)
        case .unsupported: return Theme.textSecondary
        }
    }

    /// 采集失败的原因；未信任时直接给出该执行的那条命令
    private var issueText: String {
        guard let issue = state.issue else { return "" }
        if case .untrusted = issue {
            return "先在终端执行 ssh \(host.alias)，确认并信任主机指纹"
        }
        return issue.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 标题行
            HStack(alignment: .center, spacing: 6) {
                Circle().fill(accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: state.isOnline ? accent.opacity(0.7) : .clear, radius: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.alias)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(host.address)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if state.sample == nil && state.issue == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.4))
                }
                if state.isOnline, let s = state.sample {
                    Text(String(format: "负载 %.2f", s.load1))
                        .font(.system(size: 9, design: .monospaced).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                if let label = state.statusLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(state.isAlarm ? accent : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.16)))
                }
            }
            .help(state.issue.map { "\(host.alias)：\($0.title)。\(issueText)" } ?? host.displayName)

            // 指标：在线和「掉线后留下的旧数据」都显示，旧的灰显
            if let s = state.sample {
                metrics(s, muted: state.isStale)
            }

            // 采集失败的原因；还没采到过数据的机器只有这一段
            if state.issue != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let t = state.sample?.timestamp {
                        Text("数据停留在 \(timeFormatter.string(from: t))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(accent)
                    }
                    Text(issueText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(state.isAlarm ? Theme.textSecondary : Theme.textTertiary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.sample == nil {
                Text("连接中…")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(colors: [Theme.card, Theme.card.opacity(0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private func metrics(_ s: Sample, muted: Bool) -> some View {
        // 掉线后的旧数据不再按占用率着色
        func tint(_ value: Double) -> Color { muted ? Theme.textSecondary : usageColor(value) }
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                MiniRing(percent: s.cpuPercent, muted: muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                    Text(String(format: "%.1f%%", s.cpuPercent))
                        .font(.system(size: 11, weight: .semibold,
                                      design: .rounded).monospacedDigit())
                        .foregroundColor(tint(s.cpuPercent))
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1, height: 32)
            HStack(spacing: 8) {
                MiniRing(percent: s.memPercent, muted: muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("内存")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                    Text(String(format: "%.1f/%.1fG", s.memUsedGB, s.memTotalGB))
                        .font(.system(size: 10, weight: .medium,
                                      design: .monospaced).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 面板

struct PanelView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 11) {
                // 头部
                HStack(spacing: 8) {
                    PulsingDot(color: store.hosts.isEmpty ? Theme.textTertiary
                                : store.alarmCount == 0 ? Color(hex: 0x3DDC84)
                                : Color(hex: 0xFFA94D))
                    Text("服务器监控")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(store.onlineCount)/\(store.hosts.count) 台在线")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(Theme.textSecondary)
                        if let t = store.lastUpdate {
                            Text("更新于 \(timeFormatter.string(from: t))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        } else if !store.hosts.isEmpty {
                            Text("暂无有效数据")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                if store.hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("未发现可监控的服务器")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text("本工具从 ~/.ssh/config 读取主机列表。请确认该文件存在，"
                            + "且包含非通配符的 Host 条目，然后在下方点「重载配置」。")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.vertical, 10)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                           count: store.columns),
                            spacing: 8
                        ) {
                            ForEach(store.hosts) { h in
                                HostCard(state: store.state(for: h))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxHeight: 460)
                }

                // 底部
                HStack(spacing: 6) {
                    Text("每 \(Int(store.config.interval)) 秒刷新")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                    if store.alarmCount > 0 {
                        Text("· \(store.alarmCount) 台异常")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(hex: 0xFFA94D))
                    }
                    if store.unsupportedCount > 0 {
                        Text("· \(store.unsupportedCount) 台不支持")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("打开配置") { AppDelegate.shared.openConfig() }
                    Button("重载配置") { AppDelegate.shared.reloadConfig() }
                        .keyboardShortcut("r")
                    Button("退出") { NSApp.terminate(nil) }
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .tint(Theme.accent)
            }
            .padding(14)
        }
        .preferredColorScheme(.dark)
        .frame(width: store.panelWidth)
    }
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

// MARK: - 菜单栏应用

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    let store = MonitorStore()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover(_:))

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .vibrantDark)   // 深色毛玻璃质感
        popover.contentViewController = NSHostingController(rootView: PanelView(store: store))

        store.start()
        renderMenuBar()

        // 面板外点击自动关闭
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        // 数据变化时刷新菜单栏标题；同时同步弹窗尺寸（列数可能随机器数变化）
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderMenuBar()
                if let self, !self.popover.isShown {
                    self.popover.contentSize = NSSize(width: self.store.panelWidth, height: 480)
                }
            }
        }
    }

    private func renderMenuBar() {
        guard let button = statusItem.button else { return }
        if !store.configured {
            button.title = "🖥 ⚙︎"
            button.toolTip = nil
            return
        }
        // 只有连不上、未信任算异常；不支持的系统不在这里报警
        let alarms = store.states.filter(\.isAlarm)
        let alarmTip = alarms
            .map { "⚠︎ \($0.host.alias)：\($0.issue?.detail ?? "")" }
            .joined(separator: "\n")
        if let (host, s) = store.hottest {
            let cpu = String(format: "%.0f%%", s.cpuPercent)
            let mem = String(format: "%.0f%%", s.memPercent)
            let str = NSMutableAttributedString(string: "🖥 ")
            str.append(NSAttributedString(string: cpu,
                                          attributes: [.foregroundColor: nsUsageColor(s.cpuPercent)]))
            str.append(NSAttributedString(string: " "))
            str.append(NSAttributedString(string: mem,
                                          attributes: [.foregroundColor: nsUsageColor(s.memPercent)]))
            if !alarms.isEmpty {
                str.append(NSAttributedString(string: " ⚠︎",
                                              attributes: [.foregroundColor: NSColor.systemOrange]))
            }
            button.attributedTitle = str
            // 悬停提示：最热机器 + 所有异常
            var tip = "CPU 最高：\(host.alias) \(cpu) · 内存 \(mem)"
            if !alarmTip.isEmpty { tip += "\n" + alarmTip }
            button.toolTip = tip
        } else if alarms.isEmpty {
            button.title = "🖥 …"
            button.toolTip = nil
        } else {
            button.title = "🖥 ⚠︎"
            button.toolTip = alarmTip
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    private func showPopover() {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    func openConfig() {
        if let path = ConfigLoader.path() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let dir = ConfigLoader.find()?.deletingLastPathComponent() {
            NSWorkspace.shared.open(dir)
        }
    }

    func reloadConfig() {
        store.reloadConfig()
    }
}

// MARK: - 入口

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 不出现在 Dock
    app.run()
}
