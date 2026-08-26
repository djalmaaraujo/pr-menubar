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
                    // Drain both pipes concurrently before waiting: reading one
                    // to EOF and only then the other would deadlock if the child
                    // fills the second pipe's buffer while blocked, since its EOF
                    // never comes until it exits.
                    var errData = Data()
                    let errHandle = err.fileHandleForReading
                    let drain = DispatchGroup()
                    drain.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData = errHandle.readDataToEndOfFile()
                        drain.leave()
                    }
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    drain.wait()
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
    @Published var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favoriteOwners") ?? []
    @Published var errorText: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    // Owners as shown in the dropdown: All, then favorites, then the rest.
    var orderedOwners: [String] { orderOwners(owners, favorites: favorites) }

    func isFavorite(_ owner: String) -> Bool { favorites.contains(owner) }

    func toggleFavorite(_ owner: String) {
        guard owner != allOwnersSentinel, !owner.isEmpty else { return }
        if let i = favorites.firstIndex(of: owner) {
            favorites.remove(at: i)
        } else {
            favorites.append(owner)
        }
        UserDefaults.standard.set(favorites, forKey: "favoriteOwners")
    }

    private var myLogin: String?
    private var timer: Timer?
    // Every refresh gets a generation number; only the newest one is allowed to
    // mutate state. This makes switching owners cancel-and-supersede an in-flight
    // load instead of being dropped by it (or being clobbered when it lands).
    private var coordinator = RefreshCoordinator()
    private var refreshTask: Task<Void, Never>?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
    }

    // Last-seen results per owner. Switching shows the cached list instantly and
    // refreshes on top of it, so you never fall back to a blank loading screen
    // for an org you've already looked at this session.
    private var cache: [String: [PullRequest]] = [:]

    func select(_ owner: String) {
        guard owner != selectedOwner else { return }
        selectedOwner = owner
        UserDefaults.standard.set(owner, forKey: "selectedOwner")
        errorText = nil
        // Show what we last saw for this owner (if anything) while the fresh
        // load runs; otherwise keep the current list rather than blanking.
        if let cached = cache[owner] { prs = cached }
        refresh()
    }

    func refresh() {
        let gen = coordinator.begin()
        let owner = selectedOwner
        refreshTask?.cancel()
        isLoading = true
        refreshTask = Task {
            do {
                if myLogin == nil {
                    myLogin = try? await Self.fetchLogin()
                }
                let search = try await Self.search(owner: owner)
                let details = try await Self.enrich(search)

                self.cache[owner] = details
                // A newer refresh started while we were awaiting — let it win.
                guard coordinator.mayApply(gen) else { return }

                let resultOwners = search.map { $0.repository.nameWithOwner.split(separator: "/").first.map(String.init) ?? "" }
                let orgs = (try? await Self.fetchOrgs()) ?? []
                guard coordinator.mayApply(gen) else { return }

                self.owners = mergeOwners(orgs: orgs, resultOwners: resultOwners, myLogin: myLogin)
                self.prs = details
                self.errorText = nil
                self.lastUpdated = Date()
            } catch {
                guard coordinator.mayApply(gen) else { return }
                // Keep the cached list on screen; only surface the error if we
                // have nothing to show for this owner.
                if prs.isEmpty {
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            if coordinator.mayApply(gen) { self.isLoading = false }
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
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 11) {
                if depth > 0 { indent }

                Circle().fill(pr.rowState.color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(pr.rowState.color.opacity(0.25), lineWidth: 3))
                    .help(pr.rowState.label)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)")
                            .monospacedDigit()
                            .foregroundColor(pr.ci.color.opacity(0.9))
                        Text(pr.repo)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                }

                Spacer(minLength: 6)

                Image(systemName: pr.ci.glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(pr.ci.color)
                    .frame(width: 24, height: 24)
                    .background(pr.ci.color.opacity(0.12))
                    .clipShape(Circle())
                    .help(pr.ci.help)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }

    private var indent: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle().fill(Color.secondary.opacity(0.25))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .frame(width: 13, alignment: .center)
            }
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ContentView: View {
    @ObservedObject var store: PRStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 0.39, green: 0.40, blue: 0.95))
            Text("Pull Requests")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            if store.openCount > 0 {
                Text(verbatim: "\(store.openCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var canFavorite: Bool { store.selectedOwner != allOwnersSentinel }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { store.selectedOwner },
                set: { store.select($0) }
            )) {
                ForEach(store.orderedOwners, id: \.self) { owner in
                    Text(label(for: owner)).tag(owner)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)

            Button {
                store.toggleFavorite(store.selectedOwner)
            } label: {
                Image(systemName: store.isFavorite(store.selectedOwner) ? "star.fill" : "star")
                    .foregroundColor(store.isFavorite(store.selectedOwner) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canFavorite)
            .opacity(canFavorite ? 1 : 0.35)
            .help(store.isFavorite(store.selectedOwner) ? "Unfavorite" : "Favorite — pins it to the top")

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

    private func label(for owner: String) -> String {
        if owner == allOwnersSentinel { return "All orgs" }
        return store.isFavorite(owner) ? "★ \(owner)" : owner
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
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.forest, id: \.pr.id) { item in
                        PRRow(pr: item.pr, depth: item.depth)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 440)
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
                    Text(verbatim: "\(store.openCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
