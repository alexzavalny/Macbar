import AppKit
import Combine
import Security
import LocalAuthentication

enum AIProvider: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude" }
    var usageURL: URL {
        URL(string: self == .codex ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!
    }
}

struct AIUsageWindow: Identifiable, Equatable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct AIUsageSnapshot: Equatable {
    let windows: [AIUsageWindow]
    let fetchedAt: Date
    var summaryWindows: [AIUsageWindow] {
        let shared = windows.filter { $0.id == "five_hour" || $0.id == "seven_day" || $0.id.hasPrefix("codex.") }
        return shared.isEmpty ? windows : shared
    }
    var remainingPercent: Double? { summaryWindows.map(\.remainingPercent).min() }
}

struct AIProviderState {
    var snapshot: AIUsageSnapshot?
    var isRefreshing = false
    var error: AIUsageError?
}

enum AIUsageError: Error, LocalizedError {
    case codexNotInstalled, signIn(AIProvider), keychainAccess, invalidResponse, unavailable, timedOut
    case rateLimited(Date?)

    var errorDescription: String? {
        switch self {
        case .codexNotInstalled: return "Install the Codex CLI and sign in with your ChatGPT account to show limits."
        case .signIn(.codex): return "Open Codex and sign in with your ChatGPT account, then refresh. API-key accounts do not provide subscription limits."
        case .signIn(.claude): return "Sign in to Claude Code, then refresh. If your session expired, open Claude Code to renew it."
        case .keychainAccess: return "Allow access to your Claude Code sign-in to read usage. Background refreshes never open Keychain prompts."
        case .invalidResponse: return "The service returned an unrecognized limits response. Try again later."
        case .unavailable: return "Couldn’t reach the usage service. Check your connection and try again."
        case .timedOut: return "Reading usage timed out. Try refreshing again."
        case .rateLimited: return "The service is limiting refreshes. Please wait before trying again."
        }
    }

    var clearsSnapshot: Bool {
        switch self {
        case .signIn, .keychainAccess, .codexNotInstalled: return true
        default: return false
        }
    }
}

protocol AILimitsProviding {
    func fetch(_ provider: AIProvider, allowKeychainPrompt: Bool) async throws -> AIUsageSnapshot
}

enum AIUsageDecoder {
    static func codex(_ data: Data, now: Date = Date()) throws -> AIUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIUsageError.invalidResponse }
        let result = root["result"] as? [String: Any] ?? root
        var buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if buckets.isEmpty, let legacy = result["rateLimits"] as? [String: Any] { buckets["codex"] = legacy }
        var windows: [AIUsageWindow] = []
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] else { continue }
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any], let used = number(window["usedPercent"]) else { continue }
                let minutes = number(window["windowDurationMins"])
                let title: String
                if let minutes, minutes >= 10080 { title = "Weekly" }
                else if let minutes, minutes >= 60 { title = "\(Int(minutes / 60)) hours" }
                else if let minutes, minutes > 0 { title = "\(Int(minutes)) minutes" }
                else { title = slot == "primary" ? "Current window" : "Longer window" }
                let prefix = buckets.count > 1 ? "\(bucket["limitName"] as? String ?? key) · " : ""
                windows.append(AIUsageWindow(id: "\(key).\(slot)", title: prefix + title,
                                             usedPercent: min(100, max(0, used)),
                                             resetsAt: number(window["resetsAt"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }))
            }
        }
        guard !windows.isEmpty else { throw AIUsageError.invalidResponse }
        return AIUsageSnapshot(windows: windows, fetchedAt: now)
    }

    static func claude(_ data: Data, now: Date = Date()) throws -> AIUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIUsageError.invalidResponse }
        let names = [("five_hour", "5 hours"), ("seven_day", "Weekly"),
                     ("seven_day_sonnet", "Sonnet · Weekly"), ("seven_day_opus", "Opus · Weekly"),
                     ("seven_day_oauth_apps", "OAuth apps · Weekly")]
        let windows = names.compactMap { key, title -> AIUsageWindow? in
            guard let window = root[key] as? [String: Any], let used = number(window["utilization"]) else { return nil }
            return AIUsageWindow(id: key, title: title, usedPercent: min(100, max(0, used)),
                                 resetsAt: (window["resets_at"] as? String).flatMap(parseDate))
        }
        guard !windows.isEmpty else { throw AIUsageError.invalidResponse }
        return AIUsageSnapshot(windows: windows, fetchedAt: now)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Never follow a redirect carrying a provider's authorization header.
private final class UsageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class SystemAILimitsProvider: AILimitsProviding {
    func fetch(_ provider: AIProvider, allowKeychainPrompt: Bool) async throws -> AIUsageSnapshot {
        if provider == .codex { return try AIUsageDecoder.codex(await CodexLimitsRPC.read()) }
        let token = try await Task.detached(priority: .utility) { try Self.claudeToken(allowPrompt: allowKeychainPrompt) }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Macbar/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: UsageRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AIUsageError.unavailable }
        guard let response = response as? HTTPURLResponse else { throw AIUsageError.unavailable }
        switch response.statusCode {
        case 200: return try AIUsageDecoder.claude(data)
        case 401, 403: throw AIUsageError.signIn(.claude)
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw AIUsageError.rateLimited(Date().addingTimeInterval(max(1, delay ?? 180)))
        default: throw AIUsageError.unavailable
        }
    }

    private static func claudeToken(allowPrompt: Bool) throws -> String {
        let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let file = directory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let token = validClaudeToken(data) { return token }
        // A foreign app's legacy Keychain item may wait for user interaction even
        // with LAContext UI disabled. Require an explicit first-use action.
        guard allowPrompt || UserDefaults.standard.bool(forKey: "claudeUsageKeychainAccess") else {
            throw AIUsageError.keychainAccess
        }
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        context.localizedReason = "Macbar reads your Claude usage limits. Your sign-in is sent only to Anthropic."
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "Claude Code-credentials",
                                  kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                  kSecUseAuthenticationContext as String: context,
                                  kSecUseAuthenticationUI as String: allowPrompt ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw AIUsageError.keychainAccess
        }
        guard status == errSecSuccess, let data = item as? Data, let token = validClaudeToken(data) else {
            throw AIUsageError.signIn(.claude)
        }
        if allowPrompt { UserDefaults.standard.set(true, forKey: "claudeUsageKeychainAccess") }
        return token
    }

    private static func validClaudeToken(_ data: Data) -> String? {
        guard data.count < 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiry = oauth["expiresAt"] as? Double, expiry / 1000 <= Date().timeIntervalSince1970 { return nil }
        return token
    }
}

/// Official Codex app-server protocol; never starts a thread or generates tokens.
private enum CodexLimitsRPC {
    static func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try run()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func run() throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                           + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"])
        guard let executable = directories.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw AIUsageError.codexNotInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directories.joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AIUsageError.codexNotInstalled }
        let deadline = Date().addingTimeInterval(20)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        defer {
            timer.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "macbar", "title": "Macbar", "version": "0.1.0"]]])
        var buffer = Data()
        while process.isRunning || !buffer.isEmpty {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            guard buffer.count < 1_048_576 else { throw AIUsageError.invalidResponse }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if id == 0 {
                    guard message["error"] == nil else { throw AIUsageError.unavailable }
                    try send(["method": "initialized"])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1 {
                    if let error = message["error"] as? [String: Any] {
                        let text = (error["message"] as? String ?? "").lowercased()
                        throw text.contains("auth") || text.contains("login") || text.contains("sign in")
                            ? AIUsageError.signIn(.codex) : AIUsageError.unavailable
                    }
                    guard let result = message["result"] as? [String: Any] else { throw AIUsageError.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: result)
                }
            }
        }
        throw Date() >= deadline ? AIUsageError.timedOut : AIUsageError.signIn(.codex)
    }
}

@MainActor
final class AILimitsStore: ObservableObject {
    @Published private(set) var states: [AIProvider: AIProviderState] = [:]
    private let provider: AILimitsProviding
    private var tasks: [AIProvider: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var enabled = false

    init(provider: AILimitsProviding = SystemAILimitsProvider()) { self.provider = provider }
    deinit { timer?.invalidate(); tasks.values.forEach { $0.cancel() } }

    func state(for provider: AIProvider) -> AIProviderState { states[provider] ?? AIProviderState() }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        timer?.invalidate()
        timer = nil
        if enabled {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer?.tolerance = 30
        } else {
            tasks.values.forEach { $0.cancel() }
            tasks = [:]
            for key in AIProvider.allCases { states[key]?.isRefreshing = false }
        }
    }

    func refresh(only selected: AIProvider? = nil, allowKeychainPrompt: Bool = false) {
        guard enabled else { return }
        for key in AIProvider.allCases where selected == nil || selected == key {
            guard tasks[key] == nil else { continue }
            if case .rateLimited(let retryAt) = states[key]?.error, let retryAt, retryAt > Date() { continue }
            var state = state(for: key)
            state.isRefreshing = true
            states[key] = state
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await provider.fetch(key, allowKeychainPrompt: allowKeychainPrompt && key == .claude)
                    guard !Task.isCancelled else { return }
                    states[key] = AIProviderState(snapshot: snapshot)
                } catch {
                    guard !Task.isCancelled else { return }
                    let failure = error as? AIUsageError ?? .unavailable
                    var state = self.state(for: key)
                    state.isRefreshing = false
                    state.error = failure
                    if failure.clearsSnapshot { state.snapshot = nil }
                    states[key] = state
                }
                tasks[key] = nil
            }
        }
    }
}
