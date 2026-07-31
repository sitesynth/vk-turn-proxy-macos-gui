import SwiftUI
import Foundation

// wdtt://IP:DTLS_PORT:WG_PORT:LOCAL_PORT:PASSWORD:VK_HASH
struct WdttLink {
    let peer: String   // IP:DTLS_PORT
    let password: String
    let vkHash: String
    let listenPort: String // LOCAL_PORT

    static func parse(_ raw: String) -> WdttLink? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("wdtt://") else { return nil }
        let body = String(s.dropFirst("wdtt://".count))
        let parts = body.components(separatedBy: ":")
        guard parts.count >= 6,
              !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[4].isEmpty, !parts[5].isEmpty
        else { return nil }
        return WdttLink(
            peer: "\(parts[0]):\(parts[1])",
            password: parts[4],
            vkHash: parts[5],
            listenPort: parts[3].isEmpty ? "9000" : parts[3]
        )
    }
}

struct ContentView: View {
    @AppStorage("wdttLink") private var wdttLink: String = ""

    @State private var isRunning = false
    @State private var statusMessage = "Готов к работе"
    @State private var consoleOutput = ""
    @State private var currentProcess: Process?
    @State private var captchaURL: URL? = nil

    private var parsed: WdttLink? { WdttLink.parse(wdttLink) }

    var body: some View {
        VStack(spacing: 0) {
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
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ссылка wdtt://").font(.subheadline).foregroundColor(.secondary)
                    TextField("wdtt://IP:PORT:PORT:PORT:PASSWORD:HASH", text: $wdttLink)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                if let p = parsed {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green).font(.caption)
                        Text("Сервер: \(p.peer)  •  Прокси: 127.0.0.1:\(p.listenPort)")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                } else if !wdttLink.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red).font(.caption)
                        Text("Неверный формат ссылки")
                            .font(.caption).foregroundColor(.red)
                        Spacer()
                    }
                }

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

                HStack(spacing: 12) {
                    Button(action: startProxy) {
                        Label("Запустить", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                    .disabled(isRunning || parsed == nil)

                    Button(action: stopProxy) {
                        Label("Остановить", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!isRunning)
                }

                HStack(spacing: 6) {
                    Image(systemName: isRunning ? "checkmark.circle.fill" : "info.circle")
                        .foregroundColor(isRunning ? .green : .secondary)
                    Text(statusMessage).font(.subheadline)
                        .foregroundColor(isRunning ? .primary : .secondary)
                    Spacer()
                    if isRunning, let p = parsed {
                        Button(action: { copyToClipboard("127.0.0.1:\(p.listenPort)") }) {
                            Label("Скопировать адрес", systemImage: "doc.on.doc").font(.caption)
                        }.buttonStyle(.borderless)
                    }
                }

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
        guard let p = parsed else { return }
        guard let execURL = bundledBinaryURL() else {
            statusMessage = "Ошибка: бинарник не найден"
            return
        }
        let workingBinary = workingBinaryURL()
        do {
            try? FileManager.default.removeItem(at: workingBinary)
            try FileManager.default.copyItem(at: execURL, to: workingBinary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workingBinary.path)
        } catch {
            statusMessage = "Ошибка подготовки: \(error.localizedDescription)"
            return
        }

        let process = Process()
        process.executableURL = workingBinary
        process.arguments = [
            "-peer", p.peer,
            "-password", p.password,
            "-vk", p.vkHash,
            "-listen", "127.0.0.1:\(p.listenPort)",
            "-n", "12"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        captchaURL = nil
        consoleOutput = "$ wdtt-client -peer \(p.peer) -vk [HASH] -listen 127.0.0.1:\(p.listenPort)\n\n"

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
            statusMessage = "Подключение к \(p.peer)…"
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

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        let prev = statusMessage
        statusMessage = "Адрес скопирован!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.statusMessage = prev }
    }

    private func bundledBinaryURL() -> URL? {
        Bundle.main.url(forResource: "wdtt-client", withExtension: nil)
    }

    private func workingBinaryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VKTurnProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("wdtt-client")
    }
}
