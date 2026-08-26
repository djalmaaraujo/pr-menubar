import Foundation

// Standalone assertions over the pure logic in PRCore.swift. Compiled and run
// by test.sh:  swiftc -parse-as-library PRCore.swift Tests.swift -o build/prbar-tests

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

func fixture(_ name: String) -> Data {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = dir.appendingPathComponent("fixtures/\(name)")
    return (try? Data(contentsOf: url)) ?? Data()
}

func pr(_ n: Int, repo: String, head: String, base: String,
        draft: Bool = false, review: String = "", ci: CIState = .none) -> PullRequest {
    PullRequest(number: n, title: "PR \(n)", repo: repo, url: "u", isDraft: draft,
                reviewDecision: review, headRefName: head, baseRefName: base, ci: ci)
}

@main
struct Tests {
    static func main() {
        rollupTests()
        rowStateTests()
        mergeOwnersTests()
        stackTests()
        decodeTests()
        coordinatorTests()

        print("")
        if failures == 0 {
            print("All tests passed.")
            exit(0)
        } else {
            print("\(failures) test(s) failed.")
            exit(1)
        }
    }

    static func rollupTests() {
        print("rollupState:")
        check(rollupState(from: []) == .none, "empty -> none")
        check(rollupState(from: [CheckContext(status: "COMPLETED", conclusion: "SUCCESS", state: nil)]) == .success, "single success -> success")
        check(rollupState(from: [
            CheckContext(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
            CheckContext(status: "COMPLETED", conclusion: "FAILURE", state: nil),
        ]) == .failure, "any failure -> failure")
        check(rollupState(from: [
            CheckContext(status: "COMPLETED", conclusion: "SUCCESS", state: nil),
            CheckContext(status: "IN_PROGRESS", conclusion: nil, state: nil),
        ]) == .pending, "running with no failure -> pending")
        check(rollupState(from: [CheckContext(status: nil, conclusion: nil, state: "PENDING")]) == .pending, "legacy PENDING state -> pending")
        check(rollupState(from: [CheckContext(status: nil, conclusion: nil, state: "ERROR")]) == .failure, "legacy ERROR state -> failure")
        check(rollupState(from: [CheckContext(status: "COMPLETED", conclusion: "TIMED_OUT", state: nil)]) == .failure, "timed_out -> failure")
        check(rollupState(from: [CheckContext(status: "COMPLETED", conclusion: "SKIPPED", state: nil)]) == .none, "only skipped -> none")
    }

    static func rowStateTests() {
        print("rowState:")
        check(pr(1, repo: "a/b", head: "h", base: "main", draft: true).rowState == .draft, "draft wins")
        check(pr(1, repo: "a/b", head: "h", base: "main", review: "APPROVED").rowState == .approved, "approved")
        check(pr(1, repo: "a/b", head: "h", base: "main", review: "CHANGES_REQUESTED").rowState == .changesRequested, "changes requested")
        check(pr(1, repo: "a/b", head: "h", base: "main").rowState == .open, "default open")
        check(pr(1, repo: "a/b", head: "h", base: "main", draft: true, review: "APPROVED").rowState == .draft, "draft beats approved")
    }

    static func mergeOwnersTests() {
        print("mergeOwners:")
        let owners = mergeOwners(orgs: ["Zorg", "acme"], resultOwners: ["99Drive", "acme"], myLogin: "djalma")
        check(owners.first == allOwnersSentinel, "All pinned first")
        check(owners.contains("99Drive"), "private-membership owner recovered from results")
        check(owners.contains("djalma"), "own login included")
        check(Set(owners).count == owners.count, "deduped")
        check(owners == [allOwnersSentinel] + ["99Drive", "acme", "djalma", "Zorg"], "case-insensitive sort")
        check(mergeOwners(orgs: [], resultOwners: [""], myLogin: nil) == [allOwnersSentinel], "empties dropped")
    }

    static func stackTests() {
        print("buildStackForest:")
        let prs = [
            pr(12, repo: "acme/web", head: "c", base: "b"),   // top
            pr(10, repo: "acme/web", head: "a", base: "main"), // root
            pr(11, repo: "acme/web", head: "b", base: "a"),   // middle
            pr(5, repo: "solo/x", head: "fix", base: "main"), // separate repo root
        ]
        let forest = buildStackForest(prs)
        let acme = forest.filter { $0.pr.repo == "acme/web" }
        check(acme.map { $0.pr.number } == [10, 11, 12], "chain ordered root->top")
        check(acme.map { $0.depth } == [0, 1, 2], "depth increases down the stack")
        let solo = forest.filter { $0.pr.repo == "solo/x" }
        check(solo.count == 1 && solo[0].depth == 0, "unrelated repo PR is its own root")

        // Cycle guard: two PRs based on each other must still both appear.
        let cyclic = [
            pr(1, repo: "r/r", head: "x", base: "y"),
            pr(2, repo: "r/r", head: "y", base: "x"),
        ]
        check(buildStackForest(cyclic).count == 2, "cycle does not drop or hang")
    }

    static func coordinatorTests() {
        print("RefreshCoordinator:")
        var c = RefreshCoordinator()
        let g1 = c.begin()
        check(c.mayApply(g1), "sole in-flight refresh may apply")

        // Reproduces the reported bug: an owner switch starts a newer refresh
        // while the first (e.g. the launch load of "All") is still awaiting gh.
        let g2 = c.begin()
        check(!c.mayApply(g1), "superseded refresh may NOT apply (no stale overwrite)")
        check(c.mayApply(g2), "newest refresh may apply")

        // A third supersedes the second in turn.
        let g3 = c.begin()
        check(!c.mayApply(g2), "older-but-not-oldest also blocked")
        check(c.mayApply(g3), "latest wins")
    }

    static func decodeTests() {
        print("decode:")
        let search = (try? decodeSearchPRs(fixture("search.json"))) ?? []
        check(search.count == 4, "search.json decodes 4")
        check(search.first?.repository.nameWithOwner == "acme/web", "nameWithOwner decoded")

        if let d = try? decodePRDetail(fixture("pr_success.json")) {
            check(rollupState(from: d.statusCheckRollup ?? []) == .success, "pr_success -> success")
            check(d.reviewDecision == "APPROVED", "reviewDecision decoded")
        } else { check(false, "pr_success.json decodes") }

        if let d = try? decodePRDetail(fixture("pr_failure.json")) {
            check(rollupState(from: d.statusCheckRollup ?? []) == .failure, "pr_failure -> failure")
        } else { check(false, "pr_failure.json decodes") }

        if let d = try? decodePRDetail(fixture("pr_pending.json")) {
            check(rollupState(from: d.statusCheckRollup ?? []) == .pending, "pr_pending -> pending")
            check(d.reviewDecision == nil, "null reviewDecision -> nil")
        } else { check(false, "pr_pending.json decodes") }
    }
}
