import SwiftUI

/// The MenuBarExtra window: sign-in prompt when signed out, else the resolved sections.
struct MenuContentView: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if store.isSignedIn {
                signedInBody
            } else {
                SignInPromptView()
            }
            Divider()
            footer
        }
        .padding(10)
        .frame(width: 340)
        .task { if store.isSignedIn { await store.refresh() } }
    }

    private var header: some View {
        HStack {
            Text("gbar").font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing || !store.isSignedIn)
        }
    }

    @ViewBuilder
    private var signedInBody: some View {
        if let message = store.lastErrorMessage {
            Text(message).font(.caption).foregroundStyle(.orange)
        }
        if store.sessionExpired {
            SettingsLink { Text("Reconnect…") }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        if store.sections.allSatisfy(\.items.isEmpty), !store.isRefreshing {
            Text("Nothing to show right now.").font(.callout).foregroundStyle(.secondary)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.sections) { section in
                    if !section.items.isEmpty {
                        sectionView(section)
                    }
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private func sectionView(_ section: LoadedSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(section.items) { item in
                Button {
                    if let url = URL(string: item.htmlURL) { openURL(url) }
                } label: {
                    ItemRowView(item: item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink { Text("Settings…") }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.callout)
    }
}

/// Shown when no credential is configured yet.
private struct SignInPromptView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect a GitHub account to get started.")
                .font(.callout)
            Text("Open Settings to sign in with GitHub (device flow) or paste a token.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsLink { Text("Open Settings…") }
        }
    }
}
