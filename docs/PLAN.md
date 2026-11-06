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

## M3: watch for new messages

Goal: `teams-zig messages` takes a chat's name as well as its id, `teams-zig watch` prints new messages from all your chats as they arrive, and `chats` marks chats with unread messages. Still read-only: every request is a GET, so nothing registers an endpoint, opens a subscription or marks anything as read. The zero-writes rule in CLAUDE.md still holds.

Added at the owner's request before watch: choose a chat by its exact name.

### Chunks

0. **M3.0 `messages <name or id>`.** An argument that starts with digits and a colon (`19:…`, `48:notes`) is an id, as today. Anything else is a chat name, matched exactly but ignoring ASCII case, against the names `chats` shows: the topic, or the other person in a 1:1 chat. It searches your 100 newest chats, using the free names first and making M2's per-chat lookups only if none of those match, so a match on a free name costs one GET and a miss can take as long as `chats 100`. One match reads that chat; none says so; two or more list them with their ids and exit without reading messages. Pure matching with tests; `chats` keeps printing ids.
1. **M3.1 unread state, checked live.** See whether `/users/ME/conversations` carries a read marker (most likely `properties.consumptionhorizon`, holding the last-read message id and time) and its shape: keys and format only, never content. If it isn't there, unread marks are dropped from M3 and noted here.
2. **M3.2 unread in `chats`.** Parse the read marker and compare it with the last message's time; `chats` shows a `*` on chats with unread messages. Pure comparison with tests.
3. **M3.3 a watchdog per request.** Today the watchdog ends the whole command after 60 seconds, which a long-running `watch` can't live with. It becomes a per-request deadline: each request that gets no answer within 60 seconds still stops the command with the network hint.
4. **M3.4 change detection.** A pure function that compares two conversation lists and returns the chats whose last message time moved forward. Tests with canned lists: new chat, unchanged, moved, older.
5. **M3.5 `teams-zig watch`.** Every 10 seconds, list the 50 newest conversations (one GET). For each chat that changed, read its newest page (one GET) and print the messages newer than the last one seen, with the chat's name, through `writeVisible`. Ctrl-C ends it. The first poll only records where things stand; it prints nothing old.
6. **M3.6 limits.** At most 10 chats read per poll so a burst can't flood the service; a 429 or 5xx backs off (doubling, up to 5 minutes) instead of stopping; an expired token stops with the token-script hint.
7. **M3.7 live check, 0.3.0 and gate.** Read-only live check (counts only), CHANGELOG, then the milestone gate.

### Out of M3

Sending or any other write. Push notifications through an endpoint subscription (registering one is a write). Search. Desktop notifications.

## M4: readable messages (decided, not yet planned)

Decided by the owner on 2026-11-06, after `messages 48:notes` printed `\x0d` and lost its line breaks. The detailed chunk plan comes after M3 and needs approval.

- `RichText/Html` content renders as Markdown instead of having its tags stripped. `<b>`/`<strong>` → `**`, `<i>`/`<em>` → `_`, `<s>` → `~~`, `<code>` → `` ` ``, `<pre>`/code blocks → fenced blocks, `<a href>` → `[text](url)`, lists → `- `/`1. `, `<blockquote>` → `> `, `<p>`/`<br>`/`<div>` → line breaks. The HTML's own whitespace collapses and `\r` is dropped. Underline becomes plain text and emoji images use their alt text.
- Layout: a header line per message (time and sender), then the body, then a blank line between messages. Bodies aren't indented, since an indent means a code block in Markdown.
- Changed by the owner on 2026-11-06 after seeing it: the compact layout stays. Each message starts on its `time  sender: ` line, a multi-line body continues on the lines below, and there's no blank line between messages.
- Literal `*` and `_` in typed text aren't escaped at first.
- M3 stays as approved: `watch` prints through today's `writeText` until M4.
- No JSON or HTML output; Markdown is the format.

### What the messages hold

Measured live over the newest 50 messages of 30 chats (tag and attribute names and counts only): `p` 1872, `br` 773, `span` 439 (mostly `@`mentions), `strong` 149, `blockquote` 130 (125 are quoted replies), `img` 110 (81 pasted images, 28 emoji), `a` 106, `li` 21, `code` 17, `pre` 12, `div` 11, `ul` 5, `ol` 2, `h2`/`h3` 1 each. About 1100 lines of HTML content hold a `\r`.

### Chunks

Planned 2026-11-06 under the owner's instruction to plan, review and complete M4, and revised after a plan review. Plan decisions beyond the owner's list: `s`/`strike`/`del` → `~~`, `h1`–`h3` → `#`, images other than emoji → `[image]`.

Safety holds throughout: every byte from the message (text, `href`, `alt`, `<pre>` content) goes through `writeVisible`; only the writer's own markers (`**`, `` ` ``, `> `, `- `, fences) are written raw. Wherever a byte is dropped or collapsed (`\r`, HTML whitespace), the text is split there and each piece is written separately, never joined in a buffer, so a C1 control can't form across the gap. Numeric entities (`&#27;`) are not decoded.

1. **M4.1 HTML reader.** A pure iterator over a message's HTML yielding text runs, entities and tags (name, opening or closing, and an attribute lookup for `href`, `alt` and `itemtype`). The first `>` ends a tag, as today (Teams writes `>` in values as `&gt;`). `writeText` switches to it with unchanged output; it keeps its guarantees (always moves forward, an unterminated tag is dropped, unknown entities pass through). Tests, including `<a href="x>y">` degrading harmlessly.
2. **M4.2 Markdown writer: lines and whitespace.** A writer that collapses the HTML's own whitespace, trims it at every line start (so no line becomes an indented code block), drops `\r`, turns `p`, `div` and `br` into line breaks, writes at most one blank line in a row, and trims blank lines at both ends. One line-start routine writes every line's prefix (empty for now). Existing `writeText` expectations change here, since line breaks now appear. Tests per rule, plus `\xc2\r\x9b` and `\xc2\n\x9b` staying escaped.
3. **M4.3 inline markup.** `b`/`strong` → `**`, `i`/`em` → `_`, `s`/`strike`/`del` → `~~`, `code` → `` ` ``, `u` → plain, `a href` → `[text](url)`. An opening marker waits for the first non-space text (one pending marker), so empty markup writes nothing and edge spaces sit outside the markers. Mentions stay plain text. A test with `\x1b` in an `href`.
4. **M4.4 quotes.** `blockquote` → `> ` per level at every line start, depth bounded at 8 (deeper shown at 8). Tests include a reply quote in Teams' shape (`itemtype` ending `/Reply`, a `strong` sender, a `p` preview; fake values).
5. **M4.5 lists.** `ul`/`ol` → `- ` and `1. `, nested lists indented two spaces per level, a stack bounded at 8 (deeper shown at 8); `br` inside `li` continues the item. Tests include a list inside a quote.
6. **M4.6 code blocks.** `pre` → a fenced block, whitespace kept and `\r` still dropped, every line still prefixed (quotes stay quoted). Tests include `pre` inside a quote and `\xc2\r\x9b` inside `pre`.
7. **M4.7 headings and images.** `h1`–`h3` → `#`, `##`, `###`. An `img` whose `itemtype` ends `/Emoji` → its `alt` text; any other `img` → `[image]`. Tests with `\x1b` in `alt`.
8. **M4.8 layout.** `messages` and `watch` print a header line per message (`time  sender`, through `writeVisible`, sender falling back to the MRI, then "(unknown sender)"; `watch` adds `[chat] ` first), then the body, then a blank line after every message, the last included. Plain `Text` messages drop `\r` (split, as above) and get the same layout; `(deleted)` and `[type]` bodies sit under their header the same way.
9. **M4.9 live check, 0.4.0 and gate.** Read-only live check, counts only: no `\x0d`, no leftover tags (`<` followed by one of the measured tag names and `>` or a space), escaped control bytes counted, emoji alt outputs about equal to emoji images, headers equal to messages. CHANGELOG with the new `messages` and `watch` layout under "Changed", then the milestone gate.

### Out of M4

Sending or any other write. Escaping, so body lines starting with `#`, `>`, `- ` or `1. ` read as Markdown, and `` ``` `` inside a code block ends it early. Leading spaces in plain `Text` messages are kept. Colours. JSON or HTML output. Short local times, an `unread` command and `help` (candidates for later).

## M3 gate

**Round 1** (mr-review, STYLE.md and Tiger Style reviews of `2818892..20fc333`):
- A chat named with a leading time, like "9:30 Standup", was taken for an id and got a 404; ids never hold whitespace, so anything with a space is a name (`d3d85b9`).
- `Seen` grew without bound over a long `watch`; it now has a fixed `chat_count_limit` (1024). Decided: when full, its marks fold into `mark_first`, so nothing shown comes back, at the cost of skipping an older unshown message in an unread chat after 1000+ distinct chats. Its tests caught two regressions on the way: a new chat could start below `mark_first`, and first-poll chats were raised to it (`0471cb9`).
- Style fixes: fixed-size first-pass names, `errdefer` in `Seen.record`, `printNewMessages` asserts `seen.changed`, comptime asserts tying the backoff to the poll and a poll's reads to the watchdog; a comment that `watch` reads one page per changed chat (`48e4590`, `0471cb9`, `d3d85b9`).

**Round 2:**
- `findChat` asserted the service sent at most 100 chats, which the service decides; `Client.conversations` now keeps at most what it asked for (`8bd2326`).
- `Seen` allocates nothing after `init`: ids are copied into storage reserved up front, and an over-long id is `ConversationIdTooLong` with a hint (`8bd2326`).
- `mark_first`'s doc, a nested condition, a comptime assert tying `watch`'s poll to `Seen`, `known_names_buffer` (`4ef3201`, `8bd2326`).

**Round 3:** `Seen`'s starting values at declaration (STYLE 3.6), a `u32` byte counter with its bound asserted, `fold`'s precondition asserted (`452ee01`).

**Round 4:** a post-clear assert in `fold` removed as padding (STYLE 4.5 over Tiger) (`7d10199`).

**Round 5:** all three reviews found nothing new. Gate passed. M3 resolved.

Live after the rounds (read-only, counts only): `watch` printed real incoming messages; `chats 100` lists 94; chats open by exact name, upper-cased names match, and a missing name ends with the hint.

Not done in M3: the self-chat row in `chats` stays as `notes (no topic) 48:notes`; the owner chose to keep it.


## M4 gate

**Round 1** (mr-review, STYLE.md and Tiger Style reviews of `d6f219f..ee877dc`):
- An empty heading put `## ` on the next paragraph, and an empty item in a nested list gave the outer item's next line a stray `- `; both fixed and tested (`169ac60`).
- Owner request during the gate: the compact layout stays (`time  sender: ` then the body, continuing below), not a header line, body and blank line (`7bd0ae3`).
- STYLE fixes: an optional heading level, no trivial `Reader.init`, one optional code-block state, one record of open marks, no flag picking two prefix paths (`a59e49f`).
- Tiger fixes: compound conditions split, sized integers, no aliases, positive flags, asserts on values the writer controls (`5872606`).

**Round 2:** `tag` dispatches once to open and close handlers, so no handler takes a flag picking between two paths (STYLE 5.5); spacing uses early returns (STYLE 5.4); no alias to the code-block state, and a written mark is asserted to be open (`abf2df2`).

**Round 3:** helpers split from one caller carry its name (`ac2312e`).

**Round 4:** the same naming applied to every single-caller helper in `markdown.zig`; two one-caller helpers folded into their callers (`fef24e0`).

**Round 5:** mr-review and STYLE.md found nothing. Tiger raised whether the call-history naming rule reaches a type's own methods (`Output.text`, `entity`, `tag`, `finish`, called only by `writeHtml`; `List.markerWidth`). Parked for the owner: the literal reading renames the type's whole interface.

Owner decision: the call-history prefix is for helpers split out of a function; a type's methods driven from outside are its interface (STYLE 1.6, `a6702e6`).

**Round 6:** all three reviews found nothing new under the amended rule. Gate passed. M4 resolved.

Live after each round (read-only, counts only): about 505 messages across 11 chats (48:notes and the 10 newest) render with no `\x0d`, no raw control bytes and no leftover tags; code fences pair up.

Decided along the way: compound conditions, aliases and flag parameters are refactored away rather than waived; the incremental compiler was tried at the owner's request and isn't usable on arm64 macOS with Zig 0.17 (it crashes, and the self-hosted backend emits a binary that won't run), so builds stay as they are (about 3.3 s per rebuild).

## Polish: times, unread, escaping (0.5.0)

Asked for by the owner on 2026-11-06 as a polish pass with a review before M5 (sending). It stays read-only. Plan decisions:

- Times are shown in local time, with the time zone taken from CoreFoundation's system time zone and the offset found for each moment, so daylight saving is handled. A time from the same local day shows as `14:05`, one from the previous six days as `Mon 14:05`, and anything older as `2026-10-12 14:05`. A timestamp that doesn't parse is shown as it came.
- `unread` reads your 50 newest chats. For each unread one (the same test as the `*` in `chats`), up to 10 chats, it reads that chat's 20 newest messages and prints the text messages newer than your read marker, in `watch`'s `[chat] time  sender: body` form. More than 10 unread chats ends with a line saying how many weren't shown, and none prints `No unread messages.` It never marks anything as read.
- In HTML messages, typed text at the start of a line that would read as a Markdown block gets a `\` in front: `#`, `>`, `-`, `*` or `+` followed by a space, digits followed by `.` or `)` and a space, and `` ``` ``. Inline `*` and `_` stay as typed. Code block contents and plain `Text` messages are unchanged.

### Chunks

1. **P.1 time zone.** CoreFoundation's offset from GMT at a given moment, in `macos.core_foundation`.
2. **P.2 short times.** Parsing the service's ISO timestamps and writing them in the short local form. Tests with fixed times and offsets.
3. **P.3 times in output.** `chats`, `messages` and `watch` use the short form, and `chats` pads the column to its widest form.
4. **P.4 unread.** The `unread` command, sharing `watch`'s message printing.
5. **P.5 escaping.** Line-start escaping in the Markdown writer.
6. **P.6 0.5.0 and gate.** A read-only live check (counts only), CHANGELOG, the version, and the three reviews, recorded below.

### Out of the polish pass

Anything that writes to Teams. `` ``` `` inside a code block still ends it early. Colours. `help`, which the usage text already covers.

## Polish gate

All six chunks done; live check (read-only, counts only) over 11 chats: every header in a short form, no ISO timestamps left, no `\x0d`, no leftover tags, fences paired; 28 typed line starts escaped (16 `* ` bullets, 12 numbered lines); `unread` agreed with the `*` count in `chats`.

- **Round 1.** mr-review: the changelog claimed escaping for every message (plain `Text` and inline `*`/`_` aren't; now listed as known limits); `printMessagesAfter` had no test (added). STYLE 1.6: `parseIso`'s helpers carry its name. Tiger Style: `Command.run` went past 70 lines (the chats arm moved out), options structs for `short_time.write` (`Times`) and the date maths (`Date`), units last (`now_seconds`), compound conditions split, `@divFloor`/`@mod` and `s_per_min`, `textEscapeIndex` returns `?u32` with CommonMark's 9-digit cap, added asserts (whole-second zone offsets, date ranges, `unread`'s counts), an alias removed.
- **Round 2.** mr-review: a test for the 9-digit cap, another alias, unsigned time parts. STYLE 5.4 over Tiger's else-if rule: the day prefix moved to `writeDay` with guard clauses, which satisfies both. Tiger Style: compound conditions in the escaping, qualifiers last (`at_day`), `parseIso` asserts its result, helpers split from `run` carry its name (`runChats`, `runUnread`), test constants in seconds.
- **Round 3.** mr-review: `writeDay`'s comment read as "yesterday". STYLE 1.6: `writeDay`'s helpers carry its name. Tiger Style: the time is computed after the day is written, close to its use.
- **Round 4:** all three reviews found nothing new. Gate passed. Polish pass resolved at 0.5.0.

## M5: send messages, written in Markdown (planned, needs approval)

Asked for by the owner on 2026-11-06: sending, with Markdown turned into Teams' format. Testing uses the owner's own account, sends only to their notes chat (`48:notes`), and is kept to a minimum.

Protocol (from `inspo/`, facts only): `POST /v1/users/ME/conversations/{id}/messages` with JSON `content` (HTML), `messagetype: "RichText/Html"`, `contenttype: "text"`, `clientmessageid` (a fresh number) and `imdisplayname` (your name); the answer carries `OriginalArrivalTime`, the new message's id.

Plan decisions:

- `teams-zig send <chat> <text>`: `<chat>` as for `messages` (an exact name or an id), the text as one argument (quote it). No stdin, no files, no editing or replies.
- A hard-coded allow list holds only `48:notes`. Any other chat, however chosen, fails with `error.SendNotAllowed` before a request is made. Widening it is a later owner decision.
- A send is never retried, since a retry after a lost answer could post twice. Any failure is reported and the command stops.
- Text over 16 KiB is refused before any request (Teams' own limit is near 28 KB of HTML, and escaping grows the text).
- Markdown supported, mirroring what `messages` shows: paragraphs and line breaks, `**bold**`, `_italic_` and `*italic*`, `~~strike~~`, `` `code` ``, `[text](url)` (only `http`/`https` links; others stay as text), `- ` and `1. ` lists (one level), `> ` quotes, `` ``` `` fences and `#`–`###` headings. A `\` before punctuation keeps it literal. All text is HTML-escaped (`&`, `<`, `>`, `"`), so nothing typed becomes markup.
- Tests check that rendering the produced HTML back with `markdown.writeHtml` gives the Markdown typed, for each supported form.
- The zero-writes rule in CLAUDE.md stays as written; the owner's lift covers only sends to `48:notes` during M5.

### Chunks

1. **M5.1 Markdown inline to HTML.** Escaping, bold, italic, strike, code, links, backslash escapes, in a new `src/chat/teams_html.zig`. Round-trip tests.
2. **M5.2 Markdown blocks to HTML.** Paragraphs, line breaks, lists, quotes, fences, headings. Round-trip tests.
3. **M5.3 `Client.send`.** The POST, its JSON body built with `std.json`, no retry, the answer's id parsed. Tests on the body and the answer with fake values; no network.
4. **M5.4 `send` command.** Parsing, the 16 KiB cap, the allow list checked after the chat is resolved and before the request, the new message's time printed. Tests for refused chats and sizes.
5. **M5.5 one live send.** One message to `48:notes` holding each supported form, read back with `messages 48:notes 1` and compared by counts; at most one retry of the check, never of the send.
6. **M5.6 0.6.0 and gate.**

### Out of M5

Sending anywhere but `48:notes`. Editing, deleting, reacting, replies, mentions, files and images. Marking as read. Nested lists.
