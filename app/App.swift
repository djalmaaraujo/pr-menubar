import SwiftUI
import AppKit

// Model + pure logic live in PRCore.swift (Foundation-only, shared with the
// test binary). These extensions add the UI-only concerns.

extension CIState {
    var glyph: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        case .none: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        case .pending: return Color(red: 0.98, green: 0.75, blue: 0.18) // amber
        case .none: return .secondary
        }
    }

    var help: String {
        switch self {
        case .success: return "Checks passing"
        case .failure: return "Checks failing"
        case .pending: return "Checks running"
        case .none: return "No checks"
        }
    }
}

extension RowState {
    var color: Color {
        switch self {
        case .draft: return .secondary
        case .changesRequested: return Color(red: 0.90, green: 0.29, blue: 0.36)
        case .approved: return .green
        case .open: return Color(red: 0.39, green: 0.40, blue: 0.95) // indigo #6366f1
        }
    }
}

// MARK: - gh runner

enum GHError: LocalizedError {
    case notFound
    case notAuthenticated
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "GitHub CLI not found. Install it with `brew install gh`."
        case .notAuthenticated: return "Not logged in. Run `gh auth login` in a terminal."
        case .failed(let m): return m
        }
    }
}

enum GH {
    static let knownPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static func resolvePath() -> String? {
        if let p = knownPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return p
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v gh"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func run(_ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let ghPath = resolvePath() else {
                    cont.resume(throwing: GHError.notFound); return
                }
                var env = ProcessInfo.processInfo.environment
                let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
                env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ghPath)
                process.arguments = args
                process.environment = env
                process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                        if process.isRunning { process.terminate() }
                    }
                    // Drain before waiting: a full pipe buffer would otherwise
                    // deadlock the child against us.
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let msg = String(data: errData, encoding: .utf8) ?? ""
                        if msg.lowercased().contains("auth") || msg.lowercased().contains("logged in") || msg.lowercased().contains("gh auth login") {
                            cont.resume(throwing: GHError.notAuthenticated)
                        } else {
                            cont.resume(throwing: GHError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gh exited with code \(process.terminationStatus)" : String(msg.prefix(200))))
                        }
                        return
                    }
                    cont.resume(returning: data)
                } catch {
                    cont.resume(throwing: GHError.notFound)
                }
            }
        }
    }
}

// MARK: - Store

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PullRequest] = []
    @Published var owners: [String] = [allOwnersSentinel]
    @Published var selectedOwner: String = UserDefaults.standard.string(forKey: "selectedOwner") ?? allOwnersSentinel
    @Published var errorText: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    private var myLogin: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func select(_ owner: String) {
        selectedOwner = owner
        UserDefaults.standard.set(owner, forKey: "selectedOwner")
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            do {
                if myLogin == nil {
                    myLogin = try? await Self.fetchLogin()
                }
                let search = try await Self.search(owner: selectedOwner)
                let details = try await Self.enrich(search)

                let resultOwners = search.map { $0.repository.nameWithOwner.split(separator: "/").first.map(String.init) ?? "" }
                let orgs = (try? await Self.fetchOrgs()) ?? []
                self.owners = mergeOwners(orgs: orgs, resultOwners: resultOwners, myLogin: myLogin)
                self.prs = details
                self.errorText = nil
                self.lastUpdated = Date()
            } catch {
                self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isLoading = false
        }
    }

    var forest: [(pr: PullRequest, depth: Int)] { buildStackForest(prs) }
    var openCount: Int { prs.count }

    // MARK: gh calls

    static func fetchLogin() async throws -> String {
        let data = try await GH.run(["api", "user", "--jq", ".login"])
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func fetchOrgs() async throws -> [String] {
        let data = try await GH.run(["api", "user/orgs", "--jq", ".[].login"])
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func search(owner: String) async throws -> [SearchPR] {
        var args = ["search", "prs", "--author=@me", "--state=open", "--limit", "100",
                    "--json", "number,repository,title,isDraft"]
        if owner != allOwnersSentinel {
            args.append("--owner=\(owner)")
        }
        let data = try await GH.run(args)
        return try decodeSearchPRs(data)
    }

    static func enrich(_ search: [SearchPR]) async throws -> [PullRequest] {
        try await withThrowingTaskGroup(of: PullRequest?.self) { group in
            let semaphore = BoundedCounter(limit: 6)
            for s in search {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
                    return try? await detail(for: s)
                }
            }
            var result: [PullRequest] = []
            for try await pr in group { if let pr { result.append(pr) } }
            return result
        }
    }

    static func detail(for s: SearchPR) async throws -> PullRequest {
        let repo = s.repository.nameWithOwner
        let data = try await GH.run(["pr", "view", "\(s.number)", "--repo", repo,
                                     "--json", "number,title,state,url,isDraft,reviewDecision,headRefName,baseRefName,statusCheckRollup"])
        let d = try decodePRDetail(data)
        return PullRequest(
            number: d.number, title: d.title, repo: repo, url: d.url,
            isDraft: d.isDraft, reviewDecision: d.reviewDecision ?? "",
            headRefName: d.headRefName, baseRefName: d.baseRefName,
            ci: rollupState(from: d.statusCheckRollup ?? [])
        )
    }
}

actor BoundedCounter {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if count < limit { count += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        count += 1
    }
    func release() {
        count -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

// MARK: - Views

struct PRRow: View {
    let pr: PullRequest
    let depth: Int

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                if depth > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<depth, id: \.self) { _ in
                            Text("│").foregroundColor(.secondary.opacity(0.4))
                                .frame(width: 10, alignment: .leading)
                        }
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                Circle().fill(pr.rowState.color).frame(width: 7, height: 7)
                    .help(pr.rowState.label)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).lineLimit(1).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Text("#\(pr.number)").foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary)
                        Text(pr.repo).foregroundColor(.secondary).lineLimit(1)
                    }.font(.system(size: 10))
                }
                Spacer(minLength: 4)
                Image(systemName: pr.ci.glyph)
                    .foregroundColor(pr.ci.color)
                    .font(.system(size: 12))
                    .help(pr.ci.help)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @ObservedObject var store: PRStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { store.selectedOwner },
                set: { store.select($0) }
            )) {
                ForEach(store.owners, id: \.self) { owner in
                    Text(owner == allOwnersSentinel ? "All orgs" : owner).tag(owner)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let err = store.errorText {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundColor(.orange)
                Text(err).font(.system(size: 12)).multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { store.refresh() }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        } else if store.prs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.title).foregroundColor(.secondary)
                Text(store.isLoading ? "Loading…" : "No open pull requests")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.forest, id: \.pr.id) { item in
                        PRRow(pr: item.pr, depth: item.depth)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
    }

    private var footer: some View {
        HStack {
            if let t = store.lastUpdated {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
    }
}

// MARK: - Menu bar icon

let menuBarIconHeight: CGFloat = 16

// Size the mark to a fixed menu-bar height, keeping its natural aspect ratio so
// a tall/narrow glyph isn't squashed. No .resizable()/.frame() on the Image in
// the label — MenuBarExtra needs an intrinsic size before its own layout pass,
// so we set NSImage.size directly instead.
func loadMenuBarImage() -> NSImage {
    guard let url = Bundle.main.url(forResource: "menubar-mark", withExtension: "png"),
          let image = NSImage(contentsOf: url), image.size.height > 0 else {
        let img = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "PR")
            ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: menuBarIconHeight, height: menuBarIconHeight)
        return img
    }
    let aspect = image.size.width / image.size.height
    image.isTemplate = true
    image.size = NSSize(width: menuBarIconHeight * aspect, height: menuBarIconHeight)
    return image
}

let menuBarMark = loadMenuBarImage()

@main
struct PRBarApp: App {
    @StateObject private var store = PRStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 2) {
                if store.errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    Image(nsImage: menuBarMark)
                }
                if store.errorText == nil && store.openCount > 0 {
                    Text("\(store.openCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
