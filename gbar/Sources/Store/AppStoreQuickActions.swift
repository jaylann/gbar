import Foundation

// MARK: - Quick actions

extension AppStore {
    /// Approve a pull request via its own account's client, optionally attaching a review
    /// message. Approval doesn't change which lists the PR belongs to, so on success we just
    /// clear a stale error. An empty/whitespace-only message is sent as no body (plain approval).
    func approve(_ item: AccountItem, message: String? = nil) async {
        guard let token = tokenForAccount(item.account) else { return }
        let api = makeAPI(item.account.apiBaseURL, token)
        let issue = item.issue
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            try await api.approvePullRequest(repo: issue.repositorySlug, number: issue.number, body: body)
            lastErrorMessage = nil
        } catch {
            handleActionError(
                error,
                verb: "approve",
                fallback: "Failed to approve \(issue.repositorySlug) #\(issue.number).",
                item: item
            )
        }
    }

    /// Merge a pull request with the chosen strategy via its own account's client. On success
    /// the PR is removed from every section (it's no longer open); failures surface via
    /// `lastErrorMessage`.
    func merge(_ item: AccountItem, method: MergeMethod) async {
        guard let token = tokenForAccount(item.account) else { return }
        let api = makeAPI(item.account.apiBaseURL, token)
        let issue = item.issue
        do {
            try await api.mergePullRequest(repo: issue.repositorySlug, number: issue.number, method: method)
            lastErrorMessage = nil
            removeItem(id: item.id)
        } catch {
            handleActionError(
                error,
                verb: "merge",
                fallback: "Failed to merge \(issue.repositorySlug) #\(issue.number).",
                item: item
            )
        }
    }

    /// Shared failure handling for quick actions. A 401 means the token is dead, so mirror the
    /// refresh behaviour — flag `sessionExpired` and prompt a reconnect — instead of a generic
    /// per-action failure; anything else surfaces the caller's `fallback` message.
    func handleActionError(_ error: Error, verb: String, fallback: String, item: AccountItem) {
        if case .http(401) = error as? GitHubClient.ClientError {
            sessionExpired = true
            lastErrorMessage = "Session expired — reconnect in Settings."
        } else {
            lastErrorMessage = fallback
        }
        let ref = "\(item.issue.repositorySlug)#\(item.issue.number)"
        let reason = error.localizedDescription
        Log.network
            .error("\(verb, privacy: .public) failed for \(ref, privacy: .public): \(reason, privacy: .public)")
    }
}
