import Foundation

/// The per-repo feeds — GitHub Actions workflow runs and Releases — hydrated over the curated
/// `watchlist`. Split out of `AppStore` like `AppStoreHydration`; this wave owns `actionRuns`,
/// `releases`, and the `repoFeedsTask`/`repoFeedsGeneration` staleness pair, and mirrors the
/// best-effort, capped-concurrency, generation-guarded shape of `hydrateChecks`.
extension AppStore {
    // MARK: View-facing projections (account-filtered)

    /// Actions runs scoped to the active account filter.
    var visibleActionRuns: [AccountActionRun] {
        guard let filter = accountFilter else { return actionRuns }
        return actionRuns.filter { $0.account.id == filter }
    }

    /// Releases scoped to the active account filter.
    var visibleReleases: [AccountRelease] {
        guard let filter = accountFilter else { return releases }
        return releases.filter { $0.account.id == filter }
    }

    /// The Actions tab badge: runs that need attention — failing or still running (filtered).
    /// The tab stays quiet (`nil`) when everything's green, matching the actionable-count spirit
    /// of the PR badge rather than showing a raw run total.
    var actionRunsAttentionCount: Int {
        visibleActionRuns.count { $0.run.ciStatus == .failure || $0.run.ciStatus == .pending }
    }

    /// Whether a watched repo's account has also starred it (case-insensitive) — lets the
    /// "Starred" chip narrow the Actions/Releases tabs the same way it narrows the others.
    func isStarred(_ item: AccountActionRun) -> Bool {
        starredByAccount[item.account.id]?.contains(item.repo.lowercased()) ?? false
    }

    func isStarred(_ item: AccountRelease) -> Bool {
        starredByAccount[item.account.id]?.contains(item.repo.lowercased()) ?? false
    }

    // MARK: Watchlist mutators

    /// Append a blank watchlist slot for the user to fill in with an `owner/name`.
    func addWatchRepo() {
        watchlist.append("")
    }

    func deleteWatchRepo(at offsets: IndexSet) {
        watchlist.remove(atOffsets: offsets)
    }

    func moveWatchRepo(from source: IndexSet, to destination: Int) {
        watchlist.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Starred merge

    /// Fold each account's starred slugs into `starredByAccount` (lowercased). A failed fetch
    /// (`starredSucceeded == false`) leaves the account's prior set untouched, so a transient
    /// error can't drop the star marks / Starred filter for a poll.
    func mergeStarred(_ loads: [Account.ID: AccountLoad]) {
        for account in accounts {
            guard let load = loads[account.id], load.starredSucceeded else { continue }
            starredByAccount[account.id] = Set(load.starred.map { $0.lowercased() })
        }
    }

    // MARK: Repo-feed hydration

    /// One watched repo resolved to the account (and its client) that will fetch it.
    struct RepoRef {
        let account: Account
        let slug: String
        let api: GitHubAPI
    }

    /// Max total `(account, repo)` fetches per wave — a hard ceiling on the request fan-out so a
    /// long watchlist (× several accounts) can't blow the rate limit. Each ref costs two requests
    /// (runs + releases).
    static let reposScanCap = 24
    /// How many rows each feed keeps after merging across repos — the tabs are a recency digest,
    /// not an archive.
    static let actionRunsDisplayCap = 100
    static let releasesDisplayCap = 50

    /// Resolve the watchlist into concrete fetch targets. Each slug is paired with **every**
    /// signed-in account's client (a watched repo might only be visible to one of them; misses
    /// 404 and drop out best-effort), deduped by `(accountID, slug)` and total-capped at
    /// `reposScanCap`. Blank/malformed slugs (not exactly `owner/name`) are skipped.
    func watchedRepoRefs(apis: [Account.ID: GitHubAPI]) -> [RepoRef] {
        var seen = Set<String>()
        var refs: [RepoRef] = []
        for raw in watchlist {
            let slug = Self.normalizedSlug(raw)
            guard let slug else { continue }
            for account in accounts {
                guard let api = apis[account.id] else { continue }
                guard seen.insert("\(account.id)\n\(slug.lowercased())").inserted else { continue }
                refs.append(RepoRef(account: account, slug: slug, api: api))
                if refs.count == Self.reposScanCap {
                    Log.store.info("watchlist scan capped at \(Self.reposScanCap, privacy: .public) repos")
                    return refs
                }
            }
        }
        return refs
    }

    /// Trim a watchlist entry and validate it as an `owner/name` slug, returning nil for blank or
    /// malformed input (empty parts, missing or extra `/`). Keeps the original case — GitHub repo
    /// paths are case-insensitive on fetch, and the display should reflect what the user typed.
    static func normalizedSlug(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        // Reject interior whitespace — a stray space means a typo, not a repo path, and would
        // only produce a wasted best-effort 404.
        guard !parts.contains(where: { $0.contains(where: \.isWhitespace) }) else { return nil }
        return trimmed
    }

    /// Best-effort Actions + Releases hydration across the watched repos. Supersedes any prior
    /// wave, then fetches each repo's recent runs and releases with capped concurrency, folding
    /// the results into `actionRuns`/`releases` (sorted newest-first, display-capped). Stale runs
    /// (a superseded `generation`) drop their writes.
    func hydrateRepoFeeds(apis: [Account.ID: GitHubAPI]) {
        repoFeedsTask?.cancel()
        repoFeedsGeneration += 1
        let refs = watchedRepoRefs(apis: apis)
        guard !refs.isEmpty else {
            // Nothing watched (or no usable client): clear the feeds and mark loaded so the tabs
            // show the "add repos" nudge rather than a perpetual skeleton.
            actionRuns = []
            releases = []
            hasLoadedRepoFeeds = true
            repoFeedsTask = nil
            return
        }
        repoFeedsTask = repoFeedsWave(refs: refs, generation: repoFeedsGeneration)
    }

    private func repoFeedsWave(refs: [RepoRef], generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            let collected = await withTaskGroup(
                of: (runs: [AccountActionRun], releases: [AccountRelease]).self
            ) { group -> (runs: [AccountActionRun], releases: [AccountRelease]) in
                var next = 0
                func schedule() {
                    guard next < refs.count else { return }
                    let ref = refs[next]
                    next += 1
                    group.addTask { await Self.fetchRepoFeed(ref) }
                }
                for _ in 0..<Self.checksConcurrency {
                    schedule()
                }
                var runs: [AccountActionRun] = []
                var rels: [AccountRelease] = []
                while let part = await group.next() {
                    runs.append(contentsOf: part.runs)
                    rels.append(contentsOf: part.releases)
                    schedule()
                }
                return (runs, rels)
            }
            guard let self, self.repoFeedsGeneration == generation, !Task.isCancelled else { return }
            self.actionRuns = collected.runs
                .sorted { $0.run.updatedAt > $1.run.updatedAt }
                .prefix(Self.actionRunsDisplayCap)
                .map(\.self)
            self.releases = collected.releases
                .sorted { $0.release.sortDate > $1.release.sortDate }
                .prefix(Self.releasesDisplayCap)
                .map(\.self)
            self.hasLoadedRepoFeeds = true
            self.repoFeedsTask = nil
        }
    }

    /// Fetch one repo's runs and releases concurrently, tagging each with its account + slug.
    /// Best-effort: a failed endpoint yields an empty list for that feed (a repo an account can't
    /// see just contributes nothing), never an error.
    private nonisolated static func fetchRepoFeed(
        _ ref: RepoRef
    ) async
    -> (runs: [AccountActionRun], releases: [AccountRelease]) {
        async let runsResult = try? ref.api.workflowRuns(repo: ref.slug)
        async let releasesResult = try? ref.api.releases(repo: ref.slug)
        let runs = await (runsResult ?? []).map { AccountActionRun(account: ref.account, repo: ref.slug, run: $0) }
        // Drafts have no publish date and read as noise in a "what shipped" digest — drop them.
        let releases = await (releasesResult ?? [])
            .filter { !$0.draft }
            .map { AccountRelease(account: ref.account, repo: ref.slug, release: $0) }
        return (runs, releases)
    }
}

extension Release {
    /// The date the digest sorts on: published time, falling back to creation for the rare
    /// undated release that slips through the draft filter.
    var sortDate: Date {
        publishedAt ?? createdAt
    }
}

#if DEBUG
extension AppStore {
    /// Test hook: await the current repo-feeds wave (if any) to completion.
    func awaitRepoFeedsHydration() async {
        await repoFeedsTask?.value
    }
}
#endif
