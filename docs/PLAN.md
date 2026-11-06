# Plan

## M1: read-only Teams client

Goal: `teams-zig whoami`, `teams-zig chats` and `teams-zig messages <conversation-id>` work against a real org account, using a skype token and region that `scripts/teams-token.fish` put in the login keychain.

Protocol facts come from `inspo/teams-api/docs/findings.md`.

### Layout

- `src/macos/`: hand-written Security and CoreFoundation bindings, plus a keychain wrapper. The seed of a Zig-friendly macOS API; it holds only what M1 uses.
- `src/chat/`: the Chat Service client and its response types.
- `src/root.zig`: re-exports. `src/main.zig`: the CLI.
- `scripts/teams-token.fish`: sign-in and token capture. Not part of the Zig build.

### Keychain contract

The script and the client share one keychain service name, `teams-zig`, with two accounts:

- `skype-token`: the skype token from the web client's `x-skypetoken` request header.
- `region`: `amer`, `emea` or `apac`.

### Chunks

1. **M1.1 package skeleton.** `build.zig`, `build.zig.zon` with no dependencies, `src/root.zig`, `src/main.zig` printing usage, and a passing `zig build test`.
2. **M1.2 CoreFoundation bindings.** `extern` declarations for the CFString, CFData, CFDictionary and CFRelease calls the keychain needs, and the framework links in `build.zig`. A test round-trips a CFString.
3. **M1.3 Security bindings.** `extern` declarations for `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete` and the `kSec*` constants they use.
4. **M1.4 keychain wrapper.** `read(service, account)` and `write(service, account, value)` over the bindings, with OSStatus mapped to a Zig error set. Tests use a throwaway service name and fake values, and delete what they write. The rebuild prompt question is settled in M1.7.
5. **M1.5 token script: sign-in and cookie.** agent-browser opens Teams for interactive sign-in, then reads the skype token from the `x-skypetoken` request header. A live probe found no `skypetoken_asm` cookie. *Needs your sign-off: new outside tool, and it runs a live sign-in.*
6. **M1.6 token script: region.** Detect the region from the page's `chatsvc/{region}` or `{region}.ng.msg.teams.microsoft.com` requests. If agent-browser can't see network requests, park it and fall back to asking for the region once.
7. **M1.7 token script: keychain write.** Store both values with `security add-generic-password -U -A` under the contract above. `-A` lets the client read them without a prompt after every rebuild. Items made by `security` are already readable by any process through `security` itself, so this barely widens exposure. A self-signed certificate with codesign is the tighter option for later.
8. **M1.8 Chat Service request.** Build the base URL from the region, and send GET requests with the `Authentication: skypetoken=…` header using `std.http.Client`. Map 401 to a distinct "token expired, rerun the script" error.
9. **M1.9 whoami.** `GET /users/ME/properties`, then parse the `userDetails` JSON string for `name` and `upn`.
10. **M1.10 list chats.** `GET /users/ME/conversations?view=mychats&pageSize=n`. Parse `id`, `threadProperties.threadType`, `threadProperties.topic` and `properties.lastimreceivedtime`, and filter out system streams.
11. **M1.11 read messages.** `GET /users/ME/conversations/{id}/messages?pageSize=n&view=superchat`, then follow `_metadata.backwardLink`. Parse id, type, sender, display name, content and times, and mark deleted messages (`properties.deletetime`).
12. **M1.12 CLI wiring.** `whoami`, `chats` and `messages` commands that read the keychain and print plain text.
13. **M1.13 live check.** Run all three commands against your account, which is read-only. Then run the milestone gate.

### Out of M1

Sending, editing, deleting and reactions (M2). Search, profiles, files and transcripts, which need Bearer tokens (later). HTML-to-text rendering beyond stripping tags.
