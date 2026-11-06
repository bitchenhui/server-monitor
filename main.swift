// ServerMonitor — macOS 菜单栏服务器监控小工具
// 读取 ~/.ssh/config，通过 SSH 并行采集所有机器的实时 CPU / 内存，弹出面板一览显示
// 构建：./build.sh

import AppKit
import SwiftUI

// MARK: - 配置

struct ServerConfig: Codable {
    var interval: Double = 3.0   // 采集间隔（秒）
    var columns: Int? = nil      // 面板列数；null/0 = 按机器数自动（≤6:1列 ≤14:2列 >14:3列）
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
}

enum SSHConfigParser {
    /// 解析 ~/.ssh/config，返回所有显式主机（跳过含通配符的 Host 段）
    static func parse() -> [SSHHostEntry] {
        let path = NSHomeDirectory() + "/.ssh/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var hosts: [SSHHostEntry] = []
        var current: SSHHostEntry?
        func flush() {
            if let c = current { hosts.append(c) }
            current = nil
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "host":
                flush()
                // 一行 Host 可写多个别名，跳过通配符，取第一个
                let names = value.split(separator: " ").map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") }
                if let first = names.first {
                    current = SSHHostEntry(alias: first, hostName: nil, user: nil, port: nil)
                }
            case "hostname":
                current?.hostName = value.isEmpty ? nil : value
            case "user":
                current?.user = value.isEmpty ? nil : value
            case "port":
                current?.port = Int(value)
            default:
                break
            }
        }
        flush()
        return Self.dedupe(hosts)
    }

    /// 去重：同一台机器（实际地址+端口相同）只保留一个条目。
    /// 实际地址 = HostName ?? 别名（Host 段没写 HostName 时，别名本身就是地址）。
    /// 多条指向同一台时优先保留命名别名，弃用裸 IP 条目。
    private static func dedupe(_ hosts: [SSHHostEntry]) -> [SSHHostEntry] {
        func key(_ h: SSHHostEntry) -> String {
            let addr = h.hostName ?? h.alias
            let port = h.port ?? 22
            return "\(addr.lowercased()):\(port)"
        }
        func isIPAlias(_ s: String) -> Bool {
            let parts = s.split(separator: ".")
            return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
        }
        var seen: [String: SSHHostEntry] = [:]
        var order: [String] = []
        for h in hosts {
            let k = key(h)
            if let existing = seen[k] {
                // 已记录的是裸 IP 条目、新来的是命名别名 → 换成别名条目
                if isIPAlias(existing.alias) && !isIPAlias(h.alias) {
                    seen[k] = h
                }
            } else {
                seen[k] = h
                order.append(k)
            }
        }
        return order.compactMap { seen[$0] }
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

enum SSHError: LocalizedError {
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .remote(let msg): return msg
        }
    }
}

enum Collector {
    /// 一次 SSH 调用完成 CPU 两次采样 + 内存 + 负载
    /// 直接用 ~/.ssh/config 里的别名连接，自动继承 User/Port/IdentityFile/ProxyJump 等配置
    static func sample(_ host: SSHHostEntry) throws -> Sample {
        let remote = "head -1 /proc/stat; sleep 1; head -1 /proc/stat; "
            + "grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; cat /proc/loadavg"
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new",
            host.alias,
            remote,
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

        guard process.terminationStatus == 0 else {
            var msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.isEmpty { msg = "ssh 退出码 \(process.terminationStatus)" }
            if msg.contains("Permission denied") {
                msg += "（BatchMode 需要免密：请先执行 ssh-copy-id）"
            }
            throw SSHError.remote(msg)
        }

        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 5 else {
            throw SSHError.remote("远程输出格式异常：\(out.prefix(200))")
        }

        func cpuJiffies(_ line: String) -> (busy: Double, total: Double)? {
            let parts = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard parts.count >= 5 else { return nil }
            let idle = parts[3] + (parts.count > 4 ? parts[4] : 0) // idle + iowait
            let total = parts.reduce(0, +)
            return (total - idle, total)
        }

        guard let c1 = cpuJiffies(lines[0]), let c2 = cpuJiffies(lines[1]) else {
            throw SSHError.remote("无法解析 /proc/stat")
        }
        let cpu = c2.total > c1.total ? (c2.busy - c1.busy) / (c2.total - c1.total) * 100 : 0

        func kb(_ line: String) -> Double? {
            line.split(separator: " ").compactMap { Double($0) }.first
        }
        guard let memTotal = kb(lines[2]), let memAvail = kb(lines[3]) else {
            throw SSHError.remote("无法解析 /proc/meminfo")
        }
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
}

// MARK: - 状态存储

@MainActor
final class MonitorStore: ObservableObject {
    @Published var hosts: [SSHHostEntry] = []
    @Published var samples: [String: Sample] = [:]    // alias -> 最新采样
    @Published var errors: [String: String] = [:]     // alias -> 最近错误
    @Published var config = ServerConfig()

    private var timer: Timer?
    private var inFlight: Set<String> = []

    var lastUpdate: Date? {
        samples.values.map(\.timestamp).max()
    }

    var configured: Bool { !hosts.isEmpty }

    func start() {
        reloadConfig()
        tick()
    }

    func reloadConfig() {
        hosts = SSHConfigParser.parse()
        if let cfg = ConfigLoader.load() { config = cfg }
        NSLog("ServerMonitor: 监控 %d 台 → %@", hosts.count,
              hosts.map(\.alias).joined(separator: ", "))
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(config.interval, 2)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 每轮对所有机器并行采样
    private func tick() {
        for host in hosts where !inFlight.contains(host.alias) {
            inFlight.insert(host.alias)
            Task.detached { [weak self] in
                do {
                    let s = try Collector.sample(host)
                    await MainActor.run { [weak self] in
                        self?.samples[host.alias] = s
                        self?.errors[host.alias] = nil
                        self?.inFlight.remove(host.alias)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.errors[host.alias] = error.localizedDescription
                        self?.inFlight.remove(host.alias)
                    }
                }
            }
        }
    }

    /// 菜单栏展示：CPU 最高的机器
    var hottest: (host: SSHHostEntry, sample: Sample)? {
        hosts.compactMap { h in samples[h.alias].map { (h, $0) } }
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

    var body: some View {
        let color = usageColor(percent)
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(percent / 100, 0.03))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 3)
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
    let host: SSHHostEntry
    let sample: Sample?
    let errorMessage: String?

    /// 卡片主色：按最差指标定级，出错为红
    private var accent: Color {
        if errorMessage != nil { return usageColor(95) }
        if let s = sample { return usageColor(max(s.cpuPercent, s.memPercent)) }
        return Theme.textTertiary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 标题行
            HStack(alignment: .center, spacing: 6) {
                Circle().fill(accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(0.7), radius: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.alias)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(host.hostName ?? host.alias)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if sample == nil && errorMessage == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.4))
                }
                if let s = sample {
                    Text(String(format: "负载 %.2f", s.load1))
                        .font(.system(size: 9, design: .monospaced).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                if errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(usageColor(95))
                }
            }
            .help(errorMessage ?? host.displayName)

            // 仪表区
            if let s = sample {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        MiniRing(percent: s.cpuPercent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("CPU")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.textTertiary)
                            Text(String(format: "%.1f%%", s.cpuPercent))
                                .font(.system(size: 11, weight: .semibold,
                                              design: .rounded).monospacedDigit())
                                .foregroundColor(usageColor(s.cpuPercent))
                        }
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 1, height: 32)
                    HStack(spacing: 8) {
                        MiniRing(percent: s.memPercent)
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
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接失败")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(usageColor(95))
                    Text(errorMessage)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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
}

// MARK: - 面板

struct PanelView: View {
    @ObservedObject var store: MonitorStore

    private var onlineCount: Int {
        store.hosts.filter { store.samples[$0.alias] != nil }.count
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 11) {
                // 头部
                HStack(spacing: 8) {
                    PulsingDot(color: store.hosts.isEmpty ? Theme.textTertiary
                                : store.errors.isEmpty ? Color(hex: 0x3DDC84)
                                : Color(hex: 0xFFA94D))
                    Text("服务器监控")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(onlineCount)/\(store.hosts.count) 台在线")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(Theme.textSecondary)
                        if let t = store.lastUpdate {
                            Text("更新于 \(timeFormatter.string(from: t))")
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
                                HostCard(
                                    host: h,
                                    sample: store.samples[h.alias],
                                    errorMessage: store.errors[h.alias]
                                )
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
                    if !store.errors.isEmpty {
                        Text("· \(store.errors.count) 台失败")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(hex: 0xFFA94D))
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
            return
        }
        if let (host, s) = store.hottest {
            let cpu = String(format: "%.0f%%", s.cpuPercent)
            let mem = String(format: "%.0f%%", s.memPercent)
            let str = NSMutableAttributedString(string: "🖥 ")
            str.append(NSAttributedString(string: cpu,
                                          attributes: [.foregroundColor: nsUsageColor(s.cpuPercent)]))
            str.append(NSAttributedString(string: " "))
            str.append(NSAttributedString(string: mem,
                                          attributes: [.foregroundColor: nsUsageColor(s.memPercent)]))
            if !store.errors.isEmpty {
                str.append(NSAttributedString(string: " ⚠︎",
                                              attributes: [.foregroundColor: NSColor.systemOrange]))
            }
            button.attributedTitle = str
            // 悬停提示：最热机器 + 全部异常
            var tip = "CPU 最高：\(host.alias) \(cpu) · 内存 \(mem)"
            for (alias, err) in store.errors {
                tip += "\n⚠︎ \(alias)：\(err)"
            }
            button.toolTip = tip
        } else if store.errors.isEmpty {
            button.title = "🖥 …"
        } else {
            button.title = "🖥 ⚠︎"
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
