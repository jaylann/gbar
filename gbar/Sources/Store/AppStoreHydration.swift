import Foundation

/// Fetch planning, repository-permission resolution, and the CI/gate hydration wave itself.
/// Split out of `AppStore` to keep that file focused; these helpers own hydration-internal
/// state (`repoMergeInfo`, `prChecks`, `prGates`, `checksTask`/`checksGeneration`).
extension AppStore {
    /// One PR to hydrate: its key, the issue, the owning account's `login` (to spot the
    /// viewer's own approvals) and that account's API client.
    struct PRFetch {
        let key: PRCheckKey
        let issue: SearchIssue
        let login: String
        let api: GitHubAPI
    }

    /// Distinct `(account, PR)` fetches — the same PR can appear in several sections, and each
    /// account has its own client.
    func distinctPRFetches(from sections: [LoadedSection], apis: [Account.ID: GitHubAPI]) -> [PRFetch] {
        var seen = Set<PRCheckKey>()
        return sections
            .flatMap(\.items)
            .filter(\.issue.isPullRequest)
            .compactMap { item in
                let key = PRCheckKey(accountID: item.account.id, prID: item.issue.id)
                guard seen.insert(key).inserted, let api = apis[item.account.id] else { return nil }
                return PRFetch(key: key, issue: item.issue, login: item.account.login, api: api)
            }
    }

    /// Cache key for `repoMergeInfo` — the viewer's merge signals are per account **and** repo.
    func repoPermissionKey(accountID: Account.ID, slug: String) -> String {
        "\(accountID)\n\(slug)"
    }

    /// Re-hydrate a single PR's action gate (+ checks) after a mutation such as an approval, so
    /// the Approve/Merge buttons reflect the new state immediately instead of waiting for the next
    /// poll. Reuses `fetchPRState`/`deriveGate` and the cached repo merge info. Guarded by
    /// `checksGeneration`: if a full hydration wave supersedes (and possibly prunes) this key
    /// while we fetch, we skip the write and let that wave own the state.
    func refreshPRState(for item: AccountItem, using api: GitHubAPI) async {
        let key = PRCheckKey(accountID: item.account.id, prID: item.issue.id)
        let generation = checksGeneration
        let cacheKey = repoPermissionKey(accountID: item.account.id, slug: item.issue.repositorySlug)
        let mergeInfo = repoMergeInfo[cacheKey]
        let state = await Self.fetchPRState(
            for: item.issue, login: item.account.login, mergeInfo: mergeInfo, using: api
        )
        guard checksGeneration == generation else { return }
        prGates[key] = state.gate
        prChecks[key] = state.checks
    }

    /// Fetch the merge signals (push access + allowed strategies) for any `(account, repo)` in
    /// `prs` not already cached, and fold the results into `repoMergeInfo`. Best-effort: a failed
    /// fetch leaves the key absent, so the gate treats that repo's permission as unknown
    /// (optimistic). Guards `generation` so a superseded wave can't write stale info.
    func hydrateRepoPermissions(prs: [PRFetch], generation: Int) async {
        var seen = Set<String>()
        let missing = prs.compactMap { pr -> (key: String, slug: String, api: GitHubAPI)? in
            let cacheKey = repoPermissionKey(accountID: pr.key.accountID, slug: pr.issue.repositorySlug)
            guard repoMergeInfo[cacheKey] == nil, seen.insert(cacheKey).inserted else { return nil }
            return (cacheKey, pr.issue.repositorySlug, pr.api)
        }
        guard !missing.isEmpty else { return }
        let fetched = await withTaskGroup(of: (String, RepoMergeInfo?).self) { group -> [String: RepoMergeInfo] in
            var next = 0
            func schedule() {
                guard next < missing.count else { return }
                let repo = missing[next]
                next += 1
                group.addTask {
                    guard let info = try? await repo.api.repository(repo: repo.slug) else { return (repo.key, nil) }
                    let perms = info.permissions
                    let canMerge = (perms?.push ?? false) || (perms?.maintain ?? false) || (perms?.admin ?? false)
                    return (repo.key, RepoMergeInfo(canMerge: canMerge, allowedMethods: info.allowedMergeMethods))
                }
            }
            for _ in 0..<Self.checksConcurrency {
                schedule()
            }
            var result: [String: RepoMergeInfo] = [:]
            while let (key, info) = await group.next() {
                if let info { result[key] = info }
                schedule()
            }
            return result
        }
        guard checksGeneration == generation else { return }
        repoMergeInfo.merge(fetched) { _, new in new }
    }

    /// Snapshot the resolved merge info for each PR from `repoMergeInfo` (main-actor state) into
    /// a per-key map the off-actor fetch tasks can read without a hop.
    func mergePermissions(for prs: [PRFetch]) -> [PRCheckKey: RepoMergeInfo] {
        var result: [PRCheckKey: RepoMergeInfo] = [:]
        for pr in prs {
            let cacheKey = repoPermissionKey(accountID: pr.key.accountID, slug: pr.issue.repositorySlug)
            result[pr.key] = repoMergeInfo[cacheKey]
        }
        return result
    }

    /// Best-effort CI hydration across accounts: for every distinct PR (keyed per account),
    /// fetch its detail then its check runs using that account's client, roll them up, and
    /// stash the result in `prChecks`. Runs in a detached, non-blocking task with a capped
    /// `TaskGroup`; failures are swallowed. Stale runs are dropped via `checksGeneration`.
    func hydrateChecks(for sections: [LoadedSection], apis: [Account.ID: GitHubAPI]) {
        // Supersede any previous wave so it stops firing requests and can't clobber this one.
        checksTask?.cancel()
        checksGeneration += 1
        let prs = distinctPRFetches(from: sections, apis: apis)
        // Prune entries for PRs no longer in the list so a dropped-out PR's stale CI dot can't
        // linger (and `prChecks` can't grow unbounded). Prune the notification baseline the same
        // way so a PR that leaves every section doesn't retain a stale `lastCheckStatus` (bug #5).
        // A PR still in the list but whose fetch fails keeps its key here (it's in `prs`), so its
        // baseline survives — that's what protects bug #3.
        let live = Set(prs.map(\.key))
        prChecks = prChecks.filter { live.contains($0.key) }
        prGates = prGates.filter { live.contains($0.key) }
        lastCheckStatus = lastCheckStatus.filter { live.contains($0.key) }
        guard !prs.isEmpty else {
            checksTask = nil
            return
        }
        checksTask = checksWave(prs: prs, generation: checksGeneration)
    }

    /// The capped-concurrency hydration wave. Stale runs (a superseded `generation`) drop their
    /// writes.
    private func checksWave(prs: [PRFetch], generation: Int) -> Task<Void, Never> {
        // Carry each PR alongside its key so the completion step can build a CI banner.
        let issueByKey = Dictionary(uniqueKeysWithValues: prs.map { ($0.key, $0.issue) })
        return Task { [weak self] in
            // Resolve per-repo merge info first so each PR's gate knows it up front.
            await self?.hydrateRepoPermissions(prs: prs, generation: generation)
            let mergeInfoByKey = self?.mergePermissions(for: prs) ?? [:]
            await self?.drainChecks(
                prs: prs, mergeInfoByKey: mergeInfoByKey, issueByKey: issueByKey, generation: generation
            )
        }
    }

    /// Run the capped-concurrency detail+check-runs fetch for `prs`, folding each result into
    /// working copies of the hydration maps and publishing them in batches. The fetches run
    /// off-actor; the folds and whole-map publishes happen here on the main actor.
    ///
    /// Publishing in batches is deliberate: every write to `prChecks`/`prGates` invalidates every
    /// view that reads them, so writing 50 PRs one at a time triggers 50 render passes during the
    /// post-open wave — the dominant menu jank. Reassigning the whole map once per batch collapses
    /// each batch into a single invalidation while still revealing CI state progressively.
    private func drainChecks(
        prs: [PRFetch],
        mergeInfoByKey: [PRCheckKey: RepoMergeInfo],
        issueByKey: [PRCheckKey: SearchIssue],
        generation: Int
    ) async {
        await withTaskGroup(of: (PRCheckKey, PRState).self) { group in
            var next = 0
            func schedule() {
                guard next < prs.count else { return }
                let pr = prs[next]
                next += 1
                let mergeInfo = mergeInfoByKey[pr.key]
                group.addTask {
                    await (
                        pr.key,
                        Self.fetchPRState(for: pr.issue, login: pr.login, mergeInfo: mergeInfo, using: pr.api)
                    )
                }
            }
            for _ in 0..<Self.checksConcurrency {
                schedule()
            }
            // Seed from the (already pruned) live maps so absent keys stay absent.
            var pendingChecks = prChecks
            var pendingGates = prGates
            var sinceFlush = 0
            while let (key, state) = await group.next() {
                guard checksGeneration == generation else { continue }
                fold(key: key, state: state, issueByKey: issueByKey, checks: &pendingChecks, gates: &pendingGates)
                sinceFlush += 1
                if sinceFlush >= Self.checksFlushBatch {
                    publishChecks(pendingChecks, gates: pendingGates, generation: generation)
                    sinceFlush = 0
                }
                schedule()
            }
            if sinceFlush > 0 {
                publishChecks(pendingChecks, gates: pendingGates, generation: generation)
            }
        }
    }

    /// Fold one completed PR's resolved state into the pending hydration maps, firing a pass/fail
    /// banner on a real check observation. A `nil` checks result clears the decorative dot but
    /// leaves `lastCheckStatus` untouched, so a transient fetch error can't swallow the next real
    /// pass→fail transition (bug #3).
    private func fold(
        key: PRCheckKey,
        state: PRState,
        issueByKey: [PRCheckKey: SearchIssue],
        checks: inout [PRCheckKey: PRChecks],
        gates: inout [PRCheckKey: PRGate]
    ) {
        gates[key] = state.gate
        if let resolved = state.checks {
            if let issue = issueByKey[key] {
                notifyCheckStatusChange(key: key, pr: issue, newStatus: resolved.status)
            }
            checks[key] = resolved
        } else {
            checks[key] = nil
        }
    }

    /// Publish a hydration batch as single whole-map assignments (one view invalidation each),
    /// unless a newer wave has superseded this one.
    private func publishChecks(_ checks: [PRCheckKey: PRChecks], gates: [PRCheckKey: PRGate], generation: Int) {
        guard checksGeneration == generation else { return }
        prGates = gates
        prChecks = checks
    }
}
