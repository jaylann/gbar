import Foundation

/// Desktop-notification orchestration for `AppStore`: diff each poll's fresh data against the
/// per-account baselines (declared as stored properties on the main type), post banners for
/// what's genuinely new, and advance the baselines. The set math lives in `NotificationDiff`;
/// the stateful, account-aware seeding and preservation live here.
///
/// Two invariants guard against banner spam on transient failures:
/// - A baseline is advanced/seeded only for the `(account, section)` / `account` that actually
///   loaded this poll. A failed load leaves that slice of the baseline untouched (bug #2), so a
///   section that recovers doesn't re-fire its pre-existing items.
/// - Notifications for a slice fire only once it has been *seeded* — its first successful load is
///   silent. A poll that fails never seeds, so the first successful poll after a failed launch
///   diffs against real data, not an empty baseline (bug #1).
extension AppStore {
    // MARK: - Bulk mark read

    /// Mark the whole (account-scoped) inbox read via the bulk endpoint. Respects the active
    /// account filter; ignores the transient reason/search filters (the UI hides this action
    /// while either is active). Pessimistic: drop an account's notifications only after its
    /// PUT succeeds. Baselines self-heal on the next poll, so no explicit baseline reset needed.
    func markAllRead() async {
        let scoped = accountFilter == nil ? accounts : accounts.filter { $0.id == accountFilter }
        var failed = false
        for account in scoped {
            guard notifications.contains(where: { $0.account.id == account.id && $0.notification.unread }),
                  let token = tokenForAccount(account) else { continue }
            let api = makeAPI(account.apiBaseURL, token)
            do {
                try await api.markAllNotificationsRead()
                dropNotifications(forAccount: account.id)
            } catch {
                failed = true
                Log.network.error("mark all read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastErrorMessage = failed ? "Couldn't mark all notifications as read." : nil
    }

    // MARK: - Sections

    /// Diff freshly-loaded section items against the baseline and post a banner per new PR/issue,
    /// then advance the per-`(account, query)` baseline. Only successfully-loaded `(account, query)`
    /// slices are touched; failed ones keep their previous baseline entries so recovery is quiet.
    func notifyNewSectionItems(loads: [Account.ID: AccountLoad], queries: [SearchQuery.Section]) {
        let previousItemKeys = seenSectionItemKeys.reduce(into: Set<String>()) { acc, entry in
            acc.insert(Self.dropQueryComponent(entry))
        }
        var newBaseline = seenSectionItemKeys
        var newSeeded = seededSectionKeys
        var candidates: [AccountItem] = []
        var candidateKeys = Set<String>()
        var didLoadAnySection = false

        for account in accounts {
            guard let load = loads[account.id] else { continue }
            for query in queries where query.isRunnable {
                // A missing key means the query failed for this account — leave its baseline slice
                // intact and don't seed it, so it can't drop out and re-fire on recovery.
                guard let issues = load.sections[query.id] else { continue }
                didLoadAnySection = true
                let sectionKey = "\(account.id)\n\(query.id)"
                let wasSeeded = seededSectionKeys.contains(sectionKey)

                // Replace this slice's baseline contribution with the fresh items.
                newBaseline = newBaseline.filter { !$0.hasPrefix(sectionKey + "\n") }
                for issue in issues {
                    newBaseline.insert("\(sectionKey)\n\(issue.id)")
                }
                newSeeded.insert(sectionKey)

                guard wasSeeded else { continue } // first load seeds silently
                for issue in issues {
                    let itemKey = NotificationDiff.sectionItemKey(account: account, issue: issue)
                    // New only if unseen across *every* section last poll, deduped within this poll.
                    guard !previousItemKeys.contains(itemKey), candidateKeys.insert(itemKey).inserted else { continue }
                    candidates.append(AccountItem(account: account, issue: issue))
                }
            }
        }

        seenSectionItemKeys = newBaseline
        seededSectionKeys = newSeeded
        postSectionBanners(candidates, didLoadAnySection: didLoadAnySection)
    }

    /// Emit a banner for each genuinely-new section item, applying the recency gate, and advance
    /// the poll marker. Split out of `notifyNewSectionItems` so the diff/baseline math stays within
    /// the lint complexity budget.
    ///
    /// The recency gate guards against a dormant item churning back into the capped, eventually-
    /// consistent fetch window *between consecutive polls*. It only holds up when the previous poll
    /// was itself recent: after a long gap (system sleep, network outage, polling turned off) the
    /// baseline diff is the honest "new since we last looked" signal, so gating by age would wrongly
    /// drop a genuinely-new item whose activity predates the gap. Skip the gate when the gap exceeds
    /// the window. Only successful polls advance the marker, so a run of failed polls during an
    /// outage can't make the next recovery look "recent".
    private func postSectionBanners(_ candidates: [AccountItem], didLoadAnySection: Bool) {
        let now = Date()
        let gateActive = lastSectionPollDate
            .map { now.timeIntervalSince($0) <= NotificationDiff.recencyWindow } ?? false
        if didLoadAnySection { lastSectionPollDate = now }

        guard notificationsEnabled, notifySections else { return }
        for item in candidates where !gateActive || NotificationDiff.isRecentlyActive(item.issue, now: now) {
            let issue = item.issue
            notifier?.post(
                title: issue.isPullRequest ? "New pull request" : "New issue",
                body: "\(issue.repositorySlug) #\(issue.number): \(issue.title)",
                url: URL(string: issue.htmlURL)
            )
        }
    }

    // MARK: - Inbox

    /// Diff freshly-loaded inbox threads against the baseline and post a banner per newly-unread
    /// thread, then advance the per-account unread baseline. Only accounts whose inbox fetch
    /// succeeded are touched — a failed inbox keeps its baseline so recovery stays quiet.
    func notifyNewInboxItems(loads: [Account.ID: AccountLoad]) {
        let previousUnread = lastUnreadInboxKeys
        var newBaseline = lastUnreadInboxKeys
        var newSeeded = seededInboxAccounts
        var candidates: [AccountNotification] = []

        for account in accounts {
            guard let load = loads[account.id], load.notificationsSucceeded else { continue }
            let wasSeeded = seededInboxAccounts.contains(account.id)

            // Replace this account's unread contribution with the fresh set.
            newBaseline = newBaseline.filter { !$0.hasPrefix(account.id + "\n") }
            newBaseline.formUnion(NotificationDiff.unreadKeys(account: account, notifications: load.notifications))
            newSeeded.insert(account.id)

            guard wasSeeded else { continue } // first load seeds silently
            let tagged = load.notifications.map { AccountNotification(account: account, notification: $0) }
            candidates.append(contentsOf: NotificationDiff.newNotifications(
                previousUnreadKeys: previousUnread,
                current: tagged
            ))
        }

        lastUnreadInboxKeys = newBaseline
        seededInboxAccounts = newSeeded

        guard notificationsEnabled, notifyInbox else { return }
        for item in candidates {
            notifier?.post(
                title: item.notification.repository.fullName,
                body: item.notification.subject.title,
                url: item.notification.htmlURL(apiBaseURL: item.account.apiBaseURL)
            )
        }
    }

    // MARK: - CI checks

    /// Post a banner when a PR's CI reaches a new terminal pass/fail state, then advance the
    /// per-`(account, PR)` baseline. The `previous == nil` guard in `checkStatusChanged` keeps the
    /// first observation quiet, so this needs no separate seeding gate.
    func notifyCheckStatusChange(key: PRCheckKey, pr: SearchIssue, newStatus: CIStatus) {
        let previous = lastCheckStatus[key]
        if notificationsEnabled, notifyChecks, NotificationDiff.checkStatusChanged(previous: previous, new: newStatus) {
            let passed = newStatus == .success
            notifier?.post(
                title: passed ? "CI passed" : "CI failed",
                body: "\(pr.repositorySlug) #\(pr.number): \(pr.title)",
                url: URL(string: pr.htmlURL)
            )
        }
        lastCheckStatus[key] = newStatus
    }

    // MARK: - Authorization

    /// Re-read OS authorization and publish it for the Settings UI. No-op when no notifier is
    /// wired (tests/previews without one).
    func refreshNotificationAuthStatus() async {
        guard let notifier else { return }
        notificationAuthStatus = await notifier.authorizationStatus()
    }

    /// Prompt the OS permission dialog (a no-op banner-wise if already decided), then re-read
    /// the resulting status so the UI reflects the user's choice.
    func requestNotificationAuthorization() async {
        guard let notifier else { return }
        await notifier.requestAuthorization()
        notificationAuthStatus = await notifier.authorizationStatus()
    }

    /// Post a sample banner through the real notifier so the user can verify end-to-end delivery.
    func sendTestNotification() {
        notifier?.post(title: "gbar test notification", body: "Notifications are working.", url: nil)
    }

    // MARK: - Baseline lifecycle

    /// Wipe every notification baseline — used on sign-out so the next sign-in re-seeds silently.
    func resetNotificationBaselines() {
        seenSectionItemKeys = []
        seededSectionKeys = []
        lastUnreadInboxKeys = []
        seededInboxAccounts = []
        lastCheckStatus = [:]
        lastSectionPollDate = nil
    }

    /// Drop one account's baseline entries — used when removing a single account so re-adding it
    /// re-seeds silently and the sets don't leak.
    func pruneNotificationBaselines(accountID: Account.ID) {
        let prefix = accountID + "\n"
        seenSectionItemKeys = seenSectionItemKeys.filter { !$0.hasPrefix(prefix) }
        seededSectionKeys = seededSectionKeys.filter { !$0.hasPrefix(prefix) }
        lastUnreadInboxKeys = lastUnreadInboxKeys.filter { !$0.hasPrefix(prefix) }
        seededInboxAccounts.remove(accountID)
        lastCheckStatus = lastCheckStatus.filter { $0.key.accountID != accountID }
    }

    /// Reduce a `"<account>\n<query>\n<issue>"` baseline entry to `"<account>\n<issue>"` — the
    /// cross-section identity used to decide whether an item is new anywhere.
    private static func dropQueryComponent(_ entry: String) -> String {
        let parts = entry.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return entry }
        return "\(parts[0])\n\(parts[2])"
    }
}
