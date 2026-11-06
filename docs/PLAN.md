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

- `skype-token`: the skype token the web client posts to `/v1/skypetokenauth`.
- `region`: `amer`, `emea` or `apac`.

### Chunks

1. **M1.1 package skeleton.** `build.zig`, `build.zig.zon` with no dependencies, `src/root.zig`, `src/main.zig` printing usage, and a passing `zig build test`.
2. **M1.2 CoreFoundation bindings.** `extern` declarations for the CFString, CFData, CFDictionary and CFRelease calls the keychain needs, and the framework links in `build.zig`. A test round-trips a CFData (nothing reads CFStrings back).
3. **M1.3 Security bindings.** `extern` declarations for `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete` and the `kSec*` constants they use.
4. **M1.4 keychain wrapper.** `KeychainItem.read(gpa)` and `KeychainItem.write(value)` over the bindings, where a `KeychainItem` names the service and account, with OSStatus mapped to a Zig error set. Tests use a throwaway service name and fake values, and delete what they write. The rebuild prompt question is settled in M1.7.
5. **M1.5 token script: sign-in and token.** agent-browser opens Teams for interactive sign-in, then reads the skype token from the startup POST to `/v1/skypetokenauth` (form body), falling back to the `x-skypetoken` header, which only some loads send. Live probes found no `skypetoken_asm` cookie. *Needs your sign-off: new outside tool, and it runs a live sign-in.*
6. **M1.6 token script: region.** Detect the region from the page's `chatsvc/{region}` or `{region}.ng.msg.teams.microsoft.com` requests. If agent-browser can't see network requests, park it and fall back to asking for the region once.
7. **M1.7 token script: keychain write.** Store both values with `security add-generic-password -U -A` under the contract above. `-A` opens the access list, but it does not stop prompts: macOS also keeps a partition list per item, which trusts Apple tools plus each build you click "Always Allow" for, and every rebuild has a new hash. Settled after the gate: the client reads the items through `/usr/bin/security`, which they already trust, so no build is prompted. `KeychainItem` stays as part of the macOS API.
8. **M1.8 Chat Service request.** Build the base URL from the region, and send GET requests with the `Authentication: skypetoken=…` header using `std.http.Client`. Map 401 to a distinct "token expired, rerun the script" error. Redirects are refused so the token never leaves the Chat Service host (Zig 0.17 std never sends `privileged_headers`, so they can't carry it).
9. **M1.9 whoami.** `GET /users/ME/properties`, then parse the `userDetails` JSON string for `name` and `upn`.
10. **M1.10 list chats.** `GET /users/ME/conversations?view=mychats&pageSize=n`. Parse `id`, `threadProperties.threadType`, `threadProperties.topic` and `properties.lastimreceivedtime`, and filter out system streams.
11. **M1.11 read messages.** `GET /users/ME/conversations/{id}/messages?pageSize=n&view=superchat`, then follow `_metadata.backwardLink`. Parse id, type, sender, display name, content and times, and mark deleted messages (`properties.deletetime`).
12. **M1.12 CLI wiring.** `whoami`, `chats` and `messages` commands that read the keychain and print plain text.
13. **M1.13 live check.** Run all three commands against your account, which is read-only. Then run the milestone gate.

### Out of M1

Sending, editing, deleting and reactions (M2). Naming the other person in 1:1 chats, which `chats` shows as `(no topic)` (M2: `/threads/{id}/members` sometimes omits names for 1:1 chats, and the profile API needs a Bearer token). Search, profiles, files and transcripts, which need Bearer tokens (later). HTML-to-text rendering beyond stripping tags.

## M1 gate

**Round 1** (mr-review, STYLE.md and Tiger Style reviews of `0768eea..7a779c7`):
- Message paging asserted on server-controlled page counts; now capped at `page_count_max` and tested with canned pages (`51f36ed`, `64ce135`).
- The skype token could follow a cross-domain redirect. Redirects are refused; Zig 0.17 std never sends `privileged_headers`, so they couldn't carry the token (`51f36ed`).
- Failed requests gave a bare error and stack trace; `main` now prints a hint per known error, with `NotFound` for 404 (`51f36ed`).
- The token script spun for 5 minutes when agent-browser failed; it now exits at once (`5316e10`).
- Duplicate list types merged into `Owned(T)`, one shared `ParseError` (`51f36ed`).
- Style fixes: asserts on outside input moved to boundaries, optionals for absent strings, allocator naming, line length, explicit options, response-size cap, names (`6f913f0`, `51f36ed`).
- Decided: camelCase functions (STYLE 1.6, `21d3d82`); 1:1 chat names for M2; versioning per milestone (`c02f135`).

**Round 2** (reviews of the round-1 fixes):
- `writeText` crashed on an unterminated `<` through a deferred progress assert; fixed and tested (`e4187a8`).
- Style fixes: CoreFoundation and keychain operations as methods, `Dictionary.Entries`, more asserts, remaining explicit options, invalid-data tests (`449ef41`).
- Decided: JSON-mirror fields keep their key names (STYLE 1.6 carve-out); gate records live here.

**Round 3** (reviews of the round-2 fixes):
- `writeText` could still trip its deferred progress assert when a write failed, so `messages | head -1` panicked; fixed and tested (`a3f45ca`).
- Style fixes: `KeychainItem.zig` as a flat type file, `Command.parse`/`run`, preallocated message list, more invariant asserts, explicit build options, invalid-input tests (`8914fe7`).
- Decided: `extern` declarations keep C symbol names (STYLE 1.6); assertion density is met with real invariants, never padding (STYLE 4.5).

**Round 4:** padding asserts removed under the amended STYLE 4.5, borrowed fields documented, NULL `CFDataGetBytePtr` handled for empty items, `ssl_key_log` explicit (`6af8720`, `e62afa7`).

**Round 5:** a dropped connection was reported as an oversized response; fixed and named `SendFailed` (`a2e96ce`, `6cf6c2a`). `Client.chats` renamed `conversations` in code; the CLI command stays `chats` (`dd267d4`).

**Round 6:** std's `fetch` crashes when a connection drops mid-body, so `getUrl` reads the body itself; terminal escapes in server text are shown as `\xNN`; every error gets a hint through an exhaustive switch (`7dbf12c`, `6891574`). Test mode added at the owner's request (`bec78b3`); zero writes to Teams made a standing rule (`b2112c4`).

**Round 7:** short bodies, truncated chunks and compressed-body paths fixed by asking for identity encoding (with a workaround for std writing a broken `accept-encoding` header); UTF-8 C1 controls shown; tokens with CR/LF rejected (`0e79d77`, `c1941df`, `50bded4`).

**Round 8:** a C1 control could be rebuilt across a dropped HTML tag; exhaustive end-of-body check (`5ea4621`).

**Round 9:** server links could inject into the HTTP request line; refused. Token copies zeroed (`8044adb`).

**Rounds 10–13:** missing-region hint, a 60-second watchdog for held connections that starts after `connect` and stands down once the service answers, region hint fit for both modes, small placement fixes (`d58164a` … `2b4b8fa`). The connect "stalls" turned out to be Little Snitch holding each new build (`da20ffa`).

**Round 14:** `std.Uri.parse` can't fail after the link checks, so its catch is unreachable; `checkLink` extracted (`806542c`).

**Round 15:** all three reviews found nothing new. Gate passed.

Decided along the way: STYLE 1.6 (camelCase, JSON and extern name exceptions), STYLE 4.5 (assertion density from real invariants only).

**After the gate (owner decision):** normal runs read the keychain through `/usr/bin/security`, so rebuilds no longer prompt (`33a700c`). **Round 16** named `security`'s exit status, reused `KeychainReadError`, and corrected the watchdog comment and the locked-keychain hint (`730a860`). **Round 17:** no clear violations from any review. M1 resolved.

Carried to M2 as optional polish: say why `security`'s "not found" exit status is 44 (the low byte of errSecItemNotFound); "no access prompt" wording next to the unlock-dialog comment; reflow the watchdog comment; drop or use `security.Status.duplicate_item`, which nothing references.

## M2: read-only improvements

Goal: `chats` names the other person in 1:1 chats, `chats` and `messages` can go back further than the newest 50, and M1's carried polish is done. Everything stays read-only: the zero-writes rule in CLAUDE.md still holds, and every request is a GET.

### Chunks

1. **M2.1 M1 polish.** Why `security`'s "not found" exit status is 44; "no access prompt" wording; reflow the watchdog comment; drop `security.Status.duplicate_item`.
2. **M2.2 who am I, as an MRI.** Find the signed-in user's MRI (`8:orgid:<uuid>`) from a read we already make, most likely `skypeName` in `/users/ME/properties`; check its shape live (keys and format only) before relying on it.
3. **M2.3 last sender per conversation.** Parse the `lastMessage` sender MRI and display name that `/users/ME/conversations` already returns, at no extra request.
4. **M2.4 members (dropped).** A live check showed `/threads/{id}/members` gives no display names in 1:1 chats (`userDisplayName` is null), so it can't name anyone.
5. **M2.5 1:1 names in `chats`.** For a 1:1 chat, show the other person: the last sender's name when that isn't you (free), otherwise the newest sender who isn't you among that chat's 20 most recent messages (one GET). Live: all 41 chats named in 13 s. Names still go through `writeVisible`.
6. **M2.6 counts.** `teams-zig chats [count]` and `teams-zig messages <id> [count]`: optional, bounded counts (conversations follow `backwardLink` pages the way messages already do). Defaults stay 50.
7. **M2.7 live check and gate.** Read-only checks in normal and test mode, then the milestone gate.

### Out of M2

Anything that writes to Teams. Search (needs a second token). Profiles and files.

## M2 gate

**Round 1** (mr-review, STYLE.md and Tiger Style reviews of `fb6fc3f..799795d`):
- The recent-message scan could name a bot or a system event's sender as the other person; only user-written messages count now, in the pure, tested `otherWriterName` (`ec6343b`).
- A long chat list could outrun the 60-second watchdog; at most 40 name lookups per run, chats past that show `(no topic)` (`9ae2e2c`, CHANGELOG `679e9bc`).
- One unreadable chat failed the whole list; a lookup that gets 404, another unexpected status or unexpected JSON now leaves that chat unnamed (`9ae2e2c`).
- Style fixes: one owner for looked-up names, optionals instead of `''`, comptime asserts tying the counts to their types and the watchdog, edge tests for counts (`ec6343b`, `9ae2e2c`).

**Round 2** (reviews of the round-1 fixes):
- A lookup could follow several pages, so 40 lookups weren't 40 requests; lookups now read exactly one page through `Client.recentMessages` (`cd1cfe3`).
- 429 and 5xx during a lookup stop the command instead of leaving every later chat unnamed (`cd1cfe3`).
- A conversation's last sender counts only when the last message is user-written, the same rule as the scan (`cd1cfe3`).
- Style fixes: the lookup budget lives in the caller's loop, `nameSource` is a pure tested decision, more invariant asserts and null-name tests (`cd1cfe3`).

**Round 3:** the skip-or-stop rule became the pure, tested `lookupErrorSkips`; `LastMessage.messagetype` optional; page constants and parameters follow `_limit` for a fixed ceiling, `_max` for a per-call cap (`4251f61`).

**Round 4:** a test for a last message with a null or missing message type (`b7aad5e`); `page_item_count_limit` follows the same naming (`df6a31a`).

**Round 5:** `main.zig`'s fixed count ceilings renamed to `_limit` too; byte sizes and durations keep `_max` (`dbcb506`).

**Round 6:** all three reviews found nothing new. Gate passed. M2 resolved.

Live after each round (read-only, counts only): 41 of 41 1:1 chats named in 11–14 s; `chats 100` lists 94 in about 17 s; `messages 200` returns 200; `chats 0` prints usage.
