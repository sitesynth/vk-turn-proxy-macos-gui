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

// MARK: - Design Tokens

private let ink   = Color(red: 0.067, green: 0.067, blue: 0.067)   // #111111
private let cream = Color(red: 0.953, green: 0.941, blue: 0.914)   // #F3F0E9
private let yellow = Color(red: 1.0,  green: 0.843, blue: 0.192)   // #FFD731
private let green  = Color(red: 0.333, green: 0.859, blue: 0.612)  // #55DB9C
private let paper  = Color.white

// MARK: - Brutalist Button

private struct BrutalistButton: View {
    let label: String
    let icon: String
    var bg: Color = yellow
    var fg: Color = ink
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .black))
                Text(label).font(.system(size: 14, weight: .black)).textCase(.uppercase)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(disabled ? Color.gray.opacity(0.2) : bg)
            .foregroundColor(disabled ? Color.gray : fg)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(disabled ? Color.gray : ink, lineWidth: 2)
            )
            .cornerRadius(10)
            .shadow(
                color: disabled ? .clear : ink,
                radius: 0,
                x: hovered ? 2 : 4,
                y: hovered ? 2 : 4
            )
            .offset(x: hovered ? 2 : 0, y: hovered ? 2 : 0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - SVG Image loader

private struct BundleSVG: View {
    let name: String
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
        }
    }
}

// MARK: - Main View

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
            case .idle:           return "Готов к запуску"
            case .connectingVK:   return "Подключение через VK TURN…"
            case .waitingConfig:  return "Получение конфига WireGuard…"
            case .settingUpWG:    return "Настройка WireGuard…"
            case .running:        return "VPN АКТИВЕН"
            case .error(let e):   return "Ошибка: \(e)"
            }
        }
        var isRunning: Bool { if case .running = self { return true }; return false }
        var isBusy: Bool {
            switch self {
            case .connectingVK, .waitingConfig, .settingUpWG: return true
            default: return false
            }
        }
        var dotColor: Color {
            switch self {
            case .running: return green
            case .error:   return .red
            case .idle:    return Color.gray.opacity(0.4)
            default:       return yellow
            }
        }
    }

    private var parsed: WdttLink? { WdttLink.parse(wdttLink) }
    private let helperPath  = "/Library/PrivilegedHelperTools/vkproxy-helper"
    private let sudoersPath = "/etc/sudoers.d/vkproxy"

    var body: some View {
        ZStack {
            cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(ink).padding(.horizontal, 0)
                ScrollView {
                    VStack(spacing: 16) {
                        if needsInstall { installBanner }
                        linkField
                        if let url = captchaURL { captchaBanner(url: url) }
                        statusRow
                        actionButtons
                        consolePanel
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 520)
        .onAppear {
            checkHelper()
            runHelper(["teardown"])
        }
        .onDisappear { stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            BundleSVG(name: "whitelist-unblocker", width: 32, height: 32)
            BundleSVG(name: "imba-logo", width: 140, height: 52)
            Spacer()
            Circle()
                .fill(phase.dotColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(ink, lineWidth: 2))
                .shadow(color: phase.isRunning ? green.opacity(0.5) : .clear, radius: 6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(cream)
    }

    // MARK: - Install Banner

    private var installBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 20, weight: .black))
                .foregroundColor(ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("УСТАНОВКА СЕРВИСА")
                    .font(.system(size: 13, weight: .black))
                    .textCase(.uppercase)
                    .foregroundColor(ink)
                Text("Нужен пароль администратора — только один раз")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ink.opacity(0.6))
            }
            Spacer()
            if installing {
                ProgressView().scaleEffect(0.8).tint(ink)
            } else {
                BrutalistButton(label: "Установить", icon: "lock.open.fill", bg: yellow, fg: ink) {
                    installHelper()
                }
                .frame(width: 140)
            }
        }
        .padding(16)
        .background(yellow)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink, lineWidth: 2))
        .shadow(color: ink, radius: 0, x: 4, y: 4)
    }

    // MARK: - Link Field

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Вставьте ссылку из кабинета в разделе Whitelist Unblocker")
                .font(.system(size: 12, weight: .black))
                .textCase(.uppercase)
                .foregroundColor(ink)
                .fixedSize(horizontal: false, vertical: true)

            TextField("(wdtt://xxxx-xxxx)", text: $wdttLink)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .padding(12)
                .background(paper)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(parsed != nil ? ink : (wdttLink.isEmpty ? ink.opacity(0.35) : Color.red), lineWidth: 2)
                )
                .shadow(color: ink.opacity(0.12), radius: 0, x: 2, y: 2)
                .disabled(phase.isBusy || phase.isRunning)

            if let p = parsed {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(green)
                        .font(.system(size: 12, weight: .black))
                    Text("Сервер: \(p.peer)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ink.opacity(0.55))
                }
            } else if !wdttLink.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 12, weight: .black))
                    Text("Неверный формат")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.red)
                }
            }
        }
        .padding(16)
        .background(paper)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink, lineWidth: 2))
        .shadow(color: ink, radius: 0, x: 4, y: 4)
    }

    // MARK: - Captcha Banner

    private func captchaBanner(url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundColor(ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("ТРЕБУЕТСЯ КАПЧА").font(.system(size: 13, weight: .black)).foregroundColor(ink)
                Text("Решите в браузере и вернитесь")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(ink.opacity(0.6))
            }
            Spacer()
            BrutalistButton(label: "Открыть", icon: "safari.fill", bg: ink, fg: yellow) {
                NSWorkspace.shared.open(url)
            }
            .frame(width: 130)
        }
        .padding(16)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink, lineWidth: 2))
        .shadow(color: ink, radius: 0, x: 4, y: 4)
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: 10) {
            if phase.isBusy {
                ProgressView().scaleEffect(0.8).tint(ink)
            } else {
                Circle()
                    .fill(phase.dotColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(ink, lineWidth: 1.5))
            }
            Text(phase.label)
                .font(.system(size: 12, weight: .black))
                .textCase(.uppercase)
                .foregroundColor(phase.isRunning ? ink : ink.opacity(0.55))
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            BrutalistButton(
                label: "Запустить",
                icon: "play.fill",
                bg: yellow,
                fg: ink,
                disabled: phase.isBusy || phase.isRunning || parsed == nil || needsInstall
            ) { start() }

            BrutalistButton(
                label: "Остановить",
                icon: "stop.fill",
                bg: ink,
                fg: paper,
                disabled: !phase.isRunning && !phase.isBusy
            ) { stop() }
        }
    }

    // MARK: - Console

    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ЖУРНАЛ")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(ink.opacity(0.4))
                    .textCase(.uppercase)
                    .tracking(1.5)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().background(ink.opacity(0.15))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(consoleOutput.isEmpty ? "Журнал появится здесь..." : consoleOutput)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(consoleOutput.isEmpty ? Color.green.opacity(0.3) : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("bottom")
                }
                .frame(height: 160)
                .onChange(of: consoleOutput) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Color.black)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink, lineWidth: 2))
        .shadow(color: ink, radius: 0, x: 4, y: 4)
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
        guard let helperSrc  = Bundle.main.url(forResource: "vkproxy-helper", withExtension: nil),
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
                self.installing = false
                if ok {
                    self.checkHelper()
                    self.consoleOutput += self.needsInstall
                        ? "[✗] Установка не удалась\n"
                        : "[✓] Сервис установлен\n"
                } else {
                    self.consoleOutput += "[✗] Установка отменена\n"
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
        if let src = Bundle.main.url(forResource: "wdtt-client", withExtension: nil) {
            let dst = support.appendingPathComponent("wdtt-client")
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
        process.standardError  = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.handleOutput(str, peerIP: p.peerIP, support: support) }
        }

        process.terminationHandler = { _ in
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
                   let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
                   let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let uri  = obj["redirect_uri"] as? String,
                   let url  = URL(string: uri) {
                    captchaURL = url
                    consoleOutput += "[!] Требуется капча\n"
                }
                continue
            }
            if line.hasPrefix("__WDTT_EVENT__|CAPTCHA_DONE|") {
                captchaURL = nil; consoleOutput += "[✓] Капча пройдена\n"; continue
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
                    self.consoleOutput += "[✓] WireGuard запущен (utun99, \(address))\n[✓] VPN АКТИВЕН\n"
                } else {
                    self.phase = .error("WireGuard")
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

    @discardableResult
    private func runHelper(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IMBAVKProxy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
