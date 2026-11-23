const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const writeVisible = chat.text.writeVisible;
const Seen = @import("Seen.zig");
const short_time = @import("short_time.zig");
const core_foundation = teams.macos.core_foundation;

/// Shared with scripts/teams-token.fish, which writes these items.
const keychain_service = "teams-zig";

/// Apple's keychain tool, which reads the items without an access prompt (see `readKeychain`).
const security_path = "/usr/bin/security";

/// security exits with the low byte of the OSStatus: errSecItemNotFound (-25300) becomes 44.
const security_exit_item_not_found = 44;

/// Far larger than any token; a bigger value means something else is stored there.
const keychain_value_size_max = 64 * 1024;

/// Test mode: set these to skip the keychain. See `usage`.
const token_variable = "TEAMS_ZIG_SKYPE_TOKEN";
const region_variable = "TEAMS_ZIG_REGION";

const conversation_count_default = 50;
const message_count_default = 50;

/// `chats` names 1:1 chats with up to one request each, all inside the watchdog's limit, so the
/// list stays at one page of modest size.
const conversation_count_limit = 100;

/// At most this many 1:1 chats get a recent-messages lookup per run; at about a second each on a
/// slow link, they stay inside the watchdog's 60 seconds. Chats past it show "(no topic)".
const name_lookup_count_limit = 40;

comptime {
    std.debug.assert(conversation_count_limit <= std.math.maxInt(u16));
    std.debug.assert(name_lookup_count_limit < requests_seconds_max);
    // Backing off never polls faster than normal, and a poll's reads fit the watchdog's limit.
    std.debug.assert(watch_poll_seconds <= watch_backoff_seconds_max);
    std.debug.assert(watch_read_count_limit < requests_seconds_max);
    std.debug.assert(unread_read_count_limit < requests_seconds_max);
    // Each poll's chats fit in Seen without folding.
    std.debug.assert(conversation_count_default <= Seen.chat_count_limit);
    std.debug.assert(conversation_count_default <= conversation_count_limit);
    std.debug.assert(message_count_default <= message_count_limit);
    // Every id `send` accepts has a time the display can show.
    std.debug.assert(@divFloor(chat.Client.message_id_max, std.time.ms_per_s) <=
        short_time.gmt_seconds_max);
}

const message_count_limit = chat.Client.message_count_limit;

/// How far back `chats` looks for the other person's name in a 1:1 chat where you spoke last.
const message_count_recent = 20;

/// How often `watch` lists your chats when all is well.
const watch_poll_seconds = 10;

/// At most this many changed chats are read per `watch` poll, so a burst can't flood the service.
const watch_read_count_limit = 10;

/// At most this many unread chats are read by `unread`, keeping its requests inside the
/// watchdog's limit.
const unread_read_count_limit = 10;

/// The most text `send` takes. Its HTML is checked too (see `chat.Client.content_size_max`),
/// since escaping makes the HTML longer than the text.
const send_text_size_max = 16 * 1024;

/// The longest `watch` waits after throttling or a failure before trying again.
const watch_backoff_seconds_max = 300;

/// Far in the future, so an idle watchdog never fires.
pub const requests_idle = std.math.maxInt(i64);

/// A command's requests, or one `watch` poll's, normally take a few seconds; past this, the
/// network has stalled.
pub const requests_seconds_max = 60;

/// What times are shown relative to: your time zone, and now.
pub const Clock = struct {
    zone: *const core_foundation.TimeZone,
    /// Since 1970 GMT. `watch` moves it on with every poll.
    now_seconds: i64,

    /// A service timestamp in its short local form (see `short_time`), written into `buffer`;
    /// null if `timestamp` isn't one.
    fn shortTime(
        clock: *const Clock,
        buffer: *[short_time.width_max]u8,
        timestamp: []const u8,
    ) ?[]const u8 {
        const at_seconds = short_time.parseIso(timestamp) orelse return null;
        return clock.shortTimeAt(buffer, at_seconds);
    }

    /// `at_seconds`, since 1970 GMT, in its short local form, written into `buffer`.
    fn shortTimeAt(
        clock: *const Clock,
        buffer: *[short_time.width_max]u8,
        at_seconds: i64,
    ) []const u8 {
        // Local times must stay after 1970 and fit `width_max` (see `short_time.write`).
        std.debug.assert(at_seconds >= std.time.s_per_day);
        std.debug.assert(at_seconds <= short_time.gmt_seconds_max);
        const times: short_time.Times = .{
            .at_seconds = at_seconds + clock.zone.secondsFromGmt(at_seconds),
            .now_seconds = clock.now_seconds + clock.zone.secondsFromGmt(clock.now_seconds),
        };
        var writer: Io.Writer = .fixed(buffer);
        // `width_max` is the widest form, so the buffer never fills.
        short_time.write(&writer, times) catch unreachable;
        return writer.buffered();
    }
};

/// Failures reading the keychain or starting the client.
const ConnectError = KeychainReadError || error{ UnknownRegion, InvalidToken };

/// Failures reading a keychain item through `security`.
const KeychainReadError = error{ ItemNotFound, KeychainReadFailed, OutOfMemory };

/// Failures running a command: the Chat Service's, writing the output, or a chat name that
/// picks no chat or several.
const RunError = chat.Client.Error || Io.Writer.Error || ChatNameError || WatchError || SendError;

const ChatNameError = error{ ChatNameNotFound, ChatNameAmbiguous };

/// Failures of `send` found before any request.
const SendError = error{SendTextTooLong};

/// Failures of `watch` beyond the Chat Service's and the output's.
const WatchError = Seen.Error;

/// Every way a command can fail.
const CommandError = ConnectError || RunError;

pub const Command = union(enum) {
    whoami,
    watch,
    unread,
    /// How many conversations to list.
    chats: u16,
    messages: Messages,
    send: Send,

    const Messages = struct {
        chat: Chat,
        count: u32,
    };

    const Send = struct {
        chat: Chat,
        /// Markdown, as typed. Borrows the argument, which lives as long as `main`.
        text: []const u8,
    };

    /// A chat as typed on the command line. Both borrow the argument slice, which lives as long
    /// as `main`.
    const Chat = union(enum) {
        id: []const u8,
        /// Matched exactly, ignoring ASCII case, against the names `chats` shows.
        name: []const u8,

        /// Ids start with a number and a colon (`19:…`, `48:notes`) and never hold whitespace;
        /// names can start with a time, as in "9:30 Standup", but then hold a space.
        fn parse(text: []const u8) Chat {
            std.debug.assert(text.len > 0);
            const space = std.mem.indexOfAny(u8, text, &std.ascii.whitespace);
            if (space != null) return .{ .name = text };
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .{ .name = text };
            if (colon == 0) return .{ .name = text };
            for (text[0..colon]) |byte| {
                if (!std.ascii.isDigit(byte)) return .{ .name = text };
            }
            return .{ .id = text };
        }
    };

    pub fn parse(arguments: []const []const u8) ?Command {
        if (arguments.len < 2) return null;
        const name = arguments[1];
        const rest = arguments[2..];

        if (std.mem.eql(u8, name, "whoami")) {
            if (rest.len != 0) return null;
            return .whoami;
        }
        if (std.mem.eql(u8, name, "watch")) {
            if (rest.len != 0) return null;
            return .watch;
        }
        if (std.mem.eql(u8, name, "unread")) {
            if (rest.len != 0) return null;
            return .unread;
        }
        if (std.mem.eql(u8, name, "chats")) {
            if (rest.len > 1) return null;
            if (rest.len == 0) return .{ .chats = conversation_count_default };
            const count = parseCount(rest[0], conversation_count_limit) orelse return null;
            return .{ .chats = @intCast(count) };
        }
        if (std.mem.eql(u8, name, "messages")) {
            if (rest.len == 0) return null;
            if (rest.len > 2) return null;
            if (rest[0].len == 0) return null;
            const count = if (rest.len == 2)
                parseCount(rest[1], message_count_limit) orelse return null
            else
                message_count_default;
            return .{ .messages = .{ .chat = .parse(rest[0]), .count = count } };
        }
        if (std.mem.eql(u8, name, "send")) {
            if (rest.len != 2) return null;
            if (rest[0].len == 0) return null;
            if (std.mem.trim(u8, rest[1], &std.ascii.whitespace).len == 0) return null;
            return .{ .send = .{ .chat = .parse(rest[0]), .text = rest[1] } };
        }
        return null;
    }

    /// Sets `started_at` to idle once the Chat Service has answered, before any output is written.
    /// `stderr` is for `watch`'s retry notes; errors that end the command are the caller's.
    pub fn run(
        command: *const Command,
        client: *chat.Client,
        io: Io,
        clock: *Clock,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        started_at: *std.atomic.Value(i64),
    ) RunError!void {
        switch (command.*) {
            .watch => try watch(client, io, clock, stdout, stderr, started_at),
            .unread => try runUnread(client, clock, stdout, started_at),
            .whoami => {
                const user = try client.whoami();
                defer user.deinit();

                started_at.store(requests_idle, .release);

                try writeVisible(stdout, user.name);
                try stdout.writeAll(" <");
                try writeVisible(stdout, user.upn);
                try stdout.writeAll(">\n");
            },
            .send => |send| try runSend(client, clock, stdout, started_at, &send),
            .chats => |conversation_count| {
                try runChats(client, clock, stdout, started_at, conversation_count);
            },
            .messages => |messages| {
                // Holds a looked-up chat's id; freed with the command.
                var id_arena: std.heap.ArenaAllocator = .init(client.gpa);
                defer id_arena.deinit();

                const conversation_id = switch (messages.chat) {
                    .id => |id| id,
                    .name => |name| try findChat(
                        client,
                        id_arena.allocator(),
                        name,
                        clock,
                        stdout,
                        started_at,
                    ),
                };
                const list = try client.messages(conversation_id, messages.count);
                defer list.deinit();

                started_at.store(requests_idle, .release);

                // The service returns newest first; print oldest first, like a chat window.
                var index = list.items.len;
                while (index > 0) {
                    index -= 1;
                    try printMessage(stdout, clock, &list.items[index]);
                }
            },
        }
    }
};

/// Sends `send.text` as one message and prints when it arrived. Text too long to send is
/// refused before any request.
fn runSend(
    client: *chat.Client,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
    send: *const Command.Send,
) RunError!void {
    if (send.text.len > send_text_size_max) return error.SendTextTooLong;

    // Holds a looked-up chat's id and the message's HTML; freed with the command.
    var send_arena: std.heap.ArenaAllocator = .init(client.gpa);
    defer send_arena.deinit();

    const arena = send_arena.allocator();
    const conversation_id = switch (send.chat) {
        .id => |id| id,
        .name => |name| try findChat(client, arena, name, clock, stdout, started_at),
    };

    var html: Io.Writer.Allocating = .init(arena);
    // An Allocating writer fails only when it can't grow.
    chat.teams_html.writeMarkdown(&html.writer, send.text) catch return error.OutOfMemory;
    // The text holds more than whitespace (see `Command.parse`), so some HTML comes out.
    std.debug.assert(html.written().len > 0);
    if (html.written().len > chat.Client.content_size_max) return error.SendTextTooLong;

    const user = try client.whoami();
    defer user.deinit();

    const message_id = try client.send(conversation_id, &.{
        .content = html.written(),
        .display_name = user.name,
    });
    started_at.store(requests_idle, .release);

    var time_buffer: [short_time.width_max]u8 = undefined;
    // `send` takes only ids from 1970-01-02 to `message_id_max`, which `shortTimeAt` can show
    // (asserted at comptime above).
    const at_seconds: i64 = @intCast(@divFloor(message_id, std.time.ms_per_s));
    try stdout.print("Sent {s}.\n", .{clock.shortTimeAt(&time_buffer, at_seconds)});
}

/// Lists your `conversation_count` newest chats, one `printChat` row each.
fn runChats(
    client: *chat.Client,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
    conversation_count: u16,
) RunError!void {
    const user = try client.whoami();
    defer user.deinit();

    const list = try client.conversations(conversation_count);
    defer list.deinit();

    // Holds the 1:1 chat names; freed with the command.
    var names_arena: std.heap.ArenaAllocator = .init(client.gpa);
    defer names_arena.deinit();

    const arena = names_arena.allocator();
    const names = try otherPersonNames(client, arena, list.items, user.mri);
    started_at.store(requests_idle, .release);

    for (list.items, names) |*conversation, name| {
        const unread = conversation.isUnread(user.mri);
        try printChat(stdout, clock, conversation, name, unread);
    }
}

/// Starts a Chat Service client with the token and region from the environment (test mode) or,
/// normally, from the login keychain where the token script stored them.
pub fn connect(
    client: *chat.Client,
    gpa: std.mem.Allocator,
    io: Io,
    environment: *const std.process.Environ.Map,
) ConnectError!void {
    // Test mode: less secure, since any child process can read the environment, but it never
    // touches the keychain. An empty token counts as unset.
    if (environment.get(token_variable)) |environment_token| {
        if (environment_token.len > 0) {
            const region_name = environment.get(region_variable) orelse {
                return error.UnknownRegion;
            };
            try checkToken(environment_token);
            return client.init(gpa, io, try parseRegion(region_name), environment_token);
        }
    }

    const token = try readKeychain(gpa, io, "skype-token");
    defer {
        // Zeroed so our copy doesn't outlive its use. std's connection buffers still hold one
        // until the process exits.
        std.crypto.secureZero(u8, token);
        gpa.free(token);
    }

    // An empty item means the script never stored a real token.
    if (token.len == 0) return error.ItemNotFound;

    const region_name = readKeychain(gpa, io, "region") catch |err| switch (err) {
        // The token is there but the region isn't: say so, not "no token".
        error.ItemNotFound => return error.UnknownRegion,
        else => |other| return other,
    };
    defer gpa.free(region_name);

    try checkToken(token);
    try client.init(gpa, io, try parseRegion(region_name), token);
}

/// Reads one teams-zig keychain item through `/usr/bin/security`, which the token script also
/// writes with. Items made by `security` trust it, so no build of teams-zig gets an access
/// prompt, as it would reading through Security.framework itself. Owned by the caller.
fn readKeychain(
    gpa: std.mem.Allocator,
    io: Io,
    account: []const u8,
) KeychainReadError![]u8 {
    std.debug.assert(account.len > 0);
    const result = std.process.run(gpa, io, .{
        .exe = .detect,
        .argv = &.{
            security_path, "find-generic-password", "-s", keychain_service, "-a", account, "-w",
        },
        .stderr_limit = .limited(keychain_value_size_max),
        .stdout_limit = .limited(keychain_value_size_max),
        .reserve_amount = 64,
        .cwd = .inherit,
        .environ_map = null,
        .expand_arg0 = .no_expand,
        .progress_node = .none,
        .create_no_window = true,
        .timeout = .none,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.KeychainReadFailed,
    };
    gpa.free(result.stderr);
    defer {
        std.crypto.secureZero(u8, result.stdout);
        gpa.free(result.stdout);
    }

    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {},
            security_exit_item_not_found => return error.ItemNotFound,
            else => return error.KeychainReadFailed,
        },
        else => return error.KeychainReadFailed,
    }
    // security ends the value with a newline.
    const value = std.mem.trimEnd(u8, result.stdout, "\n");
    return gpa.dupe(u8, value);
}

/// The token goes into a request header, where a line break would end the header early.
fn checkToken(token: []const u8) error{InvalidToken}!void {
    if (std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidToken;
}

fn parseRegion(region_name: []const u8) error{UnknownRegion}!chat.Client.Region {
    return std.meta.stringToEnum(chat.Client.Region, region_name) orelse error.UnknownRegion;
}

/// Where a conversation's display name comes from when it has no topic.
const NameSource = union(enum) {
    /// Not a 1:1 chat, or it has a topic of its own.
    none,
    /// The other person wrote the last message; this is their name.
    known: []const u8,
    /// You wrote the last message (or it was an event), so their name needs a lookup.
    lookup,
};

fn nameSource(conversation: *const chat.Conversation, self_mri: []const u8) NameSource {
    std.debug.assert(self_mri.len > 0);
    if (!conversation.isOneToOne()) return .none;
    if (conversation.topic != null) return .none;

    const last_sender = conversation.last_sender orelse return .lookup;
    if (std.mem.eql(u8, last_sender, self_mri)) return .lookup;
    const name = conversation.last_sender_name orelse return .lookup;
    return .{ .known = name };
}

/// Polls your newest chats every `watch_poll_seconds` and prints each new message, oldest first,
/// after its chat's name. The first poll only records where things stand. Throttling, server
/// errors and network failures back off, doubling up to `watch_backoff_seconds_max`; anything
/// else (an expired token, say) ends the command.
fn watch(
    client: *chat.Client,
    io: Io,
    clock: *Clock,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    started_at: *std.atomic.Value(i64),
) RunError!void {
    const user = try client.whoami();
    defer user.deinit();

    var seen: Seen = seen: {
        const list = try client.conversations(conversation_count_default);
        defer list.deinit();
        break :seen try .init(client.gpa, list.items);
    };
    defer seen.deinit();

    started_at.store(requests_idle, .release);
    try stdout.writeAll("Watching your newest chats for new messages. Ctrl-C stops.\n");
    try stdout.flush();

    var pause_seconds: u32 = watch_poll_seconds;
    while (true) {
        io.sleep(.fromSeconds(pause_seconds), .awake) catch |err| switch (err) {
            // Nothing cancels the main thread; if something ever does, watching is over.
            error.Canceled => return,
        };

        started_at.store(Io.Clock.awake.now(io).toSeconds(), .release);
        clock.now_seconds = Io.Clock.real.now(io).toSeconds();
        if (pollChats(client, clock, &seen, user.mri, stdout)) {
            pause_seconds = watch_poll_seconds;
        } else |err| {
            if (!watchErrorRetries(err, client.response_status)) return err;
            pause_seconds = @min(pause_seconds * 2, watch_backoff_seconds_max);
            _ = try reportError(stderr, err, client.response_status);
            try stderr.print("teams-zig: trying again in {d} seconds\n", .{pause_seconds});
            try stderr.flush();
        }
        started_at.store(requests_idle, .release);
        try stdout.flush();
    }
}

/// One `watch` poll: lists your newest chats and prints the new messages in up to
/// `watch_read_count_limit` that changed; the rest wait for the next poll.
fn pollChats(
    client: *chat.Client,
    clock: *const Clock,
    seen: *Seen,
    self_mri: []const u8,
    stdout: *Io.Writer,
) RunError!void {
    const list = try client.conversations(conversation_count_default);
    defer list.deinit();

    var read_count_left: u32 = watch_read_count_limit;
    for (list.items) |*conversation| {
        if (!seen.changed(conversation)) continue;
        if (read_count_left == 0) break;
        read_count_left -= 1;
        try printNewMessages(client, clock, seen, conversation, self_mri, stdout);
    }
}

/// Reads a changed chat's newest page and prints the messages newer than its mark, then moves
/// the mark to the chat's last message.
fn printNewMessages(
    client: *chat.Client,
    clock: *const Clock,
    seen: *Seen,
    conversation: *const chat.Conversation,
    self_mri: []const u8,
    stdout: *Io.Writer,
) RunError!void {
    std.debug.assert(seen.changed(conversation));
    const last_message_id = conversation.last_message_id.?;
    const recent = client.recentMessages(conversation.id, message_count_recent) catch |err| {
        if (!lookupErrorSkips(err, client.response_status)) return err;
        // This one chat can't be read; move past it rather than retry it every poll.
        return seen.record(conversation.id, last_message_id);
    };
    defer recent.deinit();

    // One page: in a chat that gets more than `message_count_recent` messages between polls,
    // the oldest of them aren't shown.
    const mark = seen.mark(conversation.id);
    try printMessagesAfter(stdout, clock, conversation, self_mri, recent.items, mark);
    try seen.record(conversation.id, last_message_id);
}

/// Prints the text messages in `recent` (newest first, as the service returns them) whose id is
/// past `mark`, oldest first, each after its chat's name: `[name] time  sender: body`.
fn printMessagesAfter(
    stdout: *Io.Writer,
    clock: *const Clock,
    conversation: *const chat.Conversation,
    self_mri: []const u8,
    recent: []const chat.Message,
    mark: u64,
) Io.Writer.Error!void {
    const known_name = switch (nameSource(conversation, self_mri)) {
        .known => |known| known,
        .none, .lookup => otherWriterName(recent, self_mri),
    };
    const name = chatName(conversation, known_name) orelse "(no topic)";

    var index = recent.len;
    while (index > 0) {
        index -= 1;
        const message = &recent[index];
        if (!message.isText()) continue;
        const message_id = std.fmt.parseInt(u64, message.id, 10) catch continue;
        if (message_id <= mark) continue;

        try stdout.writeByte('[');
        try writeVisible(stdout, name);
        try stdout.writeAll("] ");
        try printMessage(stdout, clock, message);
    }
}

/// One unread chat and its newest page of messages, read before anything is printed.
const UnreadChat = struct {
    conversation: *const chat.Conversation,
    recent: chat.Message.List,
};

/// Prints what's new since your read marker in up to `unread_read_count_limit` unread chats
/// among your newest, the same way `watch` does. A chat that can't be read is counted with the
/// ones not shown. Every request finishes before the first line is written.
fn runUnread(
    client: *chat.Client,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
) RunError!void {
    const user = try client.whoami();
    defer user.deinit();

    const list = try client.conversations(conversation_count_default);
    defer list.deinit();

    var reads_buffer: [unread_read_count_limit]UnreadChat = undefined;
    var reads_count: u32 = 0;
    defer for (reads_buffer[0..reads_count]) |*read| read.recent.deinit();

    var unread_count: u32 = 0;
    for (list.items) |*conversation| {
        if (!conversation.isUnread(user.mri)) continue;
        unread_count += 1;
        if (reads_count == unread_read_count_limit) continue;

        const recent = client.recentMessages(conversation.id, message_count_recent) catch |err| {
            if (lookupErrorSkips(err, client.response_status)) continue;
            return err;
        };
        reads_buffer[reads_count] = .{ .conversation = conversation, .recent = recent };
        reads_count += 1;
    }
    started_at.store(requests_idle, .release);
    std.debug.assert(reads_count <= unread_count);
    std.debug.assert(reads_count <= unread_read_count_limit);

    if (unread_count == 0) return stdout.writeAll("No unread messages.\n");
    for (reads_buffer[0..reads_count]) |*read| {
        // isUnread holds only with a read marker.
        const mark = read.conversation.read_up_to_id.?;
        try printMessagesAfter(
            stdout,
            clock,
            read.conversation,
            user.mri,
            read.recent.items,
            mark,
        );
    }
    if (unread_count > reads_count) {
        try stdout.print("{d} more unread chats not shown.\n", .{unread_count - reads_count});
    }
}

/// Whether `watch` should wait and try again after `err` rather than stop: throttling, server
/// errors and network failures pass; anything else would fail the same way next time.
/// `status` is the response's, set whenever the error is UnexpectedStatus.
fn watchErrorRetries(err: RunError, status: ?std.http.Status) bool {
    return switch (err) {
        error.ConnectFailed, error.SendFailed, error.ConnectionDropped => true,
        error.UnexpectedStatus => retries: {
            if (status.? == .too_many_requests) break :retries true;
            break :retries status.?.class() == .server_error;
        },
        else => false,
    };
}

/// The id, owned by `arena`, of the one chat among your newest `conversation_count_limit` named
/// `name`. Known names are tried first; the per-chat lookups run only if none of them match.
/// Several matches are listed on `stdout`, with their ids, before ChatNameAmbiguous.
fn findChat(
    client: *chat.Client,
    arena: std.mem.Allocator,
    name: []const u8,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
) RunError![]const u8 {
    std.debug.assert(name.len > 0);
    const user = try client.whoami();
    defer user.deinit();

    const list = try client.conversations(conversation_count_limit);
    defer list.deinit();

    // conversations() returns at most the count it was asked for.
    std.debug.assert(list.items.len <= conversation_count_limit);
    var known_names_buffer: [conversation_count_limit]?[]const u8 = undefined;
    var names: []?[]const u8 = known_names_buffer[0..list.items.len];
    for (list.items, names) |*conversation, *other_name| {
        other_name.* = switch (nameSource(conversation, user.mri)) {
            .known => |known| known,
            .none, .lookup => null,
        };
    }
    var match = matchChat(list.items, names, name);
    if (match == .none) {
        names = try otherPersonNames(client, arena, list.items, user.mri);
        match = matchChat(list.items, names, name);
    }

    switch (match) {
        .none => return error.ChatNameNotFound,
        .one => |index| return try arena.dupe(u8, list.items[index].id),
        .several => {
            started_at.store(requests_idle, .release);
            for (list.items, names) |*conversation, other_name| {
                const chat_name = chatName(conversation, other_name) orelse continue;
                if (!std.ascii.eqlIgnoreCase(chat_name, name)) continue;
                const unread = conversation.isUnread(user.mri);
                try printChat(stdout, clock, conversation, other_name, unread);
            }
            return error.ChatNameAmbiguous;
        },
    }
}

/// One `chats` row: a `*` if unread, last message time, kind, name and id.
fn printChat(
    stdout: *Io.Writer,
    clock: *const Clock,
    conversation: *const chat.Conversation,
    other_name: ?[]const u8,
    unread: bool,
) Io.Writer.Error!void {
    try stdout.writeAll(if (unread) "* " else "  ");
    const last_message_at = conversation.last_message_at orelse "-";
    var time_buffer: [short_time.width_max]u8 = undefined;
    const time = clock.shortTime(&time_buffer, last_message_at) orelse last_message_at;
    try writeVisible(stdout, time);
    try stdout.splatByteAll(' ', short_time.width_max -| time.len);
    try stdout.print("  {t:<7}  ", .{conversation.kind});
    try writeVisible(stdout, chatName(conversation, other_name) orelse "(no topic)");
    try stdout.writeAll("  ");
    try writeVisible(stdout, conversation.id);
    try stdout.writeByte('\n');
}

/// Which chats a name typed on the command line picks.
const ChatMatch = union(enum) {
    none,
    one: usize,
    several,
};

/// Finds the chats whose name, as `chats` shows it (`chatName`), equals `wanted` ignoring ASCII
/// case. `other_names` holds the other person's name for each conversation, or null.
fn matchChat(
    conversations: []const chat.Conversation,
    other_names: []const ?[]const u8,
    wanted: []const u8,
) ChatMatch {
    std.debug.assert(conversations.len == other_names.len);
    std.debug.assert(wanted.len > 0);
    var match: ChatMatch = .none;
    for (conversations, other_names, 0..) |*conversation, other_name, index| {
        const name = chatName(conversation, other_name) orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, wanted)) continue;
        match = switch (match) {
            .none => .{ .one = index },
            .one, .several => .several,
        };
    }
    return match;
}

/// The name `chats` shows for a conversation: its topic, or the other person in a 1:1 chat.
fn chatName(conversation: *const chat.Conversation, other_name: ?[]const u8) ?[]const u8 {
    return conversation.topic orelse other_name;
}

/// The other person's name for each 1:1 chat in `conversations`, owned by `arena`; null where
/// there's none to show. At most `name_lookup_count_limit` chats get a lookup, one request each.
fn otherPersonNames(
    client: *chat.Client,
    arena: std.mem.Allocator,
    conversations: []const chat.Conversation,
    self_mri: []const u8,
) chat.Client.Error![]?[]const u8 {
    const names = try arena.alloc(?[]const u8, conversations.len);
    var name_lookup_count_left: u32 = name_lookup_count_limit;
    for (conversations, names) |*conversation, *name| {
        name.* = switch (nameSource(conversation, self_mri)) {
            .none => null,
            .known => |known| try arena.dupe(u8, known),
            .lookup => lookup: {
                if (name_lookup_count_left == 0) break :lookup null;
                name_lookup_count_left -= 1;
                break :lookup try lookUpOtherName(client, arena, conversation.id, self_mri);
            },
        };
    }
    return names;
}

/// Reads one page of a 1:1 chat's recent messages and returns the other writer's name, owned
/// by `arena`, or null if they haven't written there recently.
fn lookUpOtherName(
    client: *chat.Client,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
    self_mri: []const u8,
) chat.Client.Error!?[]const u8 {
    const recent = client.recentMessages(conversation_id, message_count_recent) catch |err| {
        if (lookupErrorSkips(err, client.response_status)) return null;
        return err;
    };
    defer recent.deinit();

    const name = otherWriterName(recent.items, self_mri) orelse return null;
    return try arena.dupe(u8, name);
}

/// Whether a failed lookup should just leave that chat unnamed. Errors about one chat skip it;
/// throttling, server errors, an expired token or no network would hit every chat, so they stop
/// the command. `status` is the response's, set whenever the error is UnexpectedStatus.
fn lookupErrorSkips(err: chat.Client.Error, status: ?std.http.Status) bool {
    return switch (err) {
        error.NotFound, error.UnexpectedJson => true,
        error.UnexpectedStatus => skips: {
            if (status.? == .too_many_requests) break :skips false;
            break :skips status.?.class() != .server_error;
        },
        else => false,
    };
}

/// The display name on the newest user-written message (`messages` is newest first) from someone
/// other than `self_mri`. System events and their senders don't count. Borrows from `messages`.
fn otherWriterName(messages: []const chat.Message, self_mri: []const u8) ?[]const u8 {
    std.debug.assert(self_mri.len > 0);
    for (messages) |*message| {
        if (!message.isText()) continue;
        const sender = message.sender orelse continue;
        if (std.mem.eql(u8, sender, self_mri)) continue;
        return message.sender_name orelse continue;
    }
    return null;
}

/// A count from the command line: a whole number from 1 to `count_max`, or null.
fn parseCount(text: []const u8, count_max: u32) ?u32 {
    std.debug.assert(count_max > 0);
    const count = std.fmt.parseInt(u32, text, 10) catch return null;
    if (count == 0) return null;
    if (count > count_max) return null;
    return count;
}

/// `time  sender: ` and the body as Markdown, which continues on the following lines when it
/// has more than one.
fn printMessage(
    stdout: *Io.Writer,
    clock: *const Clock,
    message: *const chat.Message,
) Io.Writer.Error!void {
    const sender = message.sender_name orelse message.sender orelse "(unknown sender)";
    var time_buffer: [short_time.width_max]u8 = undefined;
    try writeVisible(stdout, clock.shortTime(&time_buffer, message.arrived_at) orelse
        message.arrived_at);
    try stdout.writeAll("  ");
    try writeVisible(stdout, sender);
    try stdout.writeAll(": ");

    if (message.deleted_at_ms != null) {
        try stdout.writeAll("(deleted)");
    } else if (message.isText()) {
        try message.writeText(stdout);
    } else {
        try stdout.writeByte('[');
        try writeVisible(stdout, message.message_type);
        try stdout.writeByte(']');
    }
    try stdout.writeByte('\n');
}

/// Prints a one-line hint for every way a command can fail. The switch is exhaustive, so a new
/// error in the client or keychain doesn't compile until it has a hint.
pub fn reportError(
    stderr: *Io.Writer,
    err: CommandError,
    response_status: ?std.http.Status,
) Io.Writer.Error!u8 {
    const rerun_script = "run scripts/teams-token.fish";
    const hint = switch (err) {
        error.ItemNotFound => "no token in the login keychain; " ++ rerun_script,
        error.InvalidToken => "the token contains a line break; " ++ rerun_script,
        error.UnknownRegion => "the region is missing or unknown; " ++ rerun_script ++
            " (in test mode, set " ++ region_variable ++ ")",
        error.KeychainReadFailed => "couldn't read the teams-zig items with " ++ security_path ++
            "; is the keychain locked?",
        error.OutOfMemory => "out of memory",
        error.TokenExpired => "the skype token has expired; " ++ rerun_script,
        error.NotFound => "no conversation with that id, or it isn't yours",
        error.ChatNameNotFound => "no chat with exactly that name among your " ++
            std.fmt.comptimePrint("{d}", .{conversation_count_limit}) ++
            " newest; check the spelling, or use its id from teams-zig chats",
        error.ChatNameAmbiguous => "several chats have that name; use one of the ids above",
        error.SendTextTooLong => "the text is too long: at most " ++
            std.fmt.comptimePrint("{d}", .{send_text_size_max / 1024}) ++
            " KiB, and less if it holds many of & < > \"",
        error.ConversationIdTooLong => "the Chat Service sent a chat id longer than teams-zig " ++
            "keeps track of",
        error.UnexpectedStatus => {
            // Client sets response_status before it returns UnexpectedStatus.
            std.debug.assert(response_status != null);
            try stderr.print(
                "teams-zig: the Chat Service answered HTTP {d}\n",
                .{@backingInt(response_status.?)},
            );
            try stderr.flush();
            return 1;
        },
        error.ForeignLink => "the Chat Service sent a link teams-zig won't follow",
        error.Redirected => "the Chat Service redirected; not following, so the token stays there",
        error.ConnectFailed => "couldn't reach the Chat Service; check the network",
        // A send that failed this way may still have arrived, so look before sending it again.
        error.SendFailed => "couldn't send the request to the Chat Service; try again " ++
            "(after a send, check the chat first)",
        error.ConnectionDropped => "the connection dropped mid-response; try again " ++
            "(after a send, check the chat first)",
        error.BadResponse => "the Chat Service sent a response that isn't valid HTTP",
        error.UnexpectedJson => "the Chat Service's reply had an unexpected shape",
        error.ResponseTooLarge => "the Chat Service sent a response larger than teams-zig accepts",
        // Only writes to stdout return WriteFailed here, as when a pipe reader like `head` exits.
        error.WriteFailed => "couldn't write the output; was the pipe closed?",
    };
    try stderr.print("teams-zig: {s}\n", .{hint});
    try stderr.flush();
    return 1;
}

test {
    _ = Seen;
    _ = short_time;
}

test "Command.parse accepts the commands and rejects anything else" {
    try std.testing.expectEqual(Command.whoami, Command.parse(&.{ "teams-zig", "whoami" }).?);
    try std.testing.expectEqual(Command.unread, Command.parse(&.{ "teams-zig", "unread" }).?);

    const send = Command.parse(&.{ "teams-zig", "send", "48:notes", "**fake**" }).?;
    try std.testing.expectEqualStrings("48:notes", send.send.chat.id);
    try std.testing.expectEqualStrings("**fake**", send.send.text);

    const chats = Command.parse(&.{ "teams-zig", "chats" }).?;
    try std.testing.expectEqual(conversation_count_default, chats.chats);
    const chats_ten = Command.parse(&.{ "teams-zig", "chats", "10" }).?;
    try std.testing.expectEqual(10, chats_ten.chats);
    const chats_max = Command.parse(&.{ "teams-zig", "chats", "100" }).?;
    try std.testing.expectEqual(conversation_count_limit, chats_max.chats);

    const messages = Command.parse(&.{ "teams-zig", "messages", "19:fake" }).?;
    try std.testing.expectEqualStrings("19:fake", messages.messages.chat.id);
    try std.testing.expectEqual(message_count_default, messages.messages.count);
    const messages_five = Command.parse(&.{ "teams-zig", "messages", "19:fake", "5" }).?;
    try std.testing.expectEqual(5, messages_five.messages.count);
    const messages_one = Command.parse(&.{ "teams-zig", "messages", "19:fake", "1" }).?;
    try std.testing.expectEqual(1, messages_one.messages.count);
    const messages_max = Command.parse(&.{ "teams-zig", "messages", "19:fake", "12800" }).?;
    try std.testing.expectEqual(message_count_limit, messages_max.messages.count);
    const too_many = Command.parse(&.{ "teams-zig", "messages", "19:x", "12801" });
    try std.testing.expectEqual(null, too_many);

    try std.testing.expectEqual(null, Command.parse(&.{"teams-zig"}));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "whoami", "x" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "unread", "5" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "chats", "0" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "chats", "101" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "chats", "ten" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages", "" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages", "19:x", "-1" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send", "48:notes" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send", "48:notes", " \n" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send", "", "fake" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send", "a", "b", "c" }));
}

test "Command.Chat.parse tells ids from names" {
    const thread_id = "19:fake@thread.v2";
    try std.testing.expectEqualStrings(thread_id, Command.Chat.parse(thread_id).id);
    try std.testing.expectEqualStrings("48:notes", Command.Chat.parse("48:notes").id);
    try std.testing.expectEqualStrings("Fake Person", Command.Chat.parse("Fake Person").name);
    try std.testing.expectEqualStrings("Fake: standup", Command.Chat.parse("Fake: standup").name);
    try std.testing.expectEqualStrings(":fake", Command.Chat.parse(":fake").name);
    try std.testing.expectEqualStrings("2026 plans", Command.Chat.parse("2026 plans").name);
    try std.testing.expectEqualStrings("9:30 Standup", Command.Chat.parse("9:30 Standup").name);
}

test "matchChat matches whole names ignoring case, and reports several" {
    const template: chat.Conversation = .{
        .id = "19:fake@thread.v2",
        .kind = .chat,
        .topic = null,
        .last_message_at = null,
        .last_sender = null,
        .last_sender_name = null,
        .last_message_id = null,
        .read_up_to_id = null,
    };
    var conversations: [3]chat.Conversation = @splat(template);
    conversations[1].topic = "Fake Standup";
    const other_names = [_]?[]const u8{ "Fake Person", null, "Fake Other" };

    const names = &other_names;
    const person = matchChat(&conversations, names, "fake person");
    try std.testing.expectEqual(ChatMatch{ .one = 0 }, person);
    const standup = matchChat(&conversations, names, "FAKE STANDUP");
    try std.testing.expectEqual(ChatMatch{ .one = 1 }, standup);
    try std.testing.expectEqual(ChatMatch.none, matchChat(&conversations, names, "Fake"));
    try std.testing.expectEqual(ChatMatch.none, matchChat(&conversations, names, "Fake Person 2"));

    conversations[2].topic = "fake person";
    try std.testing.expectEqual(ChatMatch.several, matchChat(&conversations, names, "Fake Person"));
}

test "watchErrorRetries waits out throttling and network failures, and stops on the rest" {
    try std.testing.expect(watchErrorRetries(error.UnexpectedStatus, .too_many_requests));
    try std.testing.expect(watchErrorRetries(error.UnexpectedStatus, .service_unavailable));
    try std.testing.expect(watchErrorRetries(error.ConnectFailed, null));
    try std.testing.expect(watchErrorRetries(error.ConnectionDropped, null));
    try std.testing.expect(!watchErrorRetries(error.UnexpectedStatus, .forbidden));
    try std.testing.expect(!watchErrorRetries(error.TokenExpired, .unauthorized));
    try std.testing.expect(!watchErrorRetries(error.WriteFailed, null));
}

test "printMessage starts each message on its time and sender line" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const zone = try core_foundation.TimeZone.createFixed(std.time.s_per_hour);
    defer core_foundation.release(zone);

    // 2026-11-06T12:00:00Z, so the first message is today and the second three days back.
    const clock: Clock = .{ .zone = zone, .now_seconds = 1_793_966_400 };

    var message: chat.Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = "8:orgid:fake",
        .sender_name = "Fake Person",
        .content = "<p>fake one</p><p>fake <b>two</b></p>",
        .arrived_at = "2026-11-06T10:00:00.000Z",
        .deleted_at_ms = null,
    };
    try printMessage(&out.writer, &clock, &message);
    message.sender_name = null;
    message.deleted_at_ms = 1;
    message.arrived_at = "2026-11-03T22:30:00.000Z";
    try printMessage(&out.writer, &clock, &message);
    message.arrived_at = "fake time";
    try printMessage(&out.writer, &clock, &message);

    try std.testing.expectEqualStrings(
        \\11:00  Fake Person: fake one
        \\fake **two**
        \\Tue 23:30  8:orgid:fake: (deleted)
        \\fake time  8:orgid:fake: (deleted)
        \\
    , out.written());
}

test "printMessagesAfter prints text messages past the mark, oldest first, after the chat's name" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const zone = try core_foundation.TimeZone.createFixed(0);
    defer core_foundation.release(zone);

    const clock: Clock = .{ .zone = zone, .now_seconds = 1_793_966_400 };
    const self_mri = "8:orgid:fake-self";
    const conversation: chat.Conversation = .{
        .id = "19:fake-group@thread.v2",
        .kind = .chat,
        .topic = "Fake topic",
        .last_message_at = null,
        .last_sender = null,
        .last_sender_name = null,
        .last_message_id = null,
        .read_up_to_id = null,
    };
    const template: chat.Message = .{
        .id = "",
        .message_type = "Text",
        .sender = "8:orgid:fake-other",
        .sender_name = "Fake Other",
        .content = "",
        .arrived_at = "2026-11-06T11:00:00.000Z",
        .deleted_at_ms = null,
    };
    var messages = [_]chat.Message{ template, template, template, template, template };
    // Newest first, as the service returns them.
    messages[0].id = "3000";
    messages[0].content = "fake newest";
    messages[1].id = "2500";
    messages[1].message_type = "ThreadActivity/AddMember";
    messages[2].id = "fake-id";
    messages[3].id = "2000";
    messages[3].content = "fake older";
    messages[4].id = "1000";
    messages[4].content = "fake at the mark";

    try printMessagesAfter(&out.writer, &clock, &conversation, self_mri, &messages, 1000);
    try std.testing.expectEqualStrings(
        \\[Fake topic] 11:00  Fake Other: fake older
        \\[Fake topic] 11:00  Fake Other: fake newest
        \\
    , out.written());
}

test "checkToken rejects line breaks" {
    try checkToken("fake-token");
    try std.testing.expectError(error.InvalidToken, checkToken("fake\r\nX-Injected: 1"));
    try std.testing.expectError(error.InvalidToken, checkToken("fake\n"));
}

test "otherWriterName takes the newest user-written message from someone else" {
    const self_mri = "8:orgid:fake-self";
    const template: chat.Message = .{
        .id = "",
        .message_type = "RichText/Html",
        .sender = self_mri,
        .sender_name = "Fake Self",
        .content = "",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var messages = [_]chat.Message{ template, template, template, template };
    // Newest first: mine, a system event from a bot, then the other person, then older.
    messages[1].message_type = "ThreadActivity/AddMember";
    messages[1].sender = "28:fake-bot";
    messages[1].sender_name = "Fake Bot";
    messages[2].sender = "8:orgid:fake-other";
    messages[2].sender_name = "Fake Other";
    messages[3].sender = "8:orgid:fake-older";
    messages[3].sender_name = "Fake Older";

    try std.testing.expectEqualStrings("Fake Other", otherWriterName(&messages, self_mri).?);
    try std.testing.expectEqual(null, otherWriterName(messages[0..2], self_mri));

    // A message with no sender, or no name, is passed over for an older one.
    messages[2].sender_name = null;
    try std.testing.expectEqualStrings("Fake Older", otherWriterName(&messages, self_mri).?);
    messages[2].sender = null;
    try std.testing.expectEqualStrings("Fake Older", otherWriterName(&messages, self_mri).?);
}

test "nameSource uses the last writer when it isn't you, and asks for a lookup when it is" {
    const self_mri = "8:orgid:fake-self";
    var conversation: chat.Conversation = .{
        .id = "19:fake-self_fake-other@unq.gbl.spaces",
        .kind = .chat,
        .topic = null,
        .last_message_at = null,
        .last_sender = "8:orgid:fake-other",
        .last_sender_name = "Fake Other",
        .last_message_id = null,
        .read_up_to_id = null,
    };
    try std.testing.expectEqualStrings("Fake Other", nameSource(&conversation, self_mri).known);

    conversation.last_sender = self_mri;
    try std.testing.expectEqual(NameSource.lookup, nameSource(&conversation, self_mri));

    conversation.last_sender = null;
    try std.testing.expectEqual(NameSource.lookup, nameSource(&conversation, self_mri));

    conversation.topic = "Fake topic";
    try std.testing.expectEqual(NameSource.none, nameSource(&conversation, self_mri));

    conversation.topic = null;
    conversation.id = "19:fake-group@thread.v2";
    try std.testing.expectEqual(NameSource.none, nameSource(&conversation, self_mri));
}

test "lookupErrorSkips skips errors about one chat and stops on ones that hit every chat" {
    try std.testing.expect(lookupErrorSkips(error.NotFound, .not_found));
    try std.testing.expect(lookupErrorSkips(error.UnexpectedJson, .ok));
    try std.testing.expect(lookupErrorSkips(error.UnexpectedStatus, .forbidden));
    try std.testing.expect(!lookupErrorSkips(error.UnexpectedStatus, .too_many_requests));
    try std.testing.expect(!lookupErrorSkips(error.UnexpectedStatus, .service_unavailable));
    try std.testing.expect(!lookupErrorSkips(error.TokenExpired, .unauthorized));
    try std.testing.expect(!lookupErrorSkips(error.ConnectFailed, null));
}

test "runSend refuses text too long to send before any request" {
    var client: chat.Client = undefined;
    // A fake token: a request would be refused with another error. None is expected, which
    // `response_status` staying null confirms.
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();

    const zone = try core_foundation.TimeZone.createFixed(0);
    defer core_foundation.release(zone);

    const clock: Clock = .{ .zone = zone, .now_seconds = 1_793_966_400 };
    var started_at: std.atomic.Value(i64) = .init(requests_idle);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const long_text: [send_text_size_max + 1]u8 = @splat('a');
    const too_long: Command.Send = .{ .chat = .{ .id = "48:notes" }, .text = &long_text };
    const too_long_result = runSend(&client, &clock, &out.writer, &started_at, &too_long);
    try std.testing.expectError(error.SendTextTooLong, too_long_result);

    // Under the text cap, but `"` becomes `&quot;`, so the HTML is far over its own.
    const quotes: [send_text_size_max]u8 = @splat('"');
    const quoted: Command.Send = .{ .chat = .{ .id = "48:notes" }, .text = &quotes };
    const quoted_result = runSend(&client, &clock, &out.writer, &started_at, &quoted);
    try std.testing.expectError(error.SendTextTooLong, quoted_result);
    try std.testing.expectEqual(null, client.response_status);
    try std.testing.expectEqualStrings("", out.written());
}
