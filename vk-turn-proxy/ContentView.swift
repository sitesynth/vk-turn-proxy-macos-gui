import SwiftUI
import Foundation

// wdtt://IP:DTLS_PORT:WG_PORT:LOCAL_PORT:PASSWORD:VK_HASH
struct WdttLink {
    let peer: String
    let password: String
    let vkHash: String
    let listenPort: String

    static func parse(_ raw: String) -> WdttLink? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("wdtt://") else { return nil }
        let parts = String(s.dropFirst("wdtt://".count)).components(separatedBy: ":")
        guard parts.count >= 6, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[4].isEmpty, !parts[5].isEmpty else { return nil }
        return WdttLink(peer: "\(parts[0]):\(parts[1])", password: parts[4],
                        vkHash: parts[5], listenPort: parts[3].isEmpty ? "9000" : parts[3])
    }
}

struct ContentView: View {
    @AppStorage("wdttLink") private var wdttLink: String = ""

    @State private var phase: Phase = .idle
    @State private var consoleOutput = ""
    @State private var captchaURL: URL? = nil
    @State private var wdttProcess: Process?

    enum Phase {
        case idle, connectingVK, waitingConfig, settingUpWG, running, error(String)
        var label: String {
            switch self {
            case .idle: return "Готов"
            case .connectingVK: return "Подключение через VK TURN…"
            case .waitingConfig: return "Получение WireGuard конфига…"
            case .settingUpWG: return "Настройка WireGuard…"
            case .running: return "Подключено"
            case .error(let e): return "Ошибка: \(e)"
            }
        }
        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
        var isBusy: Bool {
            switch self {
            case .connectingVK, .waitingConfig, .settingUpWG: return true
            default: return false
            }
        }
        var color: Color {
            switch self {
            case .running: return .green
            case .error: return .red
            case .idle: return .gray
            default: return .orange
            }
        }
    }

    private var parsed: WdttLink? { WdttLink.parse(wdttLink) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 26)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VK Turn Proxy").font(.headline)
                    Text("Обход ограничений VK Звонков").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Circle().fill(phase.color).frame(width: 12, height: 12)
                    .shadow(color: phase.isRunning ? .green : .clear, radius: 4)
            }
            .padding(20)

            Divider()

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ссылка wdtt://").font(.subheadline).foregroundColor(.secondary)
                    TextField("wdtt://IP:PORT:PORT:PORT:PASSWORD:HASH", text: $wdttLink)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(phase.isBusy || phase.isRunning)
                }

                if let p = parsed {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                        Text("Сервер: \(p.peer)").font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                } else if !wdttLink.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.caption)
                        Text("Неверный формат").font(.caption).foregroundColor(.red)
                        Spacer()
                    }
                }

                if let url = captchaURL {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Требуется капча").font(.subheadline).bold()
                            Text("Решите в браузере, затем вернитесь").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Открыть") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                    .padding(12).background(Color.orange.opacity(0.1)).cornerRadius(8)
                }

                HStack(spacing: 12) {
                    Button(action: start) {
                        Label("Запустить", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                    .disabled(phase.isBusy || phase.isRunning || parsed == nil)

                    Button(action: stop) {
                        Label("Остановить", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!phase.isRunning && !phase.isBusy)
                }

                HStack(spacing: 6) {
                    if phase.isBusy {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: phase.isRunning ? "checkmark.circle.fill" : "info.circle")
                            .foregroundColor(phase.color)
                    }
                    Text(phase.label).font(.subheadline).foregroundColor(phase.isRunning ? .primary : .secondary)
                    Spacer()
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(consoleOutput.isEmpty ? "Журнал появится здесь..." : consoleOutput)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(consoleOutput.isEmpty ? .secondary : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).id("bottom")
                    }
                    .frame(height: 180).background(Color.black).cornerRadius(8)
                    .onChange(of: consoleOutput) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .onDisappear { stop() }
    }

    // MARK: - Start

    private func start() {
        guard let p = parsed else { return }
        captchaURL = nil
        consoleOutput = ""
        phase = .connectingVK

        let binDir = bundleResourcesURL()

        // Copy binaries to writable location
        let support = supportDir()
        for name in ["wdtt-client", "wireguard-go", "wg"] {
            let src = binDir.appendingPathComponent(name)
            let dst = support.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        let wdttBin = support.appendingPathComponent("wdtt-client")
        let process = Process()
        process.executableURL = wdttBin
        process.arguments = [
            "-peer", p.peer,
            "-password", p.password,
            "-vk", p.vkHash,
            "-listen", "127.0.0.1:\(p.listenPort)",
            "-n", "12"
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["WDTT_EVENTS": "1"]
        ) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.handleOutput(str, support: support) }
        }

        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if case .running = self.phase { } else {
                    self.phase = .idle
                }
                self.consoleOutput += "\n--- wdtt-client завершён ---\n"
                self.teardownWireGuard(support: support)
            }
        }

        do {
            try process.run()
            wdttProcess = process
            phase = .connectingVK
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func handleOutput(_ text: String, support: URL) {
        // Parse structured events
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("__WDTT_EVENT__|CONFIG|") {
                let json = String(line.dropFirst("__WDTT_EVENT__|CONFIG|".count))
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let config = obj["config"] as? String {
                    phase = .settingUpWG
                    consoleOutput += "\n[✓] Получен WireGuard конфиг от сервера\n"
                    setupWireGuard(config: config, support: support)
                    return
                }
            }
            if line.contains("__WDTT_EVENT__|READY|") {
                if case .connectingVK = phase { phase = .waitingConfig }
            }
        }

        // Regular log output
        let filtered = text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("__WDTT_EVENT__") }
            .joined(separator: "\n")
        if !filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consoleOutput += filtered
            detectCaptcha(in: filtered)
        }
    }

    // MARK: - WireGuard setup

    private func setupWireGuard(config: String, support: URL) {
        let configPath = "/tmp/wg-vkproxy.conf"
        // Remove DNS line — causes issues without proper DNS setup
        let cleanConfig = config.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("DNS") }
            .joined(separator: "\n")
        try? cleanConfig.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Parse Address from config
        let address = cleanConfig.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("Address") })
            .flatMap { $0.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.components(separatedBy: "/").first }
            ?? "10.66.66.99"

        let wgBin = support.appendingPathComponent("wireguard-go").path
        let wgCtrl = support.appendingPathComponent("wg").path

        // Shell script run with admin privileges via osascript
        let script = """
        #!/bin/sh
        set -e
        # Remove old interface if exists
        kill $(cat /var/run/wireguard/utun99.pid 2>/dev/null) 2>/dev/null || true
        sleep 0.3
        # Start wireguard-go
        '\(wgBin)' utun99
        sleep 0.5
        # Apply config
        '\(wgCtrl)' setconf utun99 '\(configPath)'
        # Set IP
        ifconfig utun99 inet '\(address)' '\(address)'
        # Add routes (split 0.0.0.0/0 to avoid default route conflict)
        route -q -n add -inet 0.0.0.0/1   -interface utun99 2>/dev/null || true
        route -q -n add -inet 128.0.0.0/1 -interface utun99 2>/dev/null || true
        """

        let scriptPath = "/tmp/wg-vkproxy-setup.sh"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let appleScript = "do shell script \"/bin/sh '\(scriptPath)'\" with administrator privileges"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe

        task.terminationHandler = { t in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if t.terminationStatus == 0 {
                    self.phase = .running
                    self.consoleOutput += "[✓] WireGuard запущен. Интерфейс: utun99 (\(address))\n"
                    self.consoleOutput += "[✓] VPN активен — VK звонки работают через прокси\n"
                } else {
                    let msg = out.isEmpty ? "Отменено пользователем" : out.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.phase = .error(msg)
                    self.consoleOutput += "[✗] WireGuard: \(msg)\n"
                    self.wdttProcess?.terminate()
                    self.wdttProcess = nil
                }
            }
        }

        consoleOutput += "[→] Запрос прав администратора для WireGuard…\n"
        try? task.run()
    }

    // MARK: - Stop

    private func stop() {
        wdttProcess?.terminate()
        wdttProcess = nil
        teardownWireGuard(support: supportDir())
        phase = .idle
        captchaURL = nil
    }

    private func teardownWireGuard(support: URL) {
        let teardown = """
        #!/bin/sh
        route -q -n delete -inet 0.0.0.0/1   2>/dev/null || true
        route -q -n delete -inet 128.0.0.0/1 2>/dev/null || true
        PID=$(cat /var/run/wireguard/utun99.pid 2>/dev/null)
        if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
        rm -f /var/run/wireguard/utun99.pid /var/run/wireguard/utun99.sock 2>/dev/null || true
        """
        let path = "/tmp/wg-vkproxy-teardown.sh"
        try? teardown.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let script = "do shell script \"/bin/sh '\(path)'\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Helpers

    private func detectCaptcha(in text: String) {
        guard captchaURL == nil else { return }
        let pattern = #"https?://[^\s\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range),
           let urlRange = Range(match.range, in: text),
           let url = URL(string: String(text[urlRange])) {
            captchaURL = url
        }
    }

    private func bundleResourcesURL() -> URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }

    private func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VKTurnProxy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
