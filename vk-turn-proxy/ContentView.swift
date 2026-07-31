import SwiftUI
import Foundation

struct ContentView: View {
    @AppStorage("vkLink") private var vkLink: String = ""
    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1:9000"

    @State private var isRunning = false
    @State private var statusMessage = "Готов к работе"
    @State private var consoleOutput = ""
    @State private var currentProcess: Process?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 28))
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

            VStack(spacing: 16) {
                // VK link input
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ссылка на звонок ВКонтакте")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("https://vk.com/call/join/...", text: $vkLink)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // Local proxy address
                VStack(alignment: .leading, spacing: 6) {
                    Text("Локальный адрес прокси")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("127.0.0.1:9000", text: $listenAddress)
                        .textFieldStyle(.roundedBorder)
                }

                // Start / Stop
                HStack(spacing: 12) {
                    Button(action: startProxy) {
                        Label("Запустить", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(isRunning || vkLink.isEmpty)

                    Button(action: stopProxy) {
                        Label("Остановить", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!isRunning)
                }

                // Status
                HStack(spacing: 6) {
                    Image(systemName: isRunning ? "checkmark.circle.fill" : "info.circle")
                        .foregroundColor(isRunning ? .green : .secondary)
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundColor(isRunning ? .primary : .secondary)
                    Spacer()
                    if isRunning {
                        Button(action: copyAddress) {
                            Label("Скопировать адрес", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // Console log
                ScrollView {
                    Text(consoleOutput.isEmpty ? "Журнал событий появится здесь..." : consoleOutput)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(consoleOutput.isEmpty ? .secondary : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 140)
                .background(Color.black)
                .cornerRadius(8)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onDisappear { stopProxy() }
    }

    private func startProxy() {
        guard let execURL = bundledBinaryURL() else {
            statusMessage = "Ошибка: бинарник не найден в пакете приложения"
            return
        }

        let workingBinary = workingBinaryURL()

        do {
            if !FileManager.default.fileExists(atPath: workingBinary.path) {
                try FileManager.default.copyItem(at: execURL, to: workingBinary)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workingBinary.path)
        } catch {
            statusMessage = "Ошибка подготовки: \(error.localizedDescription)"
            return
        }

        var args: [String] = ["-listen", listenAddress, "-n", "4"]
        if !vkLink.isEmpty { args.append(contentsOf: ["-vk-link", vkLink]) }

        let process = Process()
        process.executableURL = workingBinary
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        consoleOutput = "--- Запуск ---\n"

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.consoleOutput += str }
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
            statusMessage = "Работает на \(listenAddress)"
        } catch {
            statusMessage = "Ошибка запуска: \(error.localizedDescription)"
        }
    }

    private func stopProxy() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
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
