# Changelog

One entry per milestone. The version lives in `build.zig.zon`.

## 0.1.0 (M1): read-only Teams client

- `teams-zig whoami`, `teams-zig chats` and `teams-zig messages <conversation-id>` against the Teams Chat Service, with a one-line hint for each error you can act on.
- `scripts/teams-token.fish` signs in through agent-browser in a dedicated profile and stores the skype token and region in the login keychain (service `teams-zig`). Rerun it when the token expires, after about a day.
- `src/macos/`: hand-written CoreFoundation and Security bindings and a keychain wrapper, the start of a Zig-friendly macOS API.
- Test mode: set `TEAMS_ZIG_SKYPE_TOKEN` and `TEAMS_ZIG_REGION` to skip the keychain. Less secure, since child processes can read the environment.
- Read-only: nothing writes to Teams.

Known issue: each new build of teams-zig gets a keychain "allow access?" prompt, because macOS's partition list trusts builds one at a time. Use test mode to avoid it.

Needs: macOS with the SDK (Command Line Tools), Zig 0.17, agent-browser and an org (work/school) Teams account.
