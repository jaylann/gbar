import Foundation

/// One search result tagged with the account it came from. Aggregation merges items from
/// every signed-in account into a single section, so each item must remember its owner
/// (for provenance badges, per-account CI keys, and account-scoped filtering).
struct AccountItem: Identifiable {
    let account: Account
    let issue: SearchIssue

    /// Composite of account id + issue id — a bare `issue.id` (an `Int`) can collide across
    /// hosts, so scope it by account for a stable SwiftUI identity.
    var id: String {
        "\(account.id)#\(issue.id)"
    }
}

/// One notification tagged with its owning account — `markRead` needs the right account's
/// token, and the row shows which account it belongs to.
struct AccountNotification: Identifiable {
    let account: Account
    let notification: GitHubNotification

    var id: String {
        "\(account.id)#\(notification.id)"
    }
}

/// Composite key for `AppStore.prChecks`: PR ids are per-host, so a bare `Int` would collide
/// when the same numeric id exists on two accounts.
struct PRCheckKey: Hashable {
    let accountID: Account.ID
    let prID: Int
}

/// One Actions workflow run tagged with the account it was fetched under and its repo slug,
/// so the merged list shows provenance and account-scoped filtering works.
struct AccountActionRun: Identifiable {
    let account: Account
    let repo: String
    let run: WorkflowRun

    /// Composite of account id + repo + run id — run ids are per-host, so scope them.
    var id: String {
        "\(account.id)#\(repo)#\(run.id)"
    }
}

/// One release tagged with the account it was fetched under and its repo slug.
struct AccountRelease: Identifiable {
    let account: Account
    let repo: String
    let release: Release

    var id: String {
        "\(account.id)#\(repo)#\(release.id)"
    }
}

/// A default/saved query resolved to its current results, aggregated across accounts.
struct LoadedSection: Identifiable {
    let id: String
    let title: String
    let items: [AccountItem]
    /// Which tab the section renders under, carried over from `SearchQuery.Section.resolvedKind`.
    let kind: SearchQuery.Section.Kind
}

/// The rolled-up CI status for one PR plus its per-check detail rows, hydrated lazily
/// after a refresh (see `AppStore.prChecks`).
struct PRChecks {
    let status: CIStatus
    let checks: [CheckRow.Model]
}

/// The two repo-level merge signals resolved together from the one `GET /repos/{repo}` call
/// the hydration wave already makes: whether the viewer can merge at all (`canMerge`) and which
/// strategies the repo enables (`allowedMethods`), so the gate and the inline picker both come
/// from a single cache entry.
struct RepoMergeInfo {
    let canMerge: Bool
    let allowedMethods: [MergeMethod]
}

/// Whether the hover quick-actions apply to a PR, derived during hydration (see
/// `AppStore.prGates`). `alreadyApproved` hides Approve; `mergeable` is the full
/// "GitHub would let me merge this" verdict (state + write access) that gates Merge;
/// `allowedMergeMethods` is the repo's enabled strategies for the inline merge picker.
struct PRGate {
    let alreadyApproved: Bool
    let mergeable: Bool
    let allowedMergeMethods: [MergeMethod]
}

/// One PR's hydrated state — CI checks and the action gate — produced together from the
/// same fetch sequence so the hydration wave writes both in one pass.
struct PRState {
    let checks: PRChecks?
    let gate: PRGate?
    /// The PR's head (sha + ref) as of this hydration, so a subsequent unchanged poll can re-fetch
    /// just its check-runs against the same sha without re-fetching the detail. `nil` when the
    /// detail fetch failed (no head to record).
    let head: PullRequestDetail.Head?
}

/// The result of loading one account's sections + inbox, gathered off the main actor and
/// merged back on it. Value type with `Sendable` members → implicit `Sendable`.
struct AccountLoad {
    let account: Account
    /// Section results keyed by `SearchQuery.Section.id`. A missing key means that query
    /// failed for this account (so the merged section can still show other accounts' rows).
    var sections: [String: [SearchIssue]]
    var notifications: [GitHubNotification]
    /// Whether the `/notifications` fetch succeeded this poll. The notification diff advances
    /// (and seeds) the inbox baseline only for accounts that loaded, so a transient inbox
    /// failure can't drop threads from the baseline and re-fire them as "new" on recovery.
    var notificationsSucceeded: Bool
    /// The `owner/name` slugs this account has starred. Best-effort like `notifications`; a
    /// failed fetch leaves the previous set in place (see `starredSucceeded`).
    var starred: [String]
    /// Whether the `/user/starred` fetch succeeded this poll. A transient failure must not wipe
    /// the account's starred set (which would drop the star marks / Starred filter until the
    /// next good poll), so the merge keeps the prior set when this is false.
    var starredSucceeded: Bool
    var sessionExpired: Bool
    var errorMessage: String?
    /// When any request for this account hit a GitHub rate limit (from `Retry-After` /
    /// `X-RateLimit-Reset`), the time access is expected back — the poll loop backs off to the
    /// latest such time across accounts. nil when nothing was rate-limited this poll.
    var rateLimitedUntil: Date?
}

/// State of an in-place re-authentication (device flow) kicked off from the 401 prompt for a
/// single expired account.
///
/// Note: GitHub device-flow tokens carry **no** refresh token and PATs are static, so there is
/// nothing to silently refresh — a 401 recovery is always a full re-auth. This flow preserves the
/// account's identity by writing the fresh token back into that account's Keychain slot (keyed by
/// its `login`), so aggregation, filters, and baselines all carry over unchanged.
enum ReauthStatus: Equatable {
    /// Not reconnecting.
    case idle
    /// Requesting a device code from GitHub.
    case starting
    /// Waiting for the user to enter `code` in the browser and approve.
    case awaitingAuthorization(code: String)
    /// The reconnect attempt failed; carries a friendly message.
    case failed(String)
}

/// A candidate contributor to the menu-bar badge count. Raw values match the default
/// `SearchQuery` section ids (`SearchQuery.defaults`); `.inbox` maps to unread notifications
/// rather than a search section. The badge sums the user-selected sources (deduped by PR/issue),
/// and `allCases` order fixes both the Settings row order and the tooltip breakdown order.
///
/// Note: only the four baseline sections + inbox are selectable — custom saved queries (UUID ids)
/// are intentionally not badge sources.
enum BadgeSource: String, CaseIterable, Identifiable {
    case reviewRequested = "review-requested"
    case assignedPRs = "assigned-prs"
    case yourPRs = "created-prs"
    case assignedIssues = "assigned-issues"
    case inbox

    var id: String {
        rawValue
    }

    /// Label for the Settings toggle row.
    var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .assignedPRs: "Assigned PRs"
        case .yourPRs: "Your PRs"
        case .assignedIssues: "Assigned issues"
        case .inbox: "Unread inbox"
        }
    }

    /// Short noun used in the multi-source tooltip breakdown ("12 to review · 3 unread").
    var shortLabel: String {
        switch self {
        case .reviewRequested: "to review"
        case .assignedPRs: "assigned"
        case .yourPRs: "yours"
        case .assignedIssues: "issues"
        case .inbox: "unread"
        }
    }

    /// A full sentence used when exactly one source is active ("12 PRs awaiting your review").
    func soloTooltip(_ count: Int) -> String {
        switch self {
        case .reviewRequested: "\(count) \(prNoun(count)) awaiting your review"
        case .assignedPRs: "\(count) \(prNoun(count)) assigned to you"
        case .yourPRs: "\(count) \(prNoun(count)) you opened"
        case .assignedIssues: "\(count) issue\(plural(count)) assigned to you"
        case .inbox: "\(count) unread notification\(plural(count))"
        }
    }

    private func prNoun(_ count: Int) -> String {
        count == 1 ? "PR" : "PRs"
    }

    private func plural(_ count: Int) -> String {
        count == 1 ? "" : "s"
    }
}

/// How often the store polls GitHub in the background. Raw value is the interval in seconds;
/// `.off` (0) disables auto-refresh entirely.
enum PollInterval: TimeInterval, CaseIterable, Identifiable {
    case off = 0
    case s30 = 30
    case m1 = 60
    case m5 = 300
    case m15 = 900

    var id: TimeInterval {
        rawValue
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .s30: "30 seconds"
        case .m1: "1 minute"
        case .m5: "5 minutes"
        case .m15: "15 minutes"
        }
    }
}
