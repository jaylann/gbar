import ProjectDescription

// ─── Tuist manifest for gbar ─────────────────────────────────────────────────
// Single-target macOS menu-bar app (LSUIElement agent — no dock icon). Grow this
// into feature modules / a shared core package as the project does.

let bundleId = "dev.lanfermann.gbar"
let deploymentTarget: DeploymentTargets = .macOS("14.0")

// source of truth for release.yml — the release workflow greps these two lines.
let marketingVersion = "0.5.2"
let buildNumber = "13"

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "MARKETING_VERSION": .string(marketingVersion),
    "CURRENT_PROJECT_VERSION": .string(buildNumber),
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
]

/// Signing is xcconfig-driven so the committed default stays ad-hoc/teamless (a fresh clone
/// can `just build` the sandboxed app with no Apple Developer team), while a local or release
/// xcconfig can supply a real DEVELOPMENT_TEAM + Automatic signing. A team-signed build
/// carries an access-group entitlement, which lets KeychainStore use the data-protection
/// keychain (no recurring keychain ACL prompt on rebuild). Defaults live in the Tuist/Config
/// xcconfig templates.
///
/// These MUST live on the app target, not project `base`: Tuist injects a target-level
/// `CODE_SIGN_IDENTITY = "-"` that outranks any project-level value. We also set the
/// SDK-conditional key because macOS ships a higher-precedence
/// `CODE_SIGN_IDENTITY[sdk=macosx*]` default (resolves to "-") that shadows the plain key.
let signingSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "$(GBAR_CODE_SIGN_STYLE)",
    "CODE_SIGN_IDENTITY": "$(GBAR_CODE_SIGN_IDENTITY)",
    "CODE_SIGN_IDENTITY[sdk=macosx*]": "$(GBAR_CODE_SIGN_IDENTITY)",
    "DEVELOPMENT_TEAM": "$(GBAR_DEVELOPMENT_TEAM)",
    // Teamless/ad-hoc → gbar.entitlements (no keychain group, no profile needed). A team
    // build → gbar-signed.entitlements (adds keychain-access-groups → data-protection
    // keychain, no prompt). Requiring the group on an ad-hoc build would fail with
    // "requires a provisioning profile", so it must be swappable per environment.
    "CODE_SIGN_ENTITLEMENTS": "$(GBAR_ENTITLEMENTS)",
    // Developer ID release only: a real Developer ID provisioning profile must validate the
    // application-identifier + keychain-access-groups entitlements — on macOS an unvalidated
    // group under the App Sandbox makes launchd refuse to spawn the app ("Launchd job spawn
    // failed"). Empty (no-op) for teamless/ad-hoc and Automatic dev signing.
    "PROVISIONING_PROFILE_SPECIFIER": "$(GBAR_PROVISIONING_PROFILE_SPECIFIER)",
    // Icon Composer (.icon) app icon — gbar/Resources/gbar.icon, compiled by actool.
    // Must be target-level: Tuist injects a target-level default of "AppIcon" that
    // outranks any project-`base` value (same precedence issue as CODE_SIGN_IDENTITY).
    "ASSETCATALOG_COMPILER_APPICON_NAME": "gbar",
]

let appInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "gbar",
    "CFBundleShortVersionString": .string(marketingVersion),
    "CFBundleVersion": .string(buildNumber),
    // Menu-bar agent: no dock icon, no main window on launch.
    "LSUIElement": true,
    "ITSAppUsesNonExemptEncryption": false,
    // Values come from the gitignored xcconfigs (Tuist/Config/{Debug,Release}.xcconfig).
    // GH_OAUTH_CLIENT_ID is blank for self-host builds (app prompts at runtime) and
    // pre-filled for the paid/hosted build. GH_API_BASE_URL defaults to api.github.com
    // and is overridable for GitHub Enterprise.
    "GHOAuthClientID": "$(GH_OAUTH_CLIENT_ID)",
    "GHAPIBaseURL": "$(GH_API_BASE_URL)",
]

let appSettings: Settings = .settings(
    base: baseSettings,
    configurations: [
        .debug(name: .debug, xcconfig: .relativeToRoot("Tuist/Config/Debug.xcconfig")),
        .release(name: .release, xcconfig: .relativeToRoot("Tuist/Config/Release.xcconfig")),
    ]
)

let project = Project(
    name: "gbar",
    settings: appSettings,
    targets: [
        .target(
            name: "gbar",
            destinations: [.mac],
            product: .app,
            bundleId: bundleId,
            deploymentTargets: deploymentTarget,
            infoPlist: .extendingDefault(with: appInfoPlist),
            sources: ["gbar/Sources/**"],
            resources: ["gbar/Resources/**"],
            dependencies: [],
            settings: .settings(base: signingSettings)
        ),
        .target(
            name: "gbarTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "\(bundleId).tests",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["gbarTests/**"],
            dependencies: [.target(name: "gbar")]
        ),
    ]
)
