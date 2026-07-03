import Foundation

/// Off-main-actor loading helpers for `AppStore.refresh()`. Kept `nonisolated static` and
/// state-free (everything arrives as parameters) so they run inside `TaskGroup`s and stay
/// `Sendable`-clean.
extension AppStore {
    /// Load one account's sections + inbox off the main actor. Never throws — errors are
    /// captured into the returned value so the merge step can surface them coherently.
    nonisolated static func load(
        account: Account,
        api: GitHubAPI,
        queries: [SearchQuery.Section]
    ) async
    -> AccountLoad {
        var sections: [String: [SearchIssue]] = [:]
        var sessionExpired = false
        var errorMessage: String?
        for section in queries where section.isRunnable {
            do {
                sections[section.id] = try await api.searchIssues(section.query)
            } catch {
                let fallback = "Failed to load \(section.title)."
                classify(error, expired: &sessionExpired, message: &errorMessage, fallback: fallback)
                logFailure("search", account: account, error: error)
            }
        }
        var notifications: [GitHubNotification] = []
        var notificationsSucceeded = false
        do {
            notifications = try await api.notifications()
            notificationsSucceeded = true
        } catch {
            classify(error, expired: &sessionExpired, message: &errorMessage, fallback: nil)
            logFailure("notifications", account: account, error: error)
        }
        // Starred is a decorative cross-tab signal — a failure here must never surface an error
        // message (it's not a section the user asked for), only skip advancing the set.
        var starred: [String] = []
        var starredSucceeded = false
        do {
            starred = try await api.starredRepos()
            starredSucceeded = true
        } catch {
            if case .http(401) = error as? GitHubClient.ClientError { sessionExpired = true }
            logFailure("starred", account: account, error: error)
        }
        return AccountLoad(
            account: account,
            sections: sections,
            notifications: notifications,
            notificationsSucceeded: notificationsSucceeded,
            starred: starred,
            starredSucceeded: starredSucceeded,
            sessionExpired: sessionExpired,
            errorMessage: errorMessage
        )
    }

    /// Fold one failure into a load's error state: a 401 flags the expired session; otherwise
    /// apply `fallback` (a `nil` fallback is the inbox case — don't clobber a more important
    /// section error already set this pass).
    private nonisolated static func classify(
        _ error: Error,
        expired: inout Bool,
        message: inout String?,
        fallback: String?
    ) {
        if case .http(401) = error as? GitHubClient.ClientError {
            expired = true
            message = "Session expired — reconnect in Settings."
        } else if let fallback {
            message = fallback
        } else if message == nil {
            message = "Failed to load notifications."
        }
    }

    private nonisolated static func logFailure(_ what: String, account: Account, error: Error) {
        let reason = error.localizedDescription
        Log.network.error("\(what, privacy: .public) [\(account.login, privacy: .public)]: \(reason, privacy: .public)")
    }

    /// Hydrate one PR: fetch its detail (once), then best-effort its check runs and reviews,
    /// and derive the action gate. Never throws — a failed detail fetch yields an empty
    /// `PRState` so the row stays optimistic (buttons show as they did before hydration).
    /// `mergeInfo` is the viewer's repo merge signals (push access + allowed strategies), or
    /// nil when not yet hydrated. Set `includeChecks: false` for a gate-only refresh (e.g. after
    /// an approval, where CI can't have changed) to skip the extra check-runs request.
    nonisolated static func fetchPRState(
        for item: SearchIssue,
        login: String,
        mergeInfo: RepoMergeInfo?,
        using api: GitHubAPI,
        includeChecks: Bool = true
    ) async
    -> PRState {
        let repo = item.repositorySlug
        guard let detail = try? await api.pullRequest(repo: repo, number: item.number) else {
            Log.network.debug("pr detail skip #\(item.number, privacy: .public)")
            return PRState(checks: nil, gate: nil)
        }
        let checks = includeChecks ? await fetchChecks(repo: repo, detail: detail, using: api) : nil
        // `alreadyApproved` is irrelevant for the viewer's own PRs (Approve is hidden
        // synchronously in the row anyway), so skip the reviews call for them — it saves a
        // request per own-PR per poll, which matters against GitHub's hourly rate limit.
        let isOwnPR = item.user?.login.lowercased() == login.lowercased()
        let reviews: [PullRequestReview] = if isOwnPR {
            []
        } else {
            await (try? api.reviews(repo: repo, number: item.number)) ?? []
        }
        let gate = deriveGate(detail: detail, reviews: reviews, login: login, mergeInfo: mergeInfo)
        return PRState(checks: checks, gate: gate)
    }

    /// Map a PR's check runs to a `PRChecks`, or nil if it has no checks or the fetch fails.
    private nonisolated static func fetchChecks(
        repo: String,
        detail: PullRequestDetail,
        using api: GitHubAPI
    ) async
    -> PRChecks? {
        do {
            let runs = try await api.checkRuns(repo: repo, ref: detail.head.sha)
            guard let status = runs.ciRollup else { return nil }
            let models = runs.map { $0.checkRowModel(repo: repo, branch: detail.head.ref) }
            return PRChecks(status: status, checks: models)
        } catch {
            Log.network
                .debug("ci skip #\(detail.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Derive the action gate from PR detail + reviews. Pure so it's unit-testable.
    /// - `alreadyApproved`: the viewer's *latest* definitive review (approve / changes /
    ///   dismissed — comment & pending don't count) is an approval. Relies on GitHub returning
    ///   reviews oldest-first; the caller caps at one page (100), enough in practice.
    /// - `mergeable`: GitHub would show a live Merge button (open, non-draft, a clean-ish
    ///   `mergeable_state`) *and* the viewer has push access. Stays optimistic where the answer
    ///   is genuinely unknown — `nil`/`"unknown"` mergeable_state (GitHub still computing after a
    ///   push) or `nil` merge info — so a valid Merge button never flickers away; only the
    ///   definitively-bad states (blocked/dirty/behind/draft/closed) hide it.
    /// - `allowedMergeMethods`: the repo's enabled strategies, or all three until `mergeInfo`
    ///   hydrates (optimistic — the inline picker never shows fewer than reality).
    nonisolated static func deriveGate(
        detail: PullRequestDetail,
        reviews: [PullRequestReview],
        login: String,
        mergeInfo: RepoMergeInfo?
    )
    -> PRGate {
        let me = login.lowercased()
        let mine = reviews.filter { review in
            review.user?.login.lowercased() == me
                && ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state)
        }
        let alreadyApproved = mine.last?.state == "APPROVED"

        let mergeableStateOK: Bool = switch detail.mergeableState {
        case nil,
             "unknown": true // indeterminate → optimistic
        case let state?: ["clean", "unstable", "has_hooks"].contains(state)
        }
        let stateOK = detail.state == "open" && detail.draft != true && mergeableStateOK
        let mergeable = stateOK && (mergeInfo?.canMerge ?? true)

        Log.store.debug("""
        gate #\(detail.number, privacy: .public) me=\(me, privacy: .public) \
        state=\(detail.state, privacy: .public) mergeable_state=\(detail.mergeableState ?? "nil", privacy: .public) \
        reviews=\(reviews.count, privacy: .public) mine=\(mine.count, privacy: .public) \
        approved=\(alreadyApproved, privacy: .public) \
        canMerge=\(String(describing: mergeInfo?.canMerge), privacy: .public) mergeable=\(mergeable, privacy: .public)
        """)

        return PRGate(
            alreadyApproved: alreadyApproved,
            mergeable: mergeable,
            allowedMergeMethods: mergeInfo?.allowedMethods ?? MergeMethod.allCases
        )
    }
}
