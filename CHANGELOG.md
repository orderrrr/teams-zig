# Changelog

One entry per milestone. The version lives in `build.zig.zon`.

## 0.3.0 (M3): names and watch

- `teams-zig messages <chat>` takes a chat's exact name as `chats` shows it (case doesn't matter; quote names with spaces), or its id as before. If several chats share the name, it lists them with their ids and reads none.
- `teams-zig chats` marks chats with unread messages with `*`: someone else wrote after the newest message you've read. Messages the service posts itself, such as call recordings, don't count.
- `teams-zig watch` prints new messages from your 50 newest chats as they arrive, polling every 10 seconds. Throttling, server errors and network drops make it wait and retry, up to 5 minutes apart; an expired token stops it. Ctrl-C stops it.
- The 60-second "no answer" limit now applies to each batch of requests (each `watch` poll), not the whole command.
- Still read-only: every request is a GET, so `watch` reads by polling and never marks anything as read.

## 0.2.0 (M2): read-only improvements

- `teams-zig chats` names the other person in 1:1 chats instead of `(no topic)`, using the last sender, or the chat's recent messages when you spoke last. At most 40 chats get that recent-messages lookup per run, to stay inside the 60-second limit; any past that still show `(no topic)`.
- `teams-zig chats [count]` (up to 100) and `teams-zig messages <id> [count]` choose how many to show; both default to 50.
- Still read-only: nothing writes to Teams.

## 0.1.0 (M1): read-only Teams client

- `teams-zig whoami`, `teams-zig chats` and `teams-zig messages <conversation-id>` against the Teams Chat Service, with a one-line hint for each error you can act on.
- `scripts/teams-token.fish` signs in through agent-browser in a dedicated profile and stores the skype token and region in the login keychain (service `teams-zig`). Rerun it when the token expires, after about a day.
- `src/macos/`: hand-written CoreFoundation and Security bindings and a keychain wrapper, the start of a Zig-friendly macOS API.
- The client reads the token through `/usr/bin/security`, which the keychain items already trust, so rebuilding teams-zig never brings up an "allow access?" prompt.
- Test mode: set `TEAMS_ZIG_SKYPE_TOKEN` and `TEAMS_ZIG_REGION` to skip the keychain. Less secure, since child processes can read the environment.
- Read-only: nothing writes to Teams.
- A command that gets no answer from the Chat Service within 60 seconds stops with a network hint, rather than hanging (Zig 0.17's HTTP client has no read timeout and ignores its connect timeout).

Known issues:
- A per-app firewall such as Little Snitch sees each new build as a new app and holds its connection until you approve it, so the first runs after a rebuild can appear to hang. Approve teams-zig in the firewall; the 60-second limit ends a held run with a network hint.

Needs: macOS with the SDK (Command Line Tools), Zig 0.17, agent-browser and an org (work/school) Teams account.
