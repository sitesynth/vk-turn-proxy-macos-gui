import SwiftUI
import Foundation

// wdtt://IP:DTLS_PORT:WG_PORT:LOCAL_PORT:PASSWORD:VK_HASH
struct WdttLink {
    let peer: String
    let peerIP: String
    let password: String
    let vkHash: String
    let listenPort: String

    static func parse(_ raw: String) -> WdttLink? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("wdtt://") else { return nil }
        let parts = String(s.dropFirst("wdtt://".count)).components(separatedBy: ":")
        guard parts.count >= 6, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[4].isEmpty, !parts[5].isEmpty else { return nil }
        return WdttLink(
            peer: "\(parts[0]):\(parts[1])",
            peerIP: parts[0],
            password: parts[4],
            vkHash: parts[5],
            listenPort: parts[3].isEmpty ? "9000" : parts[3]
        )
    }
}

struct ContentView: View {
    @AppStorage("wdttLink") private var wdttLink: String = ""

    @State private var phase: Phase = .idle
    @State private var consoleOutput = ""
    @State private var captchaURL: URL? = nil
    @State private var wdttProcess: Process?
    @State private var needsInstall = false
    @State private var installing = false

    enum Phase {
        case idle, connectingVK, waitingConfig, settingUpWG, running, error(String)
        var label: String {
            switch self {
            case .idle: return "Готов"
            case .connectingVK: return "Подключение через VK TURN…"
            case .waitingConfig: return "Получение WireGuard конфига…"
            case .settingUpWG: return "Настройка WireGuard…"
            case .running: return "VPN активен"
            case .error(let e): return "Ошибка: \(e)"
            }
        }
        var isRunning: Bool { if case .running = self { return true }; return false }
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
    private let helperPath = "/Library/PrivilegedHelperTools/vkproxy-helper"
    private let sudoersPath = "/etc/sudoers.d/vkproxy"

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
                if needsInstall {
                    HStack(spacing: 10) {
                        Image(systemName: "shield.lefthalf.filled").foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Установка сервиса (один раз)").font(.subheadline).bold()
                            Text("Нужен пароль администратора").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if installing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Button("Установить") { installHelper() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12).background(Color.blue.opacity(0.1)).cornerRadius(8)
                }

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
                    .disabled(phase.isBusy || phase.isRunning || parsed == nil || needsInstall)

                    Button(action: stop) {
                        Label("Остановить", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!phase.isRunning && !phase.isBusy)
                }

                HStack(spacing: 6) {
                    if phase.isBusy { ProgressView().scaleEffect(0.7) }
                    else {
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
        .onAppear {
            checkHelper()
            // Clean up any stale WireGuard state from a previous crash
            runHelper(["teardown"])
        }
        .onDisappear { stop() }
    }

    // MARK: - Helper check & install

    private func checkHelper() {
        needsInstall = !FileManager.default.fileExists(atPath: helperPath) ||
                       !FileManager.default.fileExists(atPath: sudoersPath)
    }

    private func installHelper() {
        guard !installing else { return }
        installing = true

        let support = supportDir()
        guard let helperSrc = Bundle.main.url(forResource: "vkproxy-helper", withExtension: nil),
              let installSrc = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            installing = false
            consoleOutput += "[✗] Ресурсы не найдены в бандле\n"
            return
        }

        let helperTmp  = support.appendingPathComponent("vkproxy-helper")
        let installTmp = support.appendingPathComponent("install.sh")
        for (src, dst) in [(helperSrc, helperTmp), (installSrc, installTmp)] {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        let scriptPath = support.appendingPathComponent("do-install.sh").path
        let script = "#!/bin/sh\n'\(installTmp.path)' '\(helperTmp.path)'\n"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        DispatchQueue.global().async {
            let ok = scriptPath.withCString { runWithAdminPrivileges($0) == 0 }
            DispatchQueue.main.async {
                installing = false
                if ok {
                    checkHelper()
                    consoleOutput += needsInstall
                        ? "[✗] Установка не удалась\n"
                        : "[✓] Сервис установлен\n"
                } else {
                    consoleOutput += "[✗] Установка отменена\n"
                }
            }
        }
    }

    // MARK: - Start

    private func start() {
        guard let p = parsed else { return }
        captchaURL = nil
        consoleOutput = ""
        phase = .connectingVK

        let support = supportDir()
        for name in ["wdtt-client"] {
            guard let src = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            let dst = support.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        let process = Process()
        process.executableURL = support.appendingPathComponent("wdtt-client")
        process.arguments = [
            "-peer", p.peer, "-password", p.password,
            "-vk", p.vkHash, "-listen", "127.0.0.1:\(p.listenPort)", "-n", "12"
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["WDTT_EVENTS": "1"]) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.handleOutput(str, peerIP: p.peerIP, support: support) }
        }

        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.consoleOutput += "\n--- wdtt-client завершён ---\n"
                if case .running = self.phase { } else { self.phase = .idle }
                self.runHelper(["teardown"])
            }
        }

        do {
            try process.run()
            wdttProcess = process
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func handleOutput(_ text: String, peerIP: String, support: URL) {
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("__WDTT_EVENT__|CONFIG|") {
                let json = String(line.dropFirst("__WDTT_EVENT__|CONFIG|".count))
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let config = obj["config"] as? String {
                    phase = .settingUpWG
                    consoleOutput += "\n[✓] Получен WireGuard конфиг\n"
                    setupWireGuard(config: config, peerIP: peerIP, support: support)
                    return
                }
            }
            if line.hasPrefix("__WDTT_EVENT__|CAPTCHA_REQUEST|") {
                let json = String(line.dropFirst("__WDTT_EVENT__|CAPTCHA_REQUEST|".count))
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let uri = obj["redirect_uri"] as? String,
                   let url = URL(string: uri) {
                    captchaURL = url
                    consoleOutput += "[!] Требуется капча\n"
                }
                continue
            }
            if line.hasPrefix("__WDTT_EVENT__|CAPTCHA_DONE|") {
                captchaURL = nil
                consoleOutput += "[✓] Капча пройдена\n"; continue
            }
            if line.hasPrefix("__WDTT_EVENT__|READY|") {
                if case .connectingVK = phase { phase = .waitingConfig }; continue
            }
            if line.hasPrefix("__WDTT_EVENT__") { continue }
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                consoleOutput += line + "\n"
            }
        }
    }

    // MARK: - WireGuard via sudo helper

    private func setupWireGuard(config: String, peerIP: String, support: URL) {
        let address = config.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("Address") })
            .flatMap { $0.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.components(separatedBy: "/").first } ?? "10.66.66.99"

        for name in ["wireguard-go", "wg"] {
            if let src = Bundle.main.url(forResource: name, withExtension: nil) {
                let dst = support.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            }
        }

        let configPath = "/tmp/wg-vkproxy.conf"
        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)

        let wgBin  = support.appendingPathComponent("wireguard-go").path
        let wgCtrl = support.appendingPathComponent("wg").path
        let pid    = wdttProcess?.processIdentifier ?? 0

        consoleOutput += "[→] Настройка WireGuard…\n"

        DispatchQueue.global().async {
            let ok = self.runHelper([
                "setup",
                "-config",  configPath,
                "-peer-ip", peerIP,
                "-addr",    address,
                "-wg-bin",  wgBin,
                "-wg-ctrl", wgCtrl,
                "-pid",     String(pid)
            ])
            DispatchQueue.main.async {
                if ok {
                    self.phase = .running
                    self.consoleOutput += "[✓] WireGuard запущен (utun99, \(address))\n"
                    self.consoleOutput += "[✓] VPN активен\n"
                } else {
                    self.phase = .error("WireGuard: ошибка")
                    self.consoleOutput += "[✗] WireGuard не запустился\n"
                    self.wdttProcess?.terminate()
                    self.wdttProcess = nil
                }
            }
        }
    }

    private func stop() {
        wdttProcess?.terminate()
        wdttProcess = nil
        runHelper(["teardown"])
        phase = .idle
        captchaURL = nil
    }

    // Run helper via sudo -n (no password prompt thanks to sudoers)
    @discardableResult
    private func runHelper(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VKTurnProxy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
