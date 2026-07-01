import ProjectDescription

// ─── Tuist manifest for gbar ─────────────────────────────────────────────────
// Single-target macOS menu-bar app (LSUIElement agent — no dock icon). Grow this
// into feature modules / a shared core package as the project does.

let bundleId = "dev.lanfermann.gbar"
let deploymentTarget: DeploymentTargets = .macOS("14.0")

// source of truth for release.yml — the release workflow greps these two lines.
let marketingVersion = "0.1.0"
let buildNumber = "1"

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "MARKETING_VERSION": .string(marketingVersion),
    "CURRENT_PROJECT_VERSION": .string(buildNumber),
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    // Ad-hoc signing so a fresh clone can `just build` and run the sandboxed app
    // locally without an Apple Developer team. For notarized distribution, override
    // with Developer ID signing (CODE_SIGN_STYLE = Automatic + DEVELOPMENT_TEAM).
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "-",
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
            entitlements: .file(path: "gbar/gbar.entitlements"),
            dependencies: []
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
