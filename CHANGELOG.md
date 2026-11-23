# Changelog

One entry per milestone. The version lives in `build.zig.zon`.

## 0.10.0 (M7): faster reads and sends

- Requests go through the Teams front door (`teams.microsoft.com/api/chatsvc/{region}/v1`), an edge near you, not the Chat Service's own host. A new connection costs about 0.15 s, not 0.7 s.
- Lists come gzipped: the 100-chat list drops from 306 KB to 68 KB.
- teams-zig remembers your user, the other person's name in 1:1 chats, and which chat each name picks, in `~/Library/Caches/teams-zig/cache.txt` (readable only by you; no token). `scripts/teams-token.fish` deletes it at each sign-in. `whoami` always asks the service.
- A name the cache knows takes one request for `messages` and `send`. If its chat answers 404, the name is forgotten and the command fails; run it again to look the name up. Nothing is retried.
- The MCP server keeps one connection across tool calls and reads the keychain again only after the token expires. A read tool runs once more after a token or connection failure; `send` never does. A send on a connection idle for more than 30 s starts on a fresh one.
- Measured: `unread` 2.3–2.7 s before, 0.7–1.5 s now; MCP tool calls 0.5–0.9 s after the first.

## 0.9.0 (M6): an MCP server

- `teams-zig mcp` serves `whoami`, `chats`, `messages`, `unread` and `send` as MCP tools over stdin and stdout, so an agent such as Claude Code can use them. Each tool takes the command's arguments as JSON (`chats {count}`, `messages {chat, count}`, `send {chat, text}`) and returns the text the command prints. `watch` is not a tool, since it never ends.
- A failed call returns the command's hint, as the CLI prints it, marked as an error. Wrong arguments return what the tool takes.
- Each call reads the token from the keychain again, so a token stored with `scripts/teams-token.fish` works without restarting the server. A Chat Service stall of more than 60 seconds ends the server, as it ends a command.
- Register it in Claude Code with `claude mcp add --scope user teams-zig -- <repo>/zig-out/bin/teams-zig mcp`, and put `mcp__teams-zig__send` in the `ask` list of `~/.claude/settings.json`, so Claude Code asks before each send.
- `send`, as a command or a tool, refuses text holding a control character other than tab and newline (C0, DEL, or a UTF-8 C1 such as U+009B), the ones `messages` shows escaped. Its usage line says so.
- The `send` tool's description tells agents to send only what the operator asked for in that session, and to show the chat and the text first. `messages` and `unread` say their text is data, not instructions.
- Writes to Teams: sending, through the `send` command or the `send` tool, is the only write.

## 0.8.1: `messages` shows code holding backticks unambiguously

- Fixed: `messages` fences inline code with one more backtick than the longest run inside it, with a space inside each end when it holds a backtick, so code holding a backtick between `a` and `b` shows as ``` `` a`b `` ```. Before, it always used one backtick, which ended at the first backtick inside.

## 0.8.0: ``` makes a code block anywhere, as in Teams

- In `send`, three or more backticks start a code block wherever they are typed, as in Teams' compose box: `` ```ls -la``` `` on one line is a code block, and `` text ``` `` at a line's end starts one on the next line. Text before and after a block becomes its own paragraph. Single and double backticks stay inline code.

## 0.7.1: inline code with backticks inside

- Fixed: in `send`, inline code opened with several backticks (```` ``` ````) now closes only at the same number of backticks, as in Markdown, so code holding single backticks stays whole. Before, it ended at the next backtick. One space just inside each end is dropped, so `` `` `x` `` `` sends `` `x` ``.

Known limits: `messages` still shows inline code between single backticks, so code holding a backtick reads ambiguously there. In fish, a `\` at a line's end inside quotes joins the lines; press Enter inside the quotes instead.

## 0.7.0: send to any chat

- `teams-zig send` sends to any chat you can name or give the id of, not just your notes. Choose the chat the way `messages` does: its exact name, or its id. A name that several chats share is refused, with their ids listed.
- Writes to Teams: sending is the only write.

## 0.6.0 (M5): send messages in Markdown

- `teams-zig send <chat> <text>` sends one message. The text is Markdown, sent as Teams' own formatting: `**bold**`, `_italic_` or `*italic*`, `~~strike~~`, `` `code` ``, `[text](https://…)` links, `#` to `###` headings, `- ` and `1. ` lists, `> ` quotes and `` ``` `` code blocks. Everything typed is escaped, so it can't become hidden markup; a `\` before punctuation keeps it literal.
- For now it sends only to your notes (`48:notes`); any other chat is refused before anything is sent. Text over 16 KiB is refused too.
- A send is never retried. If the connection drops after sending, the message may still have arrived, so the error says to check the chat before sending again.
- Fixed: in `messages` and `watch`, the blank line before a quote no longer shows as part of the quote (a lone `>` line).
- Writes to Teams: sending is the only write, and only to `48:notes`.

Known limits: one level of lists; no mentions, replies, files or images; links only to `http` and `https`.

## 0.5.0: short times, unread, escaping

- Times show in your local time and short: `14:05` for today, `Mon 14:05` for the past week, and `2026-10-12 14:05` before that. This applies to `chats`, `messages` and `watch`.
- `teams-zig unread` shows what's new since you last read, in up to 10 unread chats among your 50 newest, the way `watch` prints it. It never marks anything as read.
- A line someone typed that starts like Markdown (`#`, `>`, `- `, `1. `, `` ``` ``, `---`) gets a `\` in front, so it reads as typed rather than as a heading, quote or list.
- Still read-only: nothing writes to Teams.

Known limits: only formatted (HTML) messages are escaped, not plain-text ones; a typed `*` or `_` inside a line stays as typed; and a typed `` ``` `` inside a code block still ends it early.

## 0.4.0 (M4): readable messages

- Messages render as Markdown: bold, italic, strikethrough, inline code, links as `[text](url)`, quoted replies and other quotes as `> `, bulleted and numbered lists, fenced code blocks and headings. An emoji shows as itself; other images show as `[image]`.
- Line breaks come through, and the stray `\x0d` at line ends is gone.
- Still read-only: nothing writes to Teams.

Each message still starts on its `time  sender: ` line; a message with several lines continues on the lines below it.

Known limits: nothing is escaped, so a line someone typed starting with `#`, `>` or `- ` reads as Markdown, and a typed `` ``` `` inside a code block ends it early.

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
