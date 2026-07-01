import Foundation

/// Fetch planning and repository-permission resolution for the CI/gate hydration wave.
/// Split out of `AppStore` (the wave itself lives in `AppStore.swift`) to keep that file
/// focused; these helpers only touch hydration-internal state (`repoCanMerge`).
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

    /// Cache key for `repoCanMerge` — the viewer's push access is per account **and** repo.
    func repoPermissionKey(accountID: Account.ID, slug: String) -> String {
        "\(accountID)\n\(slug)"
    }

    /// Fetch push access for any `(account, repo)` in `prs` not already cached, and fold the
    /// results into `repoCanMerge`. Best-effort: a failed fetch leaves the key absent, so the
    /// gate treats that repo's merge permission as unknown (optimistic). Guards `generation`
    /// so a superseded wave can't write stale permissions.
    func hydrateRepoPermissions(prs: [PRFetch], generation: Int) async {
        var seen = Set<String>()
        let missing = prs.compactMap { pr -> (key: String, slug: String, api: GitHubAPI)? in
            let cacheKey = repoPermissionKey(accountID: pr.key.accountID, slug: pr.issue.repositorySlug)
            guard repoCanMerge[cacheKey] == nil, seen.insert(cacheKey).inserted else { return nil }
            return (cacheKey, pr.issue.repositorySlug, pr.api)
        }
        guard !missing.isEmpty else { return }
        let fetched = await withTaskGroup(of: (String, Bool?).self) { group -> [String: Bool] in
            var next = 0
            func schedule() {
                guard next < missing.count else { return }
                let repo = missing[next]
                next += 1
                group.addTask {
                    guard let info = try? await repo.api.repository(repo: repo.slug) else { return (repo.key, nil) }
                    let perms = info.permissions
                    let canMerge = (perms?.push ?? false) || (perms?.maintain ?? false) || (perms?.admin ?? false)
                    return (repo.key, canMerge)
                }
            }
            for _ in 0..<Self.checksConcurrency {
                schedule()
            }
            var result: [String: Bool] = [:]
            while let (key, canMerge) = await group.next() {
                if let canMerge { result[key] = canMerge }
                schedule()
            }
            return result
        }
        guard checksGeneration == generation else { return }
        repoCanMerge.merge(fetched) { _, new in new }
    }

    /// Snapshot the resolved merge permission for each PR from `repoCanMerge` (main-actor
    /// state) into a per-key map the off-actor fetch tasks can read without a hop.
    func mergePermissions(for prs: [PRFetch]) -> [PRCheckKey: Bool] {
        var result: [PRCheckKey: Bool] = [:]
        for pr in prs {
            let cacheKey = repoPermissionKey(accountID: pr.key.accountID, slug: pr.issue.repositorySlug)
            result[pr.key] = repoCanMerge[cacheKey]
        }
        return result
    }
}
