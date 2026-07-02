# Self-hosting gbar (bring your own GitHub OAuth App)

gbar is free to self-host. Because it uses GitHub's **OAuth device flow**, you don't
need a server or a client secret — just a public **client ID** from a GitHub OAuth App
you register yourself. (Prefer zero setup? A personal access token also works — jump to
[Option B](#option-b--personal-access-token). Want zero setup *and* one-click sign-in?
See the paid build in the [README](../README.md).)

## Option A — your own GitHub OAuth App (recommended)

1. Go to **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**
   (or directly: <https://github.com/settings/developers>).
2. Fill in:
   - **Application name:** anything, e.g. `gbar (personal)`.
   - **Homepage URL:** anything, e.g. `https://github.com/jaylann/gbar`.
   - **Authorization callback URL:** required by the form but unused by device flow —
     put `http://localhost` (or your homepage URL).
3. **Enable device flow:** on the app's page, check **"Enable Device Flow"** and save.
   This is the important step — device flow is off by default.
4. Copy the **Client ID** (it's public; there's no secret to manage for device flow).
5. In gbar: **Settings → Accounts**, open the **Advanced** disclosure and paste the
   **Client ID** (on a self-host build the disclosure opens automatically), then hit
   **Sign in with GitHub** and follow the prompt (gbar shows a code; you enter it at
   <https://github.com/login/device>).

### GitHub Enterprise

In **Settings → Accounts → Advanced**, set the **API base URL** to your Enterprise
host's API, e.g. `https://ghe.example.com/api/v3`. Register the OAuth App on your
Enterprise instance and use its client ID.

## Option B — personal access token

If you'd rather not register an OAuth App:

1. Create a token at <https://github.com/settings/tokens> with the **`repo`** scope
   (and **`notifications`** if you want the notifications features).
2. In gbar: **Settings → Accounts**, pick **Access token**, and paste it.

Tokens and OAuth credentials are stored in the **macOS Keychain**, never in plaintext
on disk.

## Building from source

```bash
git clone https://github.com/jaylann/gbar
cd gbar
just bootstrap   # git hooks + local xcconfigs (client ID stays blank — you sign in at runtime)
just gen
just run
```
