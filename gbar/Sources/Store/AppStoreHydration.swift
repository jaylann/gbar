import Foundation

/// Fetch planning, repository-permission resolution, and the CI/gate hydration wave itself.
/// Split out of `AppStore` to keep that file focused; these helpers own hydration-internal
/// state (`repoMergeInfo`, `prChecks`, `prGates`, `checksTask`/`checksGeneration`).
extension AppStore {
    /// Backoff schedule for the background post-approve merge-readiness poll. GitHub recomputes a
    /// PR's `mergeable_state` asynchronously after an approval re-evaluates branch protection, so
    /// the first refetch still reads the stale `"blocked"` and Merge would stay hidden. We refetch
    /// on these delays until the gate reports mergeable (or the schedule is exhausted) — capped
    /// backoff, ~18s total. It runs off the approve call's path (see `startMergeReadinessPoll`), so
    /// a generous window costs the user nothing: the composer has already closed.
    static let approveRefreshRetryDelays: [Duration] = [
        .milliseconds(800), .milliseconds(1200), .milliseconds(1800), .milliseconds(2500),
        .seconds(3), .seconds(4), .seconds(5),
    ]

    /// One PR to hydrate: its key, the issue, the owning account's `login` (to spot the
    /// viewer's own approvals) and that account's API client.
    struct PRFetch {
        let key: PRCheckKey
        let issue: SearchIssue
        let login: String
        let api: GitHubAPI
    }

    /// A PR's state at its last successful hydration, so the next wave can cheaply refresh it.
    struct HydrationMark {
        /// The search `updated_at` we hydrated against. GitHub bumps it on a push/comment/label/
        /// review, so an equal value means the gate we derived (and the reviews behind it) are
        /// still current — the detail+reviews refetch can be skipped.
        let updatedAt: Date
        /// The head (sha + ref) we hydrated. Lets an unchanged poll re-read check-runs against the
        /// same commit without re-fetching the detail (CI can still flip on a re-run).
        let head: PullRequestDetail.Head
    }

    /// The reusable mark for a PR whose gate is still current — we hold a hydrated gate and the
    /// PR's `updated_at` hasn't advanced since that hydration. When present, the wave skips this
    /// PR's detail+reviews refetch and only re-reads its check-runs (see `fetchChecksState`),
    /// turning a 3-request hydration into 1. `nil` (→ full refetch) when never hydrated, no cached
    /// gate, or `updated_at` is missing/changed.
    func reusableMark(for pr: PRFetch) -> HydrationMark? {
        guard let mark = prHydrationMark[pr.key],
              let gate = prGates[pr.key],
              // A shown Merge button must stay truthful: a base-branch advance can flip a PR's
              // `mergeable_state` to behind/dirty *without* bumping its `updated_at`, and a stale
              // "mergeable" gate would 405 on click. So never skip a mergeable PR — re-read its
              // detail (a cheap 304 while genuinely unchanged) to catch that.
              !gate.mergeable,
              let updated = pr.issue.updatedAt,
              mark.updatedAt == updated
        else { return nil }
        return mark
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

    /// Re-hydrate a single PR's action gate after a mutation such as an approval, so the
    /// Approve/Merge buttons reflect the new state immediately instead of waiting for the next
    /// poll. Reuses `fetchPRState`/`deriveGate` and the cached repo merge info, but only the gate:
    /// CI can't have changed on an approval, so we skip the check-runs request and leave
    /// `prChecks` untouched (a re-write would blink the CI dot on a flaky fetch). A failed detail
    /// fetch yields a `nil` gate, which we skip rather than blank a good one, and return the gate
    /// still in place. Guarded by `checksGeneration`: if a full hydration wave supersedes (and
    /// possibly prunes) this key while we fetch, we drop the write and let that wave own the state.
    /// Returns the resulting gate so the caller can decide whether to keep polling.
    @discardableResult
    func refreshPRState(for item: AccountItem, using api: GitHubAPI) async -> PRGate? {
        let key = PRCheckKey(accountID: item.account.id, prID: item.issue.id)
        let generation = checksGeneration
        // Stamp the moment we *issue* the fetch, not when we commit it: a later-issued fetch read a
        // newer server state, so it must win by recency even if an earlier-issued write commits after
        // it. See `gateWriteClock`/`publishChecks` (#84).
        let issueSeq = nextGateWriteSeq()
        let cacheKey = repoPermissionKey(accountID: item.account.id, slug: item.issue.repositorySlug)
        let mergeInfo = repoMergeInfo[cacheKey]
        let state = await Self.fetchPRState(
            for: item.issue, login: item.account.login, mergeInfo: mergeInfo, using: api, includeChecks: false
        )
        guard checksGeneration == generation else { return prGates[key] }
        guard let gate = state.gate else { return prGates[key] } // failed fetch — keep the old gate
        // Defer to a concurrently-issued *newer* write (a wave fetch issued after us) rather than
        // clobber it with our older observation.
        guard issueSeq > (prGateSeq[key] ?? .min) else { return prGates[key] }
        prGates[key] = gate
        prGateSeq[key] = issueSeq
        return gate
    }

    /// Advance and return the next `prGates` write-clock tick.
    func nextGateWriteSeq() -> Int {
        gateWriteClock += 1
        return gateWriteClock
    }

    /// After an approval that didn't immediately unblock Merge, poll the PR's gate in the
    /// background until it reports mergeable (or the backoff schedule is exhausted — the PR is
    /// genuinely still blocked, e.g. by a second required approval or a failing check). GitHub
    /// recomputes `mergeable_state` asynchronously after the approval, so a single refetch reads the
    /// stale `"blocked"`; this converges the Merge button to the truth without re-running the
    /// section search (which would drop the just-approved PR out of a `review-requested:@me`
    /// section before the viewer can merge it in place). Runs as a tracked, cancellable task so it
    /// never blocks the inline approve composer; superseded by the next approval and cancelled on
    /// sign-out.
    func startMergeReadinessPoll(for item: AccountItem, using api: GitHubAPI) {
        mergeReadinessTask?.cancel()
        mergeReadinessTask = Task { [weak self] in
            // Drop our own reference on normal completion so a finished poll doesn't linger
            // (matching `checksTask`/`repoFeedsTask`). If we were cancelled, a newer poll already
            // owns `mergeReadinessTask`, so leave it be.
            defer { if !Task.isCancelled { self?.mergeReadinessTask = nil } }
            for delay in Self.approveRefreshRetryDelays {
                await self?.sleep(delay)
                guard let self, !Task.isCancelled, self.isSignedIn else { return }
                // Stop once the PR has left every section (a full refresh dropped it) — there's no
                // row left to reveal Merge on, and writing its gate would only re-add stale cruft.
                guard self.prSections.contains(where: { $0.items.contains { $0.id == item.id } }) else { return }
                let gate = await self.refreshPRState(for: item, using: api)
                if gate?.mergeable == true { return }
            }
        }
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
        // baseline survives — that's what protects bug #3. The mark is pruned alongside so an
        // unchanged PR that stays in the list keeps its reuse hint.
        pruneHydrationMaps(keepingLive: Set(prs.map(\.key)))
        guard !prs.isEmpty else {
            checksTask = nil
            return
        }
        checksTask = checksWave(prs: prs, generation: checksGeneration)
    }

    /// Prune the per-PR hydration + CI-baseline maps down to `live` — the PR keys still present in
    /// the sections. Shared by the hydration wave (which prunes before fetching) and the
    /// rate-limited skip path (`kickOffHydration`, which prunes without fetching), so a PR that
    /// left every section can't keep a stale CI dot, gate, or `lastCheckStatus` baseline in either
    /// case. A PR still in the list whose fetch later fails keeps its key (it's in `live`), so its
    /// baseline survives — the invariant behind bug #3.
    func pruneHydrationMaps(keepingLive live: Set<PRCheckKey>) {
        prChecks = prChecks.filter { live.contains($0.key) }
        prGates = prGates.filter { live.contains($0.key) }
        prGateSeq = prGateSeq.filter { live.contains($0.key) }
        prHydrationMark = prHydrationMark.filter { live.contains($0.key) }
        lastCheckStatus = lastCheckStatus.filter { live.contains($0.key) }
    }

    /// When rate-limited, do the lightweight bookkeeping the skipped N+1 waves still owe and report
    /// that hydration should be skipped: prune the CI/gate maps to the live PR set (normally
    /// hydrateChecks' job) so a PR that dropped out of every section can't keep a stale dot/gate,
    /// and mark the repo feeds loaded so the Actions/Releases tabs show their empty/nudge state —
    /// not a perpetual skeleton — even when the *first* poll is the one that's rate-limited.
    /// Returns `false` (hydrate normally) when not rate-limited.
    func hydrationSkippedForRateLimit(apis: [Account.ID: GitHubAPI]) -> Bool {
        guard rateLimitedUntil.map({ $0 > Date() }) == true else { return false }
        // Supersede any wave still in flight from the previous poll: its `pending` snapshot predates
        // this prune, so letting it publish would re-add the exact stale keys pruned below (and it
        // would keep burning the rate-limited budget).
        checksTask?.cancel()
        checksGeneration += 1
        pruneHydrationMaps(keepingLive: Set(distinctPRFetches(from: sections, apis: apis).map(\.key)))
        hasLoadedRepoFeeds = true
        return true
    }

    /// The capped-concurrency hydration wave. Stale runs (a superseded `generation`) drop their
    /// writes.
    private func checksWave(prs: [PRFetch], generation: Int) -> Task<Void, Never> {
        // Carry each PR alongside its key so the completion step can build a CI banner.
        let issueByKey = Dictionary(uniqueKeysWithValues: prs.map { ($0.key, $0.issue) })
        return Task { [weak self] in
            guard let self else { return }
            // GraphQL fast path: one batched query per account (detail + reviews + checks + repo
            // merge signals), collapsing the per-PR REST N+1. Any account/PR the batch can't cover
            // drops to the REST path below.
            var restPRs = prs
            if useGraphQLBatch {
                restPRs = await drainBatched(prs: prs, issueByKey: issueByKey, generation: generation)
            }
            guard !restPRs.isEmpty else { return }
            // REST fallback (and the whole path when GraphQL is disabled): resolve per-repo merge
            // info first so each PR's gate knows it up front, then run the per-PR fetch wave.
            await hydrateRepoPermissions(prs: restPRs, generation: generation)
            let mergeInfoByKey = mergePermissions(for: restPRs)
            await drainChecks(
                prs: restPRs, mergeInfoByKey: mergeInfoByKey, issueByKey: issueByKey, generation: generation
            )
        }
    }

    /// GraphQL fast path: issue one `pullRequestBatch` per account, map each returned bundle through
    /// the same `deriveGate`/`ciRollup` logic the REST path uses, and fold the results via the shared
    /// publish path. Returns the PRs that still need REST hydration — those on an account whose batch
    /// threw (a GHE server missing a field, a transport error) or a PR the batch couldn't resolve
    /// (no access). Each bundle's repo merge info is folded into `repoMergeInfo` so a later gate-only
    /// `refreshPRState` after an approval still finds it. Stale runs (a superseded generation) bail.
    private func drainBatched(prs: [PRFetch], issueByKey: [PRCheckKey: SearchIssue], generation: Int) async
        -> [PRFetch]
    {
        var fallback: [PRFetch] = []
        // Seed from the (already pruned) live maps so absent keys stay absent, matching drainChecks.
        var pending = PendingHydration(checks: prChecks, gates: prGates, marks: prHydrationMark)
        for (_, accountPRs) in Dictionary(grouping: prs, by: { $0.key.accountID }) {
            guard let api = accountPRs.first?.api else { continue }
            let refs = accountPRs.map { PRRef(repo: $0.issue.repositorySlug, number: $0.issue.number) }
            // Issue-time write-clock tick per PR — assigned *before* the batch fetch (each bundle
            // carries a full gate), so a batch that observed an older gate loses to a merge-poll
            // write issued after it, matching the REST drain's per-fetch stamping (#84). Ticked on
            // the actor here since the fetch below is the only suspension point.
            let issueSeq = accountPRs.reduce(into: [PRCheckKey: Int]()) { $0[$1.key] = nextGateWriteSeq() }
            guard let bundles = try? await api.pullRequestBatch(refs) else {
                // Whole-account failure → REST fallback for all of its PRs.
                fallback.append(contentsOf: accountPRs)
                continue
            }
            // Superseded while fetching this account's batch → drop without folding (no banners, no
            // `lastCheckStatus` advance) and without fallback; the newer wave owns the state.
            guard checksGeneration == generation else { return [] }
            var didFold = false
            for pr in accountPRs {
                let ref = PRRef(repo: pr.issue.repositorySlug, number: pr.issue.number)
                guard let bundle = bundles[ref] else {
                    fallback.append(pr) // node absent (no access) → try REST for this one
                    continue
                }
                if let mergeInfo = bundle.mergeInfo {
                    repoMergeInfo[repoPermissionKey(accountID: pr.key.accountID, slug: pr.issue.repositorySlug)]
                        = mergeInfo
                }
                let state = Self.state(from: bundle, login: pr.login, repo: pr.issue.repositorySlug)
                let freshSeq = state.gate != nil ? issueSeq[pr.key] : nil
                fold(key: pr.key, state: state, issueByKey: issueByKey, gateIssueSeq: freshSeq, into: &pending)
                didFold = true
            }
            // Publish each account's folds right away — under the same generation those folds (and
            // their CI banners / `lastCheckStatus` advances, fired inside `fold`) committed under.
            // There's no suspension between the guard above and here, so this is atomic per account:
            // a *later* account's batch getting superseded then can't strand this account's already-
            // fired banners with no matching `publishChecks`.
            if didFold { publishChecks(pending, generation: generation) }
        }
        return fallback
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
        // Decide each PR's plan on the actor (reading `prGates`/`prHydrationMark`), so the
        // nonisolated `schedule()` below just spawns from the precomputed list.
        let plans = fetchPlans(for: prs, mergeInfoByKey: mergeInfoByKey)
        // Issue-time write-clock tick per full fetch (a checks-only plan carries the cached gate
        // unchanged, so it never competes). Ticked *before* the fetches run, not when they fold: a
        // full fetch folds only after its slow checks/reviews legs, so a fetch that observed an older
        // gate can commit after a fresher poll write. Comparing issue ticks lets the observation that
        // read newer state win regardless of commit order (#84). Granularity is the whole wave vs. a
        // concurrent poll — the poll either issued before this drain (lower tick) or after (higher) —
        // which is the level the poll-vs-wave decision turns on. (Assigned here on the actor because
        // the group's `schedule()` runs nonisolated and can't tick the main-actor clock.)
        // Note: because the whole wave shares one issue instant, a poll that issues mid-drain beats
        // even a late-queued key whose own network fetch (capped concurrency) read newer state. That
        // residual is narrow and self-heals: the next wave out-ticks the poll, and the poll keeps
        // refetching while `!mergeable`. True per-key issue stamping would need a main-actor hop per
        // fetch, which isn't worth it for a transient, self-correcting gate flip.
        var seqBuilder: [PRCheckKey: Int] = [:]
        for plan in plans {
            if case let .full(pr, _) = plan { seqBuilder[pr.key] = nextGateWriteSeq() }
        }
        let gateIssueSeq = seqBuilder
        await withTaskGroup(of: (PRCheckKey, PRState).self) { group in
            var next = 0
            func schedule() {
                guard next < plans.count else { return }
                let plan = plans[next]
                next += 1
                group.addTask { await Self.fetchState(plan) }
            }
            for _ in 0..<Self.checksConcurrency {
                schedule()
            }
            // Seed from the (already pruned) live maps so absent keys stay absent.
            var pending = PendingHydration(checks: prChecks, gates: prGates, marks: prHydrationMark)
            var sinceFlush = 0
            while let (key, state) = await group.next() {
                guard checksGeneration == generation else { continue }
                // A fresh gate is a successful full fetch (a checks-only carry-over or a failed fetch
                // has no issue tick here, so it leaves the live gate untouched at publish).
                let freshSeq = state.gate != nil ? gateIssueSeq[key] : nil
                fold(key: key, state: state, issueByKey: issueByKey, gateIssueSeq: freshSeq, into: &pending)
                sinceFlush += 1
                if sinceFlush >= Self.checksFlushBatch {
                    publishChecks(pending, generation: generation)
                    sinceFlush = 0
                }
                schedule()
            }
            if sinceFlush > 0 {
                publishChecks(pending, generation: generation)
            }
        }
    }

    /// One PR's hydration plan: a full detail+reviews+checks fetch, or — for a PR unchanged since
    /// its last hydration — a cheap checks-only refresh reusing the cached head and gate.
    enum FetchPlan {
        case full(PRFetch, mergeInfo: RepoMergeInfo?)
        case checksOnly(PRFetch, head: PullRequestDetail.Head, gate: PRGate)
    }

    /// Resolve each PR's plan: checks-only when its gate is still current (see `reusableMark`),
    /// else a full refetch. Reads actor state, so it runs before the task group is spawned.
    private func fetchPlans(for prs: [PRFetch], mergeInfoByKey: [PRCheckKey: RepoMergeInfo]) -> [FetchPlan] {
        prs.map { pr in
            if let mark = reusableMark(for: pr), let gate = prGates[pr.key] {
                .checksOnly(pr, head: mark.head, gate: gate)
            } else {
                .full(pr, mergeInfo: mergeInfoByKey[pr.key])
            }
        }
    }

    /// Execute one plan off-actor, tagged with its key for the drain loop.
    nonisolated static func fetchState(_ plan: FetchPlan) async -> (PRCheckKey, PRState) {
        switch plan {
        case let .full(pr, mergeInfo):
            await (pr.key, fetchPRState(for: pr.issue, login: pr.login, mergeInfo: mergeInfo, using: pr.api))
        case let .checksOnly(pr, head, gate):
            await (
                pr.key,
                fetchChecksState(
                    repo: pr.issue.repositorySlug, number: pr.issue.number, head: head, cachedGate: gate, using: pr.api
                )
            )
        }
    }

    /// The three hydration maps a drain accumulates before publishing, bundled so the fold/publish
    /// helpers stay within the parameter-count limit.
    struct PendingHydration {
        var checks: [PRCheckKey: PRChecks]
        var gates: [PRCheckKey: PRGate]
        var marks: [PRCheckKey: HydrationMark]
        /// Issue-time write-clock ticks for the keys this wave *freshly* re-fetched a gate for (a
        /// successful full fetch — not a checks-only carry-over or a failed fetch). Only these keys
        /// are eligible to overwrite the live gate at publish, and only when their tick beats the
        /// live `prGateSeq` (so a merge-poll write issued later is preserved, #84).
        var freshGateSeq: [PRCheckKey: Int] = [:]
    }

    /// Fold one completed PR's resolved state into the pending hydration maps, firing a pass/fail
    /// banner on a real check observation. A `nil` checks result clears the decorative dot but
    /// leaves `lastCheckStatus` untouched, so a transient fetch error can't swallow the next real
    /// pass→fail transition (bug #3).
    private func fold(
        key: PRCheckKey,
        state: PRState,
        issueByKey: [PRCheckKey: SearchIssue],
        gateIssueSeq: Int?,
        into pending: inout PendingHydration
    ) {
        pending.gates[key] = state.gate
        // Carry the fetch's issue tick so publish can compare its recency against a concurrent
        // merge-poll write for the same key (#84). `nil` for a checks-only carry-over or a failed
        // fetch — those leave the live gate (and its stamp) untouched at publish.
        if let gateIssueSeq {
            pending.freshGateSeq[key] = gateIssueSeq
        }
        if let resolved = state.checks {
            if let issue = issueByKey[key] {
                notifyCheckStatusChange(key: key, pr: issue, newStatus: resolved.status)
            }
            pending.checks[key] = resolved
        } else {
            pending.checks[key] = nil
        }
        // Record the reuse hint only on a real hydration (a gate and head came back) with a known
        // `updated_at`; a failed detail fetch (nil gate/head) clears any mark so it's fully retried.
        // On a checks-only refresh the gate/head are the carried-over cached ones, so the mark just
        // renews unchanged.
        if state.gate != nil, let head = state.head, let updated = issueByKey[key]?.updatedAt {
            pending.marks[key] = HydrationMark(updatedAt: updated, head: head)
        } else {
            pending.marks[key] = nil
        }
    }

    /// Publish a hydration batch as single whole-map assignments (one view invalidation each),
    /// unless a newer wave has superseded this one. The marks are view-invisible but published here
    /// too so they stay consistent with the gates/checks they describe.
    ///
    /// Checks and marks are reassigned wholesale from the batch, but **gates merge by issue-time
    /// recency** onto the live map: only keys this wave *freshly* re-fetched (`freshGateSeq`)
    /// overwrite the live gate, and only when their issue tick beats the live `prGateSeq`. This
    /// keeps a merge-readiness poll's write that read newer state from being clobbered by a wave
    /// fetch that read older state but folded later (#84), while a wave fetch that genuinely read
    /// newer state still wins. Keys the wave didn't freshly fetch (a checks-only carry-over, or a
    /// failed fetch) keep their live gate rather than blanking it on a transient miss.
    private func publishChecks(_ pending: PendingHydration, generation: Int) {
        guard checksGeneration == generation else { return }
        var gates = prGates
        var seqs = prGateSeq
        for (key, seq) in pending.freshGateSeq where seq > (seqs[key] ?? .min) {
            if let gate = pending.gates[key] {
                gates[key] = gate
                seqs[key] = seq
            }
        }
        prGates = gates
        prGateSeq = seqs
        prChecks = pending.checks
        prHydrationMark = pending.marks
    }
}
