import SwiftUI
import Foundation

struct ContentView: View {
    @AppStorage("vkLink") private var vkLink: String = ""
    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1:9000"
    @AppStorage("manualCaptcha") private var manualCaptcha: Bool = true

    @State private var isRunning = false
    @State private var statusMessage = "Готов к работе"
    @State private var consoleOutput = ""
    @State private var currentProcess: Process?
    @State private var captchaURL: URL? = nil

    // wdtt://IP:DTLS_PORT:WG_PORT:LOCAL_PORT:PASSWORD:WG_KEY
    private var parsedPeer: String? {
        let link = vkLink.trimmingCharacters(in: .whitespaces)
        guard link.hasPrefix("wdtt://") else { return nil }
        let parts = String(link.dropFirst("wdtt://".count)).components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]):\(parts[1])"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 26))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VK Turn Proxy")
                        .font(.headline)
                    Text("Обход ограничений VK Звонков")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Circle()
                    .fill(isRunning ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 12, height: 12)
                    .shadow(color: isRunning ? .green : .clear, radius: 4)
            }
            .padding(20)

            Divider()

            VStack(spacing: 14) {
                // Link input
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ссылка на подключение")
                        .font(.subheadline).foregroundColor(.secondary)
                    TextField("wdtt://IP:PORT:...", text: $vkLink)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // Parsed peer hint
                if let peer = parsedPeer {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green).font(.caption)
                        Text("Сервер: \(peer)")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                }

                // Local address + captcha toggle
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Локальный прокси").font(.subheadline).foregroundColor(.secondary)
                        TextField("127.0.0.1:9000", text: $listenAddress)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Капча").font(.subheadline).foregroundColor(.secondary)
                        Toggle("Ручная", isOn: $manualCaptcha)
                            .toggleStyle(.switch).controlSize(.small)
                    }
                    .frame(width: 105)
                }

                // Captcha banner
                if let url = captchaURL {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Требуется капча").font(.subheadline).bold()
                            Text("Решите в браузере, затем вернитесь")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Открыть") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                // Start / Stop
                HStack(spacing: 12) {
                    Button(action: startProxy) {
                        Label("Запустить", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                    .disabled(isRunning || vkLink.isEmpty)

                    Button(action: stopProxy) {
                        Label("Остановить", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!isRunning)
                }

                // Status
                HStack(spacing: 6) {
                    Image(systemName: isRunning ? "checkmark.circle.fill" : "info.circle")
                        .foregroundColor(isRunning ? .green : .secondary)
                    Text(statusMessage).font(.subheadline)
                        .foregroundColor(isRunning ? .primary : .secondary)
                    Spacer()
                    if isRunning {
                        Button(action: copyAddress) {
                            Label("Скопировать адрес", systemImage: "doc.on.doc").font(.caption)
                        }.buttonStyle(.borderless)
                    }
                }

                // Console
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(consoleOutput.isEmpty ? "Журнал появится здесь..." : consoleOutput)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(consoleOutput.isEmpty ? .secondary : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("bottom")
                    }
                    .frame(height: 160)
                    .background(Color.black)
                    .cornerRadius(8)
                    .onChange(of: consoleOutput) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 500)
        .onDisappear { stopProxy() }
    }

    private func startProxy() {
        guard let execURL = bundledBinaryURL() else {
            statusMessage = "Ошибка: бинарник не найден"
            return
        }
        let workingBinary = workingBinaryURL()
        do {
            if !FileManager.default.fileExists(atPath: workingBinary.path) {
                try FileManager.default.copyItem(at: execURL, to: workingBinary)
            } else {
                // Always refresh binary from bundle in case of update
                try FileManager.default.removeItem(at: workingBinary)
                try FileManager.default.copyItem(at: execURL, to: workingBinary)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workingBinary.path)
        } catch {
            statusMessage = "Ошибка подготовки: \(error.localizedDescription)"
            return
        }

        let link = vkLink.trimmingCharacters(in: .whitespaces)
        var args: [String] = ["-listen", listenAddress, "-n", "4", "-vk-link", link]
        if let peer = parsedPeer { args.append(contentsOf: ["-peer", peer]) }
        if manualCaptcha { args.append("-manual-captcha") }

        let process = Process()
        process.executableURL = workingBinary
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        captchaURL = nil
        consoleOutput = "$ client -listen \(listenAddress) -peer \(parsedPeer ?? "?") -vk-link [LINK]\n\n"

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.consoleOutput += str
                self.detectCaptcha(in: str)
            }
        }

        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.isRunning = false
                self.statusMessage = "Остановлен"
                self.consoleOutput += "\n--- Процесс завершён ---\n"
            }
        }

        do {
            try process.run()
            currentProcess = process
            isRunning = true
            captchaURL = nil
            statusMessage = "Подключение к \(parsedPeer ?? listenAddress)…"
        } catch {
            statusMessage = "Ошибка запуска: \(error.localizedDescription)"
        }
    }

    private func detectCaptcha(in text: String) {
        guard captchaURL == nil else { return }
        let pattern = #"https?://[^\s\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range),
           let urlRange = Range(match.range, in: text),
           let url = URL(string: String(text[urlRange])) {
            captchaURL = url
            statusMessage = "Требуется капча — нажмите «Открыть»"
        }
    }

    private func stopProxy() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
        captchaURL = nil
        statusMessage = "Остановлен"
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(listenAddress, forType: .string)
        let prev = statusMessage
        statusMessage = "Адрес скопирован!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.statusMessage = prev }
    }

    private func bundledBinaryURL() -> URL? {
        Bundle.main.url(forResource: "client-darwin-arm64", withExtension: nil)
    }

    private func workingBinaryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VKTurnProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("client-darwin-arm64")
    }
}
