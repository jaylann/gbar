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
            let mergeInfoByKey = await self?.mergePermissions(for: prs) ?? [:]
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
                while let (key, state) = await group.next() {
                    guard let self, self.checksGeneration == generation else { continue }
                    self.prGates[key] = state.gate
                    if let checks = state.checks {
                        // A real observation: diff for a pass/fail banner, then store the result.
                        if let issue = issueByKey[key] {
                            self.notifyCheckStatusChange(key: key, pr: issue, newStatus: checks.status)
                        }
                        self.prChecks[key] = checks
                    } else {
                        // No checks or a failed fetch: clear the decorative dot so a stale green
                        // can't survive, but leave `lastCheckStatus` untouched — wiping it would
                        // let a transient error swallow the next real pass→fail transition (bug #3).
                        self.prChecks[key] = nil
                    }
                    schedule()
                }
            }
        }
    }
}
