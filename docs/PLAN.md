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

## M5: send messages, written in Markdown

Asked for by the owner on 2026-11-06: sending, with Markdown turned into Teams' format. Testing uses the owner's own account, sends only to their notes chat (`48:notes`), and is kept to a minimum. Plan approved by the owner on 2026-11-07, on the condition that the live send (M5.5) waits for their go-ahead at that moment; until then nothing is sent.

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

### M5 live send

On 2026-11-07, with the owner's go-ahead at that moment: one `send` to `48:notes` holding every supported form. Read back with `messages 48:notes 1`, each form came back as typed; the only differences are the blank lines `messages` always puts after lists and around quotes. Nothing was retried. Reads checked live first, after the GET path's refactor in M5.3.

## M5 gate

- **Round 1.** mr-review: the watchdog's timeout hint now says to check the chat after a send, like the other send-failure hints; a link address keeps paired brackets (`Foo_(bar)`); an italic closes only with the byte that opened it. Owner-reported during the gate: `messages` drew the blank line before a quote with the quote's `>`; fixed, and an escaping test that had recorded the wrong output corrected. STYLE: the inline writer became an `Inline` state type with guard-clause helpers (no sentinel `0`, no deep nesting), `Block` a union carrying the code block's line count, one `before` enum for two bools. Tiger Style: `u32` indexes, helper preconditions asserted, a `NewMessage` options struct, explicit JSON write options, the id buffer sized from `maxInt(u64)`, the answer's id range-checked, the HTML capped at 28 KiB before sending, `@divFloor`, `send_chat_ids_allowed`, GET or POST decided once.
- **Round 2.** mr-review: `writeInline`'s progress assert sat in a `defer`, so a failed write would have panicked; the changelog gained the quote fix. STYLE: `breaks_pending` became a union whose blank case carries its quote depth; the marker-open helpers became `Inline` methods. Tiger Style: an upper bound on the answer's id, `*const` for `NewMessage` and `Payload`, types and limits at the top of `Client.zig`. `post` went back to its plain name, since STYLE 1.6 makes a type's methods its interface (round 1's `sendPost` reverted).
- **Round 3.** mr-review: the id bound needed a day's margin for time zones. Tiger Style: one bound for shown times, `short_time.gmt_seconds_max`, which `parseIso` enforces (a `9999-12-31` timestamp could previously overflow the display), `shortTimeAt` asserts, and a comptime assert ties to `message_id_max`.
- **Round 4.** Tiger Style: `parseIso`'s tests now sit on both sides of the bound.
- **Round 5:** all three reviews found nothing new. Gate passed. M5 resolved at 0.6.0.

Reads were checked live after each change to the request code (counts only). The only write in M5 was the one approved send to `48:notes`.

## After M5: send to any chat (0.7.0)

On 2026-11-07 the owner asked to remove the notes-only restriction. `send` now writes to any chat chosen by exact name or id; the allow list, `SendNotAllowed` and their tests are gone, and the size checks stay before any request. No live send was made for this change; live sends stay limited to `48:notes`, with the owner's go-ahead each time.

## 0.7.1 and 0.8.0: code spans and fences (owner-reported)

The owner sent a snippet wrapped in ``` on one line (fish had joined the lines) and it was cut at the first inner backtick. 0.7.1 matched code spans by backtick run length, as CommonMark does. The owner then chose Teams' compose-box behaviour over CommonMark for three or more backticks: 0.8.0 makes ``` a code block wherever it is typed, with surrounding text as its own paragraphs. One live send to `48:notes` (owner-approved at the time) came back with every form as intended.

## 0.8.1: `messages` shows code holding backticks (open item)

`messages` wrapped inline code in one backtick, so code holding a backtick read ambiguously. It now fences code with one more backtick than the longest run inside it (found by looking ahead in the raw HTML to `</code>`), capped at 16, with a space inside each end when the fence is longer than one. No live calls; the change only affects reading.

- **Round 1.** mr-review: the CHANGELOG's own example was ambiguous; a comment says why a long run at a line's start isn't a fence. STYLE: `code_ticks`' bounds asserted where used (4.5). Tiger Style: the link assert as an implication, `writeMarker` switching on `side`, sized counters capped as they count, paired bounds asserts and a comptime check that the cap fits `u8`, tests for the cap, an unclosed `<code>` and `</CODE>`.
- **Round 2.** mr-review: nothing new. STYLE: a `ticks >= 1` assert that a `u8` plus one always meets was padding (4.5), so it went. Tiger Style: an exhaustive switch instead of `else`, a comptime lower bound (`code_ticks_max >= 2`), the counters named in ticks rather than `len`.
- **Round 3:** all three reviews found nothing new in the code. Gate passed.

Also in this pass: CLAUDE.md's zero-writes section now says `send` may write, and agents' live sends stay on `48:notes` with the owner's go-ahead each time.

## M6: MCP server

Asked for by the owner on 2026-11-23: an MCP server, so an agent can read Teams and send through teams-zig. Plan approved by the owner on 2026-11-23, with the answers below.

Protocol: MCP over stdio. Each message is one line of JSON-RPC 2.0 on stdin or stdout. The server answers `initialize`, `ping`, `tools/list` and `tools/call`, and ignores every notification.

Owner decisions (2026-11-23):

- A new `teams-zig mcp` subcommand speaks MCP. It reuses the CLI's code and uses only `std`, so `build.zig.zon` keeps `.dependencies = .{}`.
- Five tools: `whoami`, `chats`, `messages`, `unread` and `send`. Each takes the CLI command's arguments and returns the text that the CLI command prints. `watch` is not a tool, because it never ends.
- The `send` tool keeps the CLI's checks: the chat is an exact name or an id, the text is at most 16 KiB, and a send is never retried.
- The watchdog stays: a Chat Service stall of more than 60 seconds ends the server.
- Agents call the MCP `send` tool only for a message that the owner requested in that session, and show the owner the chat and the text before each send (M6.10).
- The owner registers the server at user scope and puts `mcp__teams-zig__send` in the `ask` list, which prompts even in `bypassPermissions` mode.

Plan decisions:

- The commands move out of `main.zig` into `src/commands.zig`, so `main.zig` and the server share one copy. No behaviour changes in that move.
- The server is `src/Server.zig`. It reads from an `Io.Reader` and writes to an `Io.Writer`, so tests drive it with fixed buffers and no network.
- Tool arguments are JSON objects with the CLI's names: `chats {count?}`, `messages {chat, count?}`, `send {chat, text}`; `whoami` and `unread` take none. Counts are JSON integers with the CLI's limits (1–100 for `chats`, 1–12800 for `messages`). One parser, shared with `Command.parse`, applies the limits.
- Each tool call reads the token and region again (keychain, or test mode's environment), as each CLI run does. A token that `scripts/teams-token.fish` stores while the server runs then works with no restart.
- A failed command gives a tool result with `isError: true`. Its text is what the command printed before it failed (for example, the ids that `ChatNameAmbiguous` lists) and then the CLI's hint for that error. The hint text moves from `reportError` into one function that both use.
- Bad tool arguments also give `isError: true`, with the tool's usage line, so the agent can correct the call. An unknown tool name or method is a JSON-RPC error (`-32602`, `-32601`), as MCP specifies.
- `initialize` answers with the client's protocol version if it is `2025-06-18` or `2025-11-25`, and with `2025-11-25` otherwise. Both versions have no JSON-RPC batches, and the server uses no feature that differs between them. A JSON array (a batch) gets `-32600`.
- The server announces only the `tools` capability. No resources, prompts, logging, progress or cancellation.
- Tool annotations: the four reads have `readOnlyHint: true`. `send` has `readOnlyHint: false`, `destructiveHint: false`, `idempotentHint: false` and `openWorldHint: true`, so a client can ask before each send.
- Limits: a request line is shorter than 256 KiB (16 KiB of text can grow about six times with JSON escapes). A longer line gets `-32700` and is skipped up to its newline; a line longer than 64 MiB stops the server, since its input is not MCP. Each request is parsed in a fixed 2 MiB of memory, and one that needs more gets `-32603`. A tool's text is at most 1 MiB, written into a fixed buffer; more fails the call with a hint to ask for fewer.
- Calls run one at a time, in the order they arrive. End of stdin ends the server with exit code 0.
- stdout carries only protocol messages. stderr carries only two lines: the watchdog's, and "teams-zig: the MCP server stopped: <error>" when stdin fails or a line passes 64 MiB.
- The watchdog starts once with the server. It counts only time spent waiting on the Chat Service, so time spent waiting for the next request does not count. A stall past 60 seconds ends the server, as it ends the CLI.
- The live checks run the server with a script that pipes JSON lines into `zig-out/bin/teams-zig mcp`. No Claude Code config is changed.
- The version becomes 0.9.0.

### Chunks

1. **M6.1 commands in their own file.** Move `Command`, `Clock`, the `run…` functions and their helpers from `main.zig` to `src/commands.zig`. `main.zig` keeps `main`, `usage` and the watchdog. The existing tests move with the code and pass unchanged.
2. **M6.2 error hints as text.** Split `reportError` into `writeErrorHint(writer, err, status)`, which writes only the hint, and the CLI's line around it. Tests for the hint of each error kind (one per `switch` group), and for the CLI's line staying as it was.
3. **M6.3 shared argument checks.** Move the count and chat checks out of `Command.parse` into functions that the JSON parser can call too. `Command.parse`'s tests pass unchanged.
4. **M6.4 request lines.** `Server` reads one line up to 256 KiB and parses the JSON-RPC envelope: `jsonrpc` is `"2.0"`, `id` is a number, a string or missing (a notification), `method` is a string, `params` is optional. Tests for a good request, a notification, bad JSON (`-32700`), a batch and a missing method (`-32600`), and an overlong line skipped up to its newline.
5. **M6.5 initialize and ping.** The `initialize` answer (protocol version, `tools` capability, `serverInfo` with name `teams-zig` and the version, which `build.zig` reads from `build.zig.zon` and passes in as a build option), `ping`'s empty result, `-32601` for an unknown method, and no answer to a notification. Tests for each, and for both protocol versions and an unknown one.
6. **M6.6 tools/list.** The five tools with their descriptions (from `usage`), input schemas and annotations. A test compares the whole answer with the expected JSON.
7. **M6.7 tools/call arguments.** Turn a tool name and its `arguments` object into a `Command`, with the checks of M6.3. Tests for each tool's good arguments, each limit's edges, a wrong type, an unknown field, a missing field and an empty text (all `isError: true` with the usage line), and an unknown tool (`-32602`).
8. **M6.8 tools/call results.** Run the `Command` with a writer on the 1 MiB buffer, then build the result: the text, or the text and the hint with `isError: true`. The run goes through a function the test can replace, so tests use fake output and fake errors with no network. A test for output over 1 MiB.
9. **M6.9 `mcp` subcommand.** `teams-zig mcp` in `Command.parse` and `usage`. `main` starts the watchdog, then runs `Server` on stdin and stdout until end of stdin. Each call connects as the CLI does and frees the client after the call. A test runs `Server` over a fixed input holding `initialize`, `tools/list` and end of input.
10. **M6.10 CLAUDE.md for the `send` tool.** Change "Writes to Teams" so that the MCP `send` tool may post too, with the same rule for agents' live sends (`48:notes` only, kept minimal, each one confirmed at that moment). Add: "Agents call the MCP `send` tool only for a message that the operator requested in that session. Before each send, agents show the operator the chat and the text." This edit is the only change outside the code.
11. **M6.11 live read check.** Pipe `initialize`, `tools/list`, `whoami`, `chats 5`, `messages 48:notes 1` and `unread` into the built server. Compare each tool's text with the same CLI command's output (the relative times can differ if a minute passes). Counts only in the report; reads only.
12. **M6.12 one live send.** One `tools/call send` to `48:notes`, only after the owner confirms that send at that moment. Read it back with the `messages` tool. Never retried.
13. **M6.13 0.9.0 and gate.** Version, CHANGELOG entry, then the milestone gate.

### Owner step: register the server

After the gate, the owner registers the server in Claude Code; agents do not change Claude Code config. For example: `claude mcp add --scope user teams-zig -- <repo>/zig-out/bin/teams-zig mcp`. Claude Code then names the tools `mcp__teams-zig__whoami` and so on. The owner also puts `mcp__teams-zig__send` in the `ask` list in `~/.claude/settings.json`, so Claude Code asks before each send, even in `bypassPermissions` mode.

### Out of M6

`watch` as a tool, and any server-to-client messages (notifications, progress, logging). Resources and prompts. Cancelling a call. Running calls in parallel. HTTP transport. Any write but `send`.

### M6 live send

On 2026-11-23, with the owner's go-ahead in the work session at that moment: one `tools/call send` through `teams-zig mcp` to `48:notes`, text "M6 MCP send check: **bold**, _italic_, `code`.". The tool answered "Sent 15:51."; the `messages` tool read it back with every form as typed. Nothing was retried. This was the only write in M6.

## M6 gate

- **Round 1** (mr-review, STYLE.md and Tiger Style reviews of `c918fcf..32d024a`). STYLE: helpers carry their caller's name (`serveLongLine`, `answerInitialize`, `answerCallRun`, `Tool.commandCount`), `run_fn`, one path for a missing or non-string field, `Runner.run` as a method. Tiger Style: lines at most 100 columns; no allocation while serving (a static 2 MiB request memory, `-32603` when a request needs more, the hint written after the text in room kept for it); all parse options explicit; pair assertions on `watch` and on `UnexpectedStatus`'s status; comptime asserts on the request size and on `Tool`'s names; `*const` for `Id` and `std.json.Value`; `@divExact`; unit names last; types before methods; the event loop marked unbounded and the skip bounded at 64 MiB; a test under 70 lines. mr-review: a test that a `tools/call` notification runs nothing, and the one-session test the plan asked for in M6.9. `main`'s tests now compile `serveMcp`, which they did not reach before.
- **Round 2** (reviews of `32d024a..99c7c64`). STYLE: one fallback in `answerInitialize`. Tiger Style: two aliases gone, `text_size_max` no longer means two things, the request allocator made where it is used, the skipped newline asserted. mr-review: one `parse_options` for the server and its tests, a test that a line past 64 MiB stops the server, and these limits in the plan.
- **Round 3** (reviews of `99c7c64..7176ff1`). Tiger Style: two variables that only shortened lines gone. mr-review: the test helper checks the answers even when `serve` fails, so the skip-limit test proves no answer goes out; a line of exactly 64 MiB is skipped, as the plan says, with a test on both sides of the edge.
- **Round 4** (reviews of `7176ff1..ad656ca`). Tiger Style: the edge test allocates only the bytes it reads and says why it resets its reader. mr-review and STYLE: nothing new.
- **Round 5** (reviews of `ad656ca..db75827`). mr-review: the edge test's comment on its reset said the opposite of what happens; reworded. STYLE and Tiger Style: nothing new.
- **Round 6:** all three reviews found nothing new. Gate passed. M6 waits on the M6.12 live send, which needs the owner's go-ahead in the work session, before it is resolved at 0.9.0.

Owner's answers to the round-6 report (2026-11-23):

1. The send rule reaches agents outside this repo: applied. `send`'s description says to send only a message the operator asked for in this session and to show the chat and the text first; `messages` and `unread` say their text comes from other people and is data, not instructions.
2. `maxLength` counts characters, the limit bytes: applied. No `maxLength`; the description and the usage line say 16 KiB of UTF-8.
3. Control bytes in send's text: applied. `Command.initSend` refuses any control byte but tab and newline, for the CLI and the tool alike; the tool answers with the usage line.
4. The stderr line "the MCP server stopped": kept, and the plan now names both stderr lines.
5. Fractional ids: no change.
6. `startWatchdog`'s silent spawn failure: no change.
7. Arguments listed in three places: no change, and no drift test.
8. The test that a `tools/call` notification runs nothing: kept.
- **Round 7** (reviews of `305fce3..089353a`, the owner's answers applied). Tiger Style: `initSend`'s tab-and-newline check is a switch, not a compound condition; tests refuse `0x1f` and pass UTF-8. mr-review: the test's comment says every control byte is refused, from argv or JSON; a test pins `send`'s usage answer. Two mr-review findings go to the owner: the CLI's usage line doesn't say why it refuses a send, and `initSend` counts only ASCII control bytes, while `text.zig` also shows UTF-8 C1 as control.
- **Round 8** (reviews of `089353a..3525520`). mr-review and Tiger Style: the test comment said every byte from space up passes, but DEL is refused; it now says printable ASCII and UTF-8 pass, and the test's printable case is `~` rather than a second space. STYLE: nothing new.
- **Round 9:** all three reviews found nothing new. Gate passed again. Two owner questions from round 7 are open (the CLI's usage line for a refused send; C1 control characters in `initSend`), and the M6.12 live send waits for the owner's go-ahead in the work session.

Owner's answers to the round-7 questions (2026-11-23): the CLI's usage line for `send` gives its rules (at most 16 KiB of UTF-8, with no control characters but tab and newline); `Command.initSend` uses `chat.text.controlLenAt`, now pub, so UTF-8 C1 controls are refused too.
- **Round 10** (reviews of `abd2256..5a6072b`, the round-7 answers applied). Tiger Style: a test refuses U+009F, the last C1 control, so both ends of the range are pinned. mr-review and STYLE: nothing new. Deferred, for the owner: nothing checks that argv text is valid UTF-8, so a lone 8-bit C1 byte (`0x9B`) from the CLI passes, as `messages` would show it.
- **Round 11:** all three reviews found nothing new. Gate passed. With the M6.12 live send done, M6 is resolved at 0.9.0, pending the owner's step to register the server.


## M7: faster reads and sends

Asked for by the owner on 2026-11-23, after the speed report: teams-zig is slow because the Chat Service host (`{region}.ng.msg.teams.microsoft.com`) is about 230 ms away, every process and every MCP call opens a new connection (about 0.7 s), requests run one after another (about 0.3 s each, with `whoami` before most commands and name lookups for 1:1 chats), and lists come uncompressed. Plan approved by the owner on 2026-11-23, with these answers: the cache file is `~/Library/Caches/teams-zig/cache.txt`; chat-name entries have no age limit; M7.13 is one live send by name to `48:notes`, confirmed by the owner at that moment in the work session. The front-door check (M7.1) waits for the owner's go-ahead in the work session; M7.2 and M7.3 start only after it succeeds.

Owner decisions (2026-11-23):

- **Front door.** Requests go to `https://teams.microsoft.com/api/chatsvc/{region}/v1`, whose edge is 25–45 ms away. First one authenticated `whoami` GET checks that the skype token works there; the switch happens only if it does. The owner knows the check sends the token to `teams.microsoft.com`.
- **Disk cache** of three kinds of entry: your own user (the `whoami` result), the other person's name in 1:1 chats, and a map from chat name to chat id. `messages <name>` and `send <name>` use the map. The owner knows a stale entry can make `send` post to the wrong chat.
- **MCP keeps one client** and its connection across tool calls, and reads the keychain again only after the token expires. A read call may reconnect once; a send call never retries. (Changed at the gate, Q6: the token and region are read for every call and compared with the kept client's in memory.)
- **gzip.** Requests ask for gzip bodies, decompressed with `std.compress.flate`.

Expected gains (from the speed report):

| Fix | Saves |
|---|---|
| Front door | ~0.5 s on every CLI command and every MCP call (a new connection plus the first request: 0.31–0.37 s, against 0.86–1.04 s) |
| Cache: your user | ~0.3–0.55 s on `chats`, `unread`, `messages <name>` and `send`; ~0.6 s on `send <name>`, which asks twice |
| Cache: chat name to id | the 100-chat list (~0.86 s) and up to 40 lookups (~0.32 s each) on `messages <name>` and `send <name>` |
| Cache: 1:1 names | ~0.32 s per 1:1 chat where you wrote last, on `chats` and on a name that misses the map |
| MCP client kept | ~0.7 s per call after the first (~0.2 s once the front door is in) |
| gzip | ~0.4–0.5 s where the chat list is read: `unread` (50 chats, 149 KB) and a name that misses the map (100 chats, 306 KB to 68 KB) |

Plan decisions:

- The token goes only to the front door. `checkLink` accepts links under the front-door base only. Paging links the service sends under the old `ng.msg` base are rewritten to the front-door base, same path and query, before they are checked; any other host stays `ForeignLink`. M7.2 records which host the links name.
- The cache holds no token. It holds ids and names, so the file is created with mode 0600. Its path is `~/Library/Caches/teams-zig/cache.txt` (the owner's answer); tests never touch it.
- The format is text, one entry per line, tab-separated: `self <mri> <name> <upn>`, `person <1:1 chat id> <name>`, `chat <name, lower-cased ASCII> <chat id>`. A value holding a tab, a newline or another control character is not cached.
- Limits (Tiger Style): at most 1024 `person` entries and 100 `chat` entries (a full listing, which rewrites the map, has 100 chats), and values of at most 256 bytes. The file limit is computed from those, so a full cache at its longest lines always loads (gate round 1 found the first 256 KiB limit too small). Past a limit, new entries are dropped. A file that is too large or doesn't parse counts as empty and is rewritten.
- Writes are whole-file and atomic: a temporary file in the same directory, then a rename. A CLI run and the MCP server writing at once means the last writer wins, which a cache can afford.
- The cache is read at the start of each CLI run and each MCP call, so a deleted file takes effect at once.
- `scripts/teams-token.fish` deletes the cache file at each new sign-in, since a new token may be another account. teams-zig itself never deletes it, except to drop one bad entry (below).
- `whoami` (the command and the tool) always asks the service, since it is the check that the token works, and writes the `self` entry. Every other command takes `self` from the cache and asks only on a miss. `send` takes the display name from the same entry.
- The name map is written by a name lookup that misses, which lists your 100 newest chats. (`chats` doesn't write it: a name unique among `chats 5` could clash with an older chat, which a lookup would call ambiguous.) Only names that pick exactly one chat in that list are stored, so an ambiguous name still lists its chats and fails as now. A name the map doesn't have is looked up as now.
- A `chat` entry whose id answers 404 is dropped from the cache and the command fails with `NotFound`, whose hint says to run it again. Nothing is retried in the same run, for `send` or for reads; a rerun resolves the name fresh. All of `send`'s other checks stay: size, control characters, no retry.
- `person` entries are never stale in practice: a 1:1 chat's other person doesn't change. A cached name is used instead of a lookup; a lookup's result is stored.
- MCP: `McpRunner` keeps the `Client` between calls. On `TokenExpired` it reads the keychain again, builds a new client and, for a read tool, runs the call once more; `send` reports the error. On `ConnectFailed`, `SendFailed` or `ConnectionDropped` a read tool reconnects and runs once more; `send` reports the error, whose hint already says to check the chat. One retry at most, and the output buffer starts empty for it.
- gzip: `Accept-Encoding: gzip, identity`. A gzip body is decompressed into the same 8 MiB body buffer, so the limit is on the decompressed size; past it, `ResponseTooLarge` as now. Other encodings are still refused.
- MCP: a send on a connection idle for more than 30 s starts on a fresh one, since the service may have closed the idle connection and a send can't be retried (added while building M7.11; kept by the owner at the gate).
- MCP: whenever the runner opens a new client, the cache's `self` is forgotten first, since the new token may be another account's (owner's answer at the gate).
- CLI: a failed cache save prints one stderr line, "teams-zig: couldn't save the cache: <error>"; the MCP server stays silent (owner's answer at the gate).
- No change to the watchdog, the request limits or the tools' arguments and text.
- The version becomes 0.10.0.

### Chunks

1. **M7.1 front-door check.** One `whoami` GET through `https://teams.microsoft.com/api/chatsvc/{region}/v1/users/ME/properties`, token on stdin to curl, never in argv, files or output. Record the status and time only. *Needs the owner's go-ahead in the work session.* If it fails, M7.2 and M7.3 are dropped and the owner is told; the other chunks do not depend on the front door.
2. **M7.2 front-door base URL.** `Region.baseUrl` gives the front door. `checkLink` accepts it and rewrites old-base paging links to it. Tests with fake links: front door accepted, old base rewritten, other hosts refused.
3. **M7.3 front-door live read.** `whoami`, `chats 5`, and `messages 48:notes 250` (which follows a paging link) through the new base. Counts and times only; record the links' host.
4. **M7.4 gzip.** Ask for gzip; decompress with `std.compress.flate` into the body buffer. Tests on the decompress step with a fake gzip body, an oversize one and a broken one.
5. **M7.5 cache format.** A `Cache` type: parse and write the three kinds of entry, the limits, a bad line or file counting as empty. Tests with fake ids and names.
6. **M7.6 cache file.** Load from and save to the cache path: a missing file is an empty cache, mode 0600, atomic rename, the size limit. Tests use a temporary directory, never the real path.
7. **M7.7 your user from the cache.** `chats`, `unread`, name lookups and `send` take `self` from the cache; `whoami` refreshes it. `send <name>` asks at most once. Tests with a fake cache and no network.
8. **M7.8 1:1 names from the cache.** `otherPersonNames` uses cached names and stores lookups. Tests.
9. **M7.9 chat name to id.** `findChat` tries the map first; listings write it; a 404 drops the entry, with no retry. Tests, including an ambiguous name and a dropped entry.
10. **M7.10 sign-in deletes the cache.** `scripts/teams-token.fish` removes the cache file after it stores a new token.
11. **M7.11 MCP keeps its client.** `McpRunner` holds the client across calls, with the reconnect and the one retry for reads only. Tests with a fake runner path for each failure.
12. **M7.12 live read check and timings.** The speed report's four commands, CLI and MCP, three runs each, against its numbers. Reads only.
13. **M7.13 one live send by name.** One `send` to `48:notes` by its name through the cache, after the owner's go-ahead at that moment. Read back with `messages`; never retried.
14. **M7.14 0.10.0 and gate.** Version, CHANGELOG, README if the cache needs a line, then the milestone gate.

### M7.1 front-door check

On 2026-11-23, with the owner's go-ahead in the work session: one `GET /users/ME/properties` through `https://teams.microsoft.com/api/chatsvc/emea/v1`, the token on stdin to curl. HTTP 200 in 0.58 s (TCP 0.04 s, TLS 0.10 s), 20,581 bytes, the same body size as on the old host, where the first authenticated read took about 1.17 s. The switch (M7.2) goes ahead.

### M7.3 front-door live read

Reads only, temporary `HOME` with a warm cache: `whoami` 1.10 s, `chats 5` 0.48 s, `messages 48:notes 250` 0.49 s, `unread` 0.70 s, all exit 0. Paging links (`backwardLink`) come back under `teams.microsoft.com/api/chatsvc/emea/v1` already, so the old-host move in `frontDoorUrl` is only a fallback.

### M7.12 timings (before the front door)

On 2026-11-23, reads only, three runs each, with a temporary `HOME` holding a warm cache (the real cache path is first written by the owner's own runs). Speed report figures in brackets.

| Command | CLI | MCP (one session) |
|---|---|---|
| `whoami` | 1.04–1.13 s [1.30–1.96] | 0.54 s after the first call [1.34–1.52] |
| `chats 5` | 0.93–0.97 s [1.75–2.10] | 0.50–0.51 s [1.80–2.10] |
| `messages 48:notes 5` | 0.94–1.00 s [1.07–1.11] | 0.55–0.56 s [1.07–1.10] |
| `unread` | 1.11–1.52 s [2.31–2.71] | 0.84–0.85 s [2.21–2.52] |
| `messages <name> 1` | 1.02–1.09 s once cached (2.19 s on a miss) | |

The CLI still pays about 0.7 s per run to connect; the front door (M7.1–M7.3) is meant to cut that.

### M7.13 live send

On 2026-11-23, with the owner's go-ahead in the work session ("send to notes whenever you need"): one `send` to `48:notes`, text "M7 front-door send check: **bold**, `code`.", through the front door, your user from the cache. By id, not by name: the notes chat has no name (`chats` shows "(no topic)"), so it can't be named; the name path was checked live with `messages <name>` (M7.9). The message arrived once at 17:34, read back with `messages 48:notes 3` as typed. The command's own output wasn't captured by the agent's shell, so its "Sent" line and exit code weren't seen; nothing was retried. With the owner's go-ahead for one more ("you can send again if you need more info"), a second send, "M7 send check 2: output captured.", with stdout and stderr each in a file: exit 0, "Sent 17:35.", nothing on stderr, 0.51 s in all (one request: the front door, your user from the cache). Both arrived once.

### Out of M7

Parallel lookups. Paging sizes. A cache age limit. Caching message content. Any write but `send`.

## M7 gate

- **Round 1** (mr-review, STYLE.md and Tiger Style reviews of `3f85955..fda277a`). mr-review's blocker: a full cache (about 1.06 MB) was larger than the 256 KiB a load read, so it would be thrown away and refilled forever; the file limit is now computed from the line sizes, with comptime asserts and a full-cache test. Per the plan, a full listing now rewrites the chat-name map, so a name that became ambiguous is forgotten. The gzip drain reads at most one byte past the gzip stream (data there is `BadResponse`), and its comment is right about the footer. STYLE: `FoundChat` a union (3.1), `McpRunner.dropClient` apart from `deinit` (4.4), the client and its last use one optional (3.5), helper names with their caller's (1.6). Tiger Style: `fetch` under 70 lines (`fetchOptions`), pair and count asserts, split compound conditions, typed limits, units in names, explicit options, edge tests. Four findings went to the owner: a running MCP server keeping the old account after a sign-in, the silent cache-save failure, the 30 s send idle rule, and the longer parameter lists.
- **Round 2** (reviews of `fda277a..cb45033`). mr-review: `chat_count_max` is 100, the listing's size, asserted against `conversation_count_limit`; a listed name whose chat answers 404 is forgotten too; this plan's limits line. STYLE: a test's `catch unreachable` says why; `putEntry`'s count check is a guard again, written positively (`== count_max`), which Tiger Style's "handle the negative space" also asks. Tiger Style: `putSelf`'s nested checks, typed line sizes, `left_size`. `runOnce`'s nested send check stays nested (Tiger Style: no compound conditions).
- **Round 3** (reviews of `cb45033..c6a47e6`). mr-review: `file_size_max`'s comment said about 1 MiB after the chat limit fell to 100; it now says 586,180 bytes and a comptime assert pins that value. STYLE: `putSelf` compares through `putSelfUnchanged`, with guard clauses, instead of a four-deep nest (5.4); `FoundChat.NamedChat` owns both its id and its name in `findChat`'s arena (6.4). Tiger Style: `forgetStaleChat`'s comment covers listed names too; the full-cache test asserts the limits its keys rely on; `Named` is the noun `NamedChat`.
- **Round 4** (reviews of `c6a47e6..ab930b2`). STYLE 6.4: `findChat`'s comment says both the id and the name are owned by `arena`. mr-review and Tiger Style: nothing new.
- **Round 5:** all three reviews found nothing new. Gate passed. Four round-1 findings wait for the owner: a running MCP server keeping the old account after a sign-in, the silent cache-save failure, the 30 s send idle rule, and the longer parameter lists. M7 is resolved at 0.10.0 once those are answered (and any fix they bring passes the gate).

Owner's answers to the round-1 questions (2026-11-23):

1. A running MCP server keeping the old account after a sign-in: before the runner opens a new client, the cache's `self` is forgotten (73df194).
2. The silent cache-save failure: the CLI prints one stderr line; the MCP server prints nothing (STYLE 4.3).
3. The 30 s send idle rule: kept, and recorded as a plan decision above.
4. The longer parameter lists: no change in M7; STYLE 2.2 warns against a parameter-bag struct.
- **Round 6** (reviews of `c2812c8..d931dc5`, the owner's answers applied). mr-review: the stale-user mark moved from one call's local value to the kept client (`Kept.cached_self_stale`), cleared only after a save, so a failed load or save can't bring the old account's user back; the CHANGELOG mentions the CLI's stderr line. Tiger Style: `writeFile`'s options spelled out in tests. STYLE: nothing new. To the owner: with the 30 s rule, most MCP sends start on a new client and so ask for your user first (about 0.2 s more).
- **Round 7** (reviews of `d931dc5..0acc78b`). mr-review: a failed read of the home folder or cache file came back as an empty cache, so the stale mark was cleared while the file still held the old user; `forgetSelf` now always marks the cache to be rewritten, and the mark clears only when a home exists and the save worked. STYLE 5.1: the test's file options are inline. Tiger Style: nothing new. To the owner: a running MCP server with the old token can still write the old user back after a sign-in, which the CLI would then read.
- **Round 8** (reviews of `0acc78b..47f3440`). STYLE 5.4 and 5.2: the MCP save moved into `McpRunner.runOnceSave`, which returns early without a home or on a failed save, so `home` is unwrapped once; `saveCache` takes a home that is there. mr-review and Tiger Style: nothing new. To the owner (with Q5): Q6, a running MCP server with the old token writing the old user back after a sign-in.
- **Round 9:** all three reviews found nothing new. Gate passed. Q5 and Q6 wait for the owner; M7 resolves at 0.10.0 once they are answered (and any fix they bring passes the gate).

Owner's answers to Q5 and Q6 (2026-11-23):

- Q5, the extra user check on most MCP sends (about 0.2 s, from the 30 s rule and Q1): accepted, no change.
- Q6, a running MCP server writing the old account's user after a sign-in: before each call the server reads the token and region and compares them with its kept client's, in memory only; a difference drops the client, and the new one forgets the cached user. No token or hash is written to disk or printed. Reviewed before building: no flaw found; costs are two keychain reads per call, a prompt on every MCP call while the keychain is locked, and one narrow race (a call already running during a sign-in may save its old user once). Built in f02d980 and the next commit.
- **Round 10** (reviews of `f19f557..fc2c49b`, Q6 built). mr-review and Tiger Style: the `McpRunner` comments no longer say the keychain is read only on a reconnect, and list a new sign-in among the reasons the client drops. Tiger Style: `now_seconds` read where it is used, after the keychain reads; blank lines after the new `defer`s; `usesToken` asserts its token like `init`; no alias to the kept client in `connected`; tests for a token with a line break and a missing region. STYLE: nothing new.
- **Round 11** (reviews of `fc2c49b..8ddfd90`). Tiger Style: blank lines around the cache's allocation and `defer`s in `runOnce` and in the `readCredentials` test; that test's name and a top comment cover the cases it refuses. mr-review and STYLE: nothing new.
- **Round 12:** all three reviews found nothing new. Gate passed, with every owner question answered. M7 resolved at 0.10.0.

## M8: `teams-zig login` and a release on GitHub

Asked for by the owner on 2026-11-23. Two goals:

1. `teams-zig login` replaces `scripts/teams-token.fish`. It runs agent-browser as the script does, but parses its output in Zig, so a user needs no fish and no jq.
2. A standalone binary on the GitHub releases page of `orderrrr/teams-zig`. A user downloads it and runs `login`, the CLI and `mcp` with no Zig compiler.

The first plan (approved 2026-11-23) signed in with Microsoft's OAuth flows. The owner changed M8 on 2026-11-23: `login` wraps agent-browser, and the OAuth work moves to a later milestone, together with the embedded sign-in window. The owner approved this revised plan on 2026-11-23, with the answers below. The live sign-in (M8.7) and the push, tag and release (M8.12) each wait for the owner's go-ahead at that moment in the work session.

Owner decisions (2026-11-23):

- **Targets.** `aarch64-macos` only.
- **Publish.** A local build plus `gh release create`, run by the owner. No GitHub Actions workflow.
- **The script.** M8.7 deletes `scripts/teams-token.fish` and changes the line about it in `CLAUDE.md`.
- **Node.** `login` needs agent-browser, and Homebrew's agent-browser needs Node. The CLI, the MCP server and the release binary do not.
- **agent-browser version.** The README names the tested version, 0.43.0. Nothing pins a version.
- **agent-browser's browser.** The README lists `agent-browser install` as the user's step. Agents never run it.
- **For the later sign-in milestone, not M8:** the Teams desktop client id `1fec8e78-bce4-4aaf-ab1b-5451cc387264` (the owner knows security tools may flag it), and no automatic renewal on `TokenExpired`.

### How `login` signs in

The same steps as `scripts/teams-token.fish`, with the same names, so a profile that is already signed in keeps working:

1. Run `agent-browser --session teams-zig --headed --profile "~/Library/Application Support/teams-zig/browser" open https://teams.microsoft.com`. The profile directory is created first.
2. Tell the user to sign in in the browser window, and wait up to 300 s.
3. Every 2 s, run `agent-browser --session teams-zig network requests --json` and parse its output in Zig.
4. Take the skype token from the body of a `POST` to a URL ending in `/v1/skypetokenauth` (`skypetoken=<token>`), else from an `x-skypetoken` header (any case, with any `skypetoken=` prefix removed). Take the region from a URL that starts `https://{region}.ng.msg.teams.microsoft.com/` or `https://teams.cloud.microsoft/api/chatsvc/{region}/` or `.../api/mt/{region}/`. The region must be `amer`, `emea` or `apac`. Stop when both are found.
5. Run `agent-browser --session teams-zig close`, on success and on every failure.
6. Write `skype-token` and `region` to the `teams-zig` keychain service, delete the cache file, and print "Stored the skype token and region <region> in the login keychain."

### Plan decisions

- **agent-browser is a child process**, found on `PATH` as `agent-browser`. Arguments go in argv; nothing secret does. `--session teams-zig` replaces the script's `AGENT_BROWSER_SESSION` variable, so `login` sets no environment. If the binary is missing, `login` fails with a hint that names the install commands (`brew install agent-browser`, then `agent-browser install`).
- **The JSON contract** is what the script reads today: `.data.requests[]` with `method`, `url`, `postData` and `headers`. Parsing ignores other fields. Output that does not match fails `login` with an error that names agent-browser's version check (`agent-browser --version`), never the output. M8.1 records the shape from agent-browser 0.43.0 on a page with no sign-in.
- **Limits (Tiger Style).** One `network requests` output is at most 64 MiB; more fails `login` with `AgentBrowserOutputTooLarge`. The wait is at most 300 s, polled every 2 s. A token is at most 16 KiB.
- **No secret is printed.** Not the token, and not agent-browser's output, which holds it. Errors name what was missing ("no skype token seen in 300 seconds"), as the script's do.
- **Keychain write on stdin.** `login` runs `/usr/bin/security -i` and writes two `add-generic-password -U -A -s teams-zig -a <account> -w <value>` lines on its stdin, so the token is never in argv (the script puts it in argv today). `-U -A` as now, so the readers need no prompt (M1.7). Before the write, each value is checked for printable ASCII with no space, quote or backslash, since `security -i` splits its lines on those. `security -i` may exit 0 after a failed line (*not checked*), so `login` reads both items back through the existing reader and compares them; a mismatch is `KeychainWriteFailed`.
- **The cache file** (`~/Library/Caches/teams-zig/cache.txt`, M7) is deleted after each sign-in that stores a token, as the script does after M7.10. M7's front-door base URL and the MCP server's token check on each call stay as they are: a running server picks up the new token at its next call.
- **Hints.** Every error hint that says "run scripts/teams-token.fish" says "run teams-zig login", and so does `usage`.
- **Release targets.** `aarch64-macos` only. Minimum macOS is Zig 0.17's default, 15.0.
- **Release build.** A new `zig build release` step builds `aarch64-macos` with `-Doptimize=ReleaseSafe` into `zig-out/release/teams-zig-aarch64-macos`. When the target is macOS and not native, `build.zig` adds the SDK search paths from `std.zig.system.darwin.getSdk`. Plain `zig build` stays as now. The build machine needs Xcode or the Command Line Tools, as today.
- **Publish.** The owner builds locally and runs `gh release create`. Each release has `teams-zig-<version>-aarch64-macos.tar.gz` (tar keeps the execute bit, which a raw browser download loses) and a `SHA256SUMS` file.
- **Gatekeeper.** No Developer ID signing and no notarization: both need a paid Apple Developer account. The README tells users to run `xattr -d com.apple.quarantine` on a browser download.
- **README.** "Sign in" says `login` needs agent-browser, and how to install it: `brew install agent-browser` (Homebrew's formula needs Node), then `agent-browser install`, which fetches its browser.
- The version becomes 0.11.0.

### Facts checked on this Mac (2026-11-23)

From a copy of `HEAD` in a scratch directory; the repo was not changed.

- `zig build -Dtarget=aarch64-macos` and `-Dtarget=x86_64-macos` both fail today: "unable to find system framework CoreFoundation". With an explicit target, Zig does not look for the macOS SDK.
- With the SDK's `System/Library/Frameworks` and `usr/lib` added as search paths (path from `xcrun --show-sdk-path`), both targets build. `std.zig.system.darwin.getSdk` gives that path from `build.zig`.
- The `aarch64` binary is 1.3 MB, ad-hoc signed by the linker (`flags=adhoc,linker-signed`), links only CoreFoundation, Security, libSystem and libobjc, and has `minos 15.0`. It runs.
- The `x86_64` binary is 1.5 MB, `minos 15.0`, not signed. It could not run here: this Mac has no Rosetta ("Bad CPU type in executable").
- With a `com.apple.quarantine` attribute (as a browser download gets), the binary is killed at start (exit 137) and `spctl` says "rejected". After `xattr -d com.apple.quarantine`, it runs.
- The repo on GitHub is public, has no `.github/` folder and no releases. Local `main` is ahead of `microslopgithub/main`.

### Chunks

1. **M8.1 agent-browser output.** Run agent-browser 0.43.0 on `https://example.com` (no Teams, no sign-in), save `network requests --json`, and check it has the fields the script reads. Write the test fixtures from that shape, with fake tokens and fake URLs only.
2. **M8.2 find the token and region.** A function that takes one `network requests` output and returns the skype token and region it finds, if any. Tests: the POST body, the header (mixed case, with and without the prefix), each region pattern, an unknown region, neither, bad JSON, a token over 16 KiB.
3. **M8.3 run agent-browser.** Run it as a child with given arguments; read its stdout up to 64 MiB; report a missing binary, a non-zero exit and too much output as distinct errors. A seam lets tests fake it. Tests with the fake.
4. **M8.4 sign-in loop.** Open, poll every 2 s up to 300 s, stop when both values are found, always close. Tests with the fake runner and a fake clock: found at once, found late, time out, browser closed (non-zero exit), close after each failure.
5. **M8.5 keychain write on stdin.** `security -i` with the two lines, the value check, and the read-back. Tests use a throwaway service name and fake values, and delete what they write, as M1.4 does.
6. **M8.6 `login` command.** `teams-zig login` in `Command.parse` and `usage`; the loop, the write, the cache delete and the message. Hints name `teams-zig login`. Tests of the wiring with fakes.
7. **M8.7 live sign-in.** *Needs the owner's go-ahead in the work session; it writes the real keychain items.* `teams-zig login`, then `whoami` and `chats 3`. Counts only; no token values.
8. **M8.8 retire the script.** Delete `scripts/teams-token.fish`. README "Sign in" becomes `teams-zig login`, with the agent-browser install. The first paragraph of `CLAUDE.md` names `teams-zig login` instead of the script.
9. **M8.9 release step.** `zig build release` as above. Check the binary with `file`, `codesign -dv` and `otool -L`, and run it.
10. **M8.10 README install.** Download, check `SHA256SUMS`, `tar -xzf`, `xattr -d com.apple.quarantine`, put the binary on `PATH`, install agent-browser, `teams-zig login`, and `claude mcp add` with the installed path.
11. **M8.11 0.11.0 and gate.** Version, CHANGELOG, then the milestone gate.
12. **M8.12 first release.** *Owner step, after the gate.* The owner pushes `main`, tags `v0.11.0`, runs `zig build release`, makes the tar file and `SHA256SUMS`, and runs `gh release create v0.11.0 --title v0.11.0 --notes-file <CHANGELOG part> <files>`. Agents never push. Then one check: download the asset with a browser, follow the README, and run `teams-zig --help`.

### Owner approvals in this plan

- agent-browser stays an outside tool (approved in M1.5), now run by `teams-zig login`.
- The keychain: the writes in M8.5's tests (fake values) and M8.7 (real).
- The live sign-in: M8.7, confirmed at that moment.
- Push, tag and release: M8.12, by the owner.
- `CLAUDE.md` and README changes: M8.8 and M8.10.

### Out of M8

Sign-in without agent-browser, for a later milestone: the device code flow, the authorization code flow with PKCE and a loopback or pasted redirect, the `authz` exchange, a `refresh-token` keychain item, and renewal with it. Developer ID signing and notarization. Homebrew for teams-zig. A universal (`lipo`) binary. Intel Macs. Linux or Windows. A GitHub Actions workflow. Bearer-token APIs (search, profiles). Personal Microsoft accounts. Any write to Teams.

An embedded sign-in window (`WKWebView` or `ASWebAuthenticationSession`) instead of the system browser: a candidate for M9 (the owner's answer, 2026-11-23).

### Sign-in protocol research (for the later milestone)

Read from docs during M8 planning. No request with a token was made.

- **Skype token from a Bearer token.** `POST https://teams.microsoft.com/api/authsvc/v1.0/authz` with `Authorization: Bearer <token>` and no body returns the skype token. Sources: `inspo/teams-api/.github/copilot-instructions.md` ("Gotchas"); AADInternals `Teams_utils.ps1` (<https://github.com/Gerenios/AADInternals/blob/master/Teams_utils.ps1>).
- **The authz answer.** `tokens.skypeToken`, `tokens.expiresIn`, `region` (for example `emea`), `partition` (for example `emea01`) and `regionGtms.chatService`. Source: fossteams `authz.go` (<https://pkg.go.dev/github.com/fossteams/teams-api/pkg>, 2022). *Not checked live:* the field names may have changed since 2022.
- **The Bearer token's audience** is `https://api.spaces.skype.com`. Source: AADInternals, and the inspo table of the two tokens.
- **Client id.** `1fec8e78-bce4-4aaf-ab1b-5451cc387264` is the Teams desktop and mobile client, a public client and a member of the "family of client ids" (FOCI). AADInternals uses it for the `api.spaces.skype.com` token. Sources: AADInternals; <https://raw.githubusercontent.com/secureworks/family-of-client-ids-research/main/known-foci-clients.csv>. The web client `5e3ce6c0-2b1f-4285-8d4b-75ee78787346` is a single-page app: its refresh tokens last 24 hours and its redirect goes only to the Teams web host, so it does not fit a CLI. Source: <https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens>.
- **Device code flow.** `POST https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode` with `client_id` and `scope`. The answer has `device_code`, `user_code`, `verification_uri`, `expires_in` (900 s by default), `interval` and `message`. The client polls `/oauth2/v2.0/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code`. The errors are `authorization_pending`, `authorization_declined`, `bad_verification_code` and `expired_token`; RFC 8628 adds `slow_down`. A refresh token comes only if the scope holds `offline_access`. Source: <https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code>.
- **Authorization code flow with PKCE.** `/oauth2/v2.0/authorize` with `code_challenge` and `code_challenge_method=S256`, then `/oauth2/v2.0/token` with `code_verifier`. A public client sends no secret. The redirect URI must be registered on the app; for `http://localhost` the port is ignored. The code lives about one minute. Sources: <https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow>, <https://learn.microsoft.com/en-us/entra/identity-platform/reply-url>.
- **Redirect URIs of the Teams client.** `https://login.microsoftonline.com/common/oauth2/nativeclient` is in use with this client id (<https://cyberpress.org/steals-microsoft-entra/>). *Not checked:* whether a loopback `http://localhost` redirect is registered for it. M8.1 opened the authorize page with this redirect; the result was not recorded before M8 changed.
- **Refresh tokens** last 90 days by default (24 hours for single-page apps). Each use returns a new refresh token, which replaces the old one. Source: <https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens>. So `refresh token → Bearer token → authz` renews the skype token, which lasts about 24 hours, with no new sign-in. *Not checked live.*
- **Conditional Access** can block the device code flow ("Authentication flows" condition), and Microsoft's page tells admins to block it where it is not used. Source: <https://learn.microsoft.com/en-us/entra/identity/conditional-access/policy-block-authentication-flows>. A device code sign-in also carries no device identity, so a policy that needs a compliant or joined device fails it too.
- **Detection.** Security tools flag sign-ins with this client id from unusual tools, because attack tools (TeamFiltration, token theft) use it. Sources: <https://www.elastic.co/guide/en/security/8.19/entra-id-sign-in-teamfiltration-user-agent-detected.html>, <https://cyberpress.org/steals-microsoft-entra/>. The script's sign-in looks like the Teams web client, so this risk is new in M8.
- **std has what the flows need.** `std.Io.net.IpAddress.listen` and `Server.accept` (loopback listener), `std.base64.url_safe_no_pad`, `Io.randomSecure`, and SHA-256 in `std.crypto`. Checked in the Zig 0.17.1 sources.
- **`/usr/bin/security -i`** reads commands on stdin until end of input (`man security`). So a token can go to the keychain on stdin and never in argv. The script puts it in argv today.

M8.1 of the first plan, run on 2026-11-23 with the owner's go-ahead, before M8 changed:

- `POST https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode` with client id `1fec8e78-…` accepted the v2 scope `https://api.spaces.skype.com/.default offline_access`. It answered `user_code`, `device_code`, `verification_uri` (`https://login.microsoft.com/device`), `expires_in` 900, `interval` and `message`.
- The check was stopped while it waited for the sign-in. No token was issued, `authz` and the refresh were not tried, and nothing was written to the keychain.
- The loopback redirect page (`http://localhost:8400`) was opened; its result was not recorded.
