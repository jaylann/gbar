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
        do {
            notifications = try await api.notifications()
        } catch {
            classify(error, expired: &sessionExpired, message: &errorMessage, fallback: nil)
            logFailure("notifications", account: account, error: error)
        }
        return AccountLoad(
            account: account,
            sections: sections,
            notifications: notifications,
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

    /// Fetch and map one PR's check runs, or nil if the PR has no checks or anything fails.
    nonisolated static func fetchChecks(for item: SearchIssue, using api: GitHubAPI) async -> PRChecks? {
        do {
            let repo = item.repositorySlug
            let detail = try await api.pullRequest(repo: repo, number: item.number)
            let runs = try await api.checkRuns(repo: repo, ref: detail.head.sha)
            guard let status = runs.ciRollup else { return nil }
            let models = runs.map { $0.checkRowModel(repo: repo, branch: detail.head.ref) }
            return PRChecks(status: status, checks: models)
        } catch {
            Log.network
                .debug("ci skip #\(item.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
