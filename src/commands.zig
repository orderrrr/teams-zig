const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const writeVisible = chat.text.writeVisible;
const Seen = @import("Seen.zig");
const short_time = @import("short_time.zig");
const core_foundation = teams.macos.core_foundation;
const Cache = @import("Cache.zig");
const keychain = @import("keychain.zig");

/// Test mode: set these to skip the keychain. See `usage`.
const token_variable = "TEAMS_ZIG_SKYPE_TOKEN";
const region_variable = "TEAMS_ZIG_REGION";

pub const conversation_count_default = 50;
pub const message_count_default = 50;

/// `chats` names 1:1 chats with up to one request each, all inside the watchdog's limit, so the
/// list stays at one page of modest size.
pub const conversation_count_limit = 100;

/// At most this many 1:1 chats get a recent-messages lookup per run; at about a second each on a
/// slow link, they stay inside the watchdog's 60 seconds. Chats past it show "(no topic)".
const name_lookup_count_limit = 40;

comptime {
    std.debug.assert(conversation_count_limit <= std.math.maxInt(u16));
    // A full listing rewrites the cache's name map, so the map's limit is the listing's size.
    std.debug.assert(Cache.chat_count_max == conversation_count_limit);
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

pub const message_count_limit = chat.Client.message_count_limit;

/// How far back `chats` looks for the other person's name in a 1:1 chat where you spoke last.
const message_count_recent = 20;

/// How often `watch` lists your chats when all is well.
const watch_poll_seconds = 10;

/// At most this many changed chats are read per `watch` poll, so a burst can't flood the service.
const watch_read_count_limit = 10;

/// At most this many unread chats are read by `unread`, keeping its requests inside the
/// watchdog's limit.
pub const unread_read_count_limit = 10;

/// The most text `send` takes. Its HTML is checked too (see `chat.Client.content_size_max`),
/// since escaping makes the HTML longer than the text.
pub const send_text_size_max = 16 * 1024;

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
const ConnectError = keychain.ReadError || error{ UnknownRegion, InvalidToken };

/// Failures running a command: the Chat Service's, writing the output, or a chat name that
/// picks no chat or several.
const RunError = chat.Client.Error || Io.Writer.Error || ChatNameError || WatchError || SendError;

const ChatNameError = error{ ChatNameNotFound, ChatNameAmbiguous };

/// Failures of `send` found before any request.
const SendError = error{SendTextTooLong};

/// Failures of `watch` beyond the Chat Service's and the output's.
const WatchError = Seen.Error;

/// Every way a command can fail.
pub const CommandError = ConnectError || RunError;

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
            if (rest.len == 0) return initChats(null);
            return initChats(parseCount(rest[0]) orelse return null);
        }
        if (std.mem.eql(u8, name, "messages")) {
            if (rest.len == 0) return null;
            if (rest.len > 2) return null;
            if (rest.len == 1) return initMessages(rest[0], null);
            return initMessages(rest[0], parseCount(rest[1]) orelse return null);
        }
        if (std.mem.eql(u8, name, "send")) {
            if (rest.len != 2) return null;
            return initSend(rest[0], rest[1]);
        }
        return null;
    }

    /// `chats` with `count` conversations (null for the default), or null if it is outside
    /// 1 to `conversation_count_limit`. Shared by the CLI and the MCP server.
    pub fn initChats(count: ?u32) ?Command {
        const conversation_count = count orelse conversation_count_default;
        if (conversation_count == 0) return null;
        if (conversation_count > conversation_count_limit) return null;
        return .{ .chats = @intCast(conversation_count) };
    }

    /// `messages` for the chat typed as `chat_text`, with `count` messages (null for the
    /// default), or null if the chat is empty or the count is outside 1 to `message_count_limit`.
    /// Borrows `chat_text`.
    pub fn initMessages(chat_text: []const u8, count: ?u32) ?Command {
        if (chat_text.len == 0) return null;
        const message_count = count orelse message_count_default;
        if (message_count == 0) return null;
        if (message_count > message_count_limit) return null;
        return .{ .messages = .{ .chat = .parse(chat_text), .count = message_count } };
    }

    /// `send` of `text` to the chat typed as `chat_text`, or null if the chat is empty, or the
    /// text holds only whitespace or a control character other than tab and newline: C0, DEL
    /// or a UTF-8 C1, as `messages` shows them (`chat.text.controlLenAt`). Borrows both. The
    /// size checks come later, in `runSend`.
    pub fn initSend(chat_text: []const u8, text: []const u8) ?Command {
        if (chat_text.len == 0) return null;
        if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) return null;
        // Every offset is checked; one inside a multi-byte character never starts a control.
        for (0..text.len) |index| {
            if (chat.text.controlLenAt(text[index..]) > 0) return null;
        }
        return .{ .send = .{ .chat = .parse(chat_text), .text = text } };
    }

    /// Sets `started_at` to idle once the Chat Service has answered, before any output is written.
    /// `stderr` is for `watch`'s retry notes; errors that end the command are the caller's.
    pub fn run(
        command: *const Command,
        client: *chat.Client,
        cache: *Cache,
        io: Io,
        clock: *Clock,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        started_at: *std.atomic.Value(i64),
    ) RunError!void {
        switch (command.*) {
            .watch => try watch(client, io, clock, stdout, stderr, started_at),
            .unread => try runUnread(client, cache, clock, stdout, started_at),
            .whoami => {
                // Always asked: whoami is the check that the token works. The answer refreshes
                // the cache.
                const user = try client.whoami();
                defer user.deinit();
                try cache.putSelf(&.{ .mri = user.mri, .name = user.name, .upn = user.upn });

                started_at.store(requests_idle, .release);

                try writeVisible(stdout, user.name);
                try stdout.writeAll(" <");
                try writeVisible(stdout, user.upn);
                try stdout.writeAll(">\n");
            },
            .send => |send| try runSend(client, cache, clock, stdout, started_at, &send),
            .chats => |conversation_count| {
                try runChats(client, cache, clock, stdout, started_at, conversation_count);
            },
            .messages => |messages| {
                // Holds a looked-up chat's id; freed with the command.
                var id_arena: std.heap.ArenaAllocator = .init(client.gpa);
                defer id_arena.deinit();

                const found: FoundChat = switch (messages.chat) {
                    .id => |id| .{ .given = id },
                    .name => |name| try findChat(
                        client,
                        cache,
                        id_arena.allocator(),
                        name,
                        clock,
                        stdout,
                        started_at,
                    ),
                };
                const list = client.messages(found.id(), messages.count) catch |err| {
                    return forgetStaleChat(cache, &found, err);
                };
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
    cache: *Cache,
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
    const found: FoundChat = switch (send.chat) {
        .id => |id| .{ .given = id },
        .name => |name| try findChat(client, cache, arena, name, clock, stdout, started_at),
    };

    var html: Io.Writer.Allocating = .init(arena);
    // An Allocating writer fails only when it can't grow.
    chat.teams_html.writeMarkdown(&html.writer, send.text) catch return error.OutOfMemory;
    // The text holds more than whitespace (see `Command.parse`), so some HTML comes out.
    std.debug.assert(html.written().len > 0);
    if (html.written().len > chat.Client.content_size_max) return error.SendTextTooLong;

    const user = try selfUser(client, cache);
    // Never retried: a cached id that answers 404 is forgotten, and the command fails. A 404
    // means nothing was posted.
    const message_id = client.send(found.id(), &.{
        .content = html.written(),
        .display_name = user.name,
    }) catch |err| return forgetStaleChat(cache, &found, err);
    started_at.store(requests_idle, .release);

    var time_buffer: [short_time.width_max]u8 = undefined;
    // `send` takes only ids from 1970-01-02 to `message_id_max`, which `shortTimeAt` can show
    // (asserted at comptime above).
    const at_seconds: i64 = @intCast(@divFloor(message_id, std.time.ms_per_s));
    try stdout.print("Sent {s}.\n", .{clock.shortTimeAt(&time_buffer, at_seconds)});
}

/// Your user: the cached one, or asked of the service once and then cached. Borrowed from the
/// cache.
fn selfUser(client: *chat.Client, cache: *Cache) RunError!Cache.User {
    if (cache.self_user) |user| return user;
    const user = try client.whoami();
    defer user.deinit();
    try cache.putSelf(&.{ .mri = user.mri, .name = user.name, .upn = user.upn });
    return cache.self_user.?;
}

/// Lists your `conversation_count` newest chats, one `printChat` row each.
fn runChats(
    client: *chat.Client,
    cache: *Cache,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
    conversation_count: u16,
) RunError!void {
    const user = try selfUser(client, cache);

    const list = try client.conversations(conversation_count);
    defer list.deinit();

    // Holds the 1:1 chat names; freed with the command.
    var names_arena: std.heap.ArenaAllocator = .init(client.gpa);
    defer names_arena.deinit();

    const arena = names_arena.allocator();
    const names = try otherPersonNames(client, cache, arena, list.items, user.mri);
    started_at.store(requests_idle, .release);

    for (list.items, names) |*conversation, name| {
        const unread = conversation.isUnread(user.mri);
        try printChat(stdout, clock, conversation, name, unread);
    }
}

/// A token and region for one connection: from the environment (test mode) or, normally, from
/// the login keychain where `teams-zig login` stored them. The token is a copy, zeroed by
/// `deinit`.
pub const Credentials = struct {
    gpa: std.mem.Allocator,
    token: []u8,
    region: chat.Client.Region,

    pub fn deinit(credentials: *Credentials) void {
        // Zeroed so our copy doesn't outlive its use.
        std.crypto.secureZero(u8, credentials.token);
        credentials.gpa.free(credentials.token);
        credentials.* = undefined;
    }
};

/// Reads the token and region, from the environment in test mode, else from the keychain.
pub fn readCredentials(
    gpa: std.mem.Allocator,
    io: Io,
    environment: *const std.process.Environ.Map,
) ConnectError!Credentials {
    // Test mode: less secure, since any child process can read the environment, but it never
    // touches the keychain. An empty token counts as unset.
    if (environment.get(token_variable)) |environment_token| {
        if (environment_token.len > 0) {
            const region_name = environment.get(region_variable) orelse {
                return error.UnknownRegion;
            };
            try checkToken(environment_token);
            const region = try parseRegion(region_name);
            return .{ .gpa = gpa, .token = try gpa.dupe(u8, environment_token), .region = region };
        }
    }

    const token = try keychain.read(gpa, io, &.{
        .service_name = keychain.service,
        .account = "skype-token",
    });
    errdefer {
        std.crypto.secureZero(u8, token);
        gpa.free(token);
    }

    // An empty item means no real token was ever stored.
    if (token.len == 0) return error.ItemNotFound;

    const region_name = keychain.read(gpa, io, &.{
        .service_name = keychain.service,
        .account = "region",
    }) catch |err| switch (err) {
        // The token is there but the region isn't: say so, not "no token".
        error.ItemNotFound => return error.UnknownRegion,
        else => |other| return other,
    };
    defer gpa.free(region_name);

    try checkToken(token);
    return .{ .gpa = gpa, .token = token, .region = try parseRegion(region_name) };
}

/// Starts a Chat Service client with the token and region `readCredentials` finds.
pub fn connect(
    client: *chat.Client,
    gpa: std.mem.Allocator,
    io: Io,
    environment: *const std.process.Environ.Map,
) ConnectError!void {
    var credentials = try readCredentials(gpa, io, environment);
    // std's connection buffers still hold a copy of the token until the process exits.
    defer credentials.deinit();

    try client.init(gpa, io, credentials.region, credentials.token);
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
    cache: *Cache,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
) RunError!void {
    const user = try selfUser(client, cache);

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

/// A chat picked for `messages` or `send`, by where its id came from.
const FoundChat = union(enum) {
    /// The id as typed.
    given: []const u8,
    /// By name, from a listing of your newest chats, which just cached the name.
    listed: NamedChat,
    /// By name, from the cache's name map.
    cached: NamedChat,

    /// A chat's id and the name that picked it, to forget if the chat answers 404. Both are
    /// owned by `findChat`'s arena.
    const NamedChat = struct { id: []const u8, name: []const u8 };

    fn id(found: *const FoundChat) []const u8 {
        return switch (found.*) {
            .given => |given| given,
            .listed, .cached => |named| named.id,
        };
    }
};

/// The chat `name` picks: from the cache's name map, or else the one chat among your newest
/// `conversation_count_limit` named `name`. Its id and name are owned by `arena`. In the
/// listing, known names are tried first; the per-chat lookups run only if none of them match.
/// The listing's names that pick one chat are cached. Several matches are listed on `stdout`,
/// with their ids, before ChatNameAmbiguous.
fn findChat(
    client: *chat.Client,
    cache: *Cache,
    arena: std.mem.Allocator,
    name: []const u8,
    clock: *const Clock,
    stdout: *Io.Writer,
    started_at: *std.atomic.Value(i64),
) RunError!FoundChat {
    std.debug.assert(name.len > 0);
    if (cache.chatId(name)) |id| {
        return .{ .cached = .{ .id = try arena.dupe(u8, id), .name = try arena.dupe(u8, name) } };
    }
    const user = try selfUser(client, cache);

    const list = try client.conversations(conversation_count_limit);
    defer list.deinit();

    // conversations() returns at most the count it was asked for.
    std.debug.assert(list.items.len <= conversation_count_limit);
    var known_names_buffer: [conversation_count_limit]?[]const u8 = undefined;
    var names: []?[]const u8 = known_names_buffer[0..list.items.len];
    for (list.items, names) |*conversation, *other_name| {
        other_name.* = switch (nameSource(conversation, user.mri)) {
            .known => |known| known,
            .lookup => cache.personName(conversation.id),
            .none => null,
        };
    }
    var match = matchChat(list.items, names, name);
    if (match == .none) {
        names = try otherPersonNames(client, cache, arena, list.items, user.mri);
        match = matchChat(list.items, names, name);
    }
    try findChatCacheNames(cache, list.items, names);

    switch (match) {
        .none => return error.ChatNameNotFound,
        .one => |index| return .{
            .listed = .{
                .id = try arena.dupe(u8, list.items[index].id),
                .name = try arena.dupe(u8, name),
            },
        },
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

/// Rewrites the cache's name map from a full listing: each name in `conversations` (as `chats`
/// shows it) that picks exactly one of them, so a name that is ambiguous now, or gone, is
/// forgotten. `other_names` holds the other person's name for each, or null.
fn findChatCacheNames(
    cache: *Cache,
    conversations: []const chat.Conversation,
    other_names: []const ?[]const u8,
) error{OutOfMemory}!void {
    std.debug.assert(conversations.len == other_names.len);
    std.debug.assert(conversations.len <= conversation_count_limit);
    cache.clearChats();
    for (conversations, other_names) |*conversation, other_name| {
        const name = chatName(conversation, other_name) orelse continue;
        if (matchChat(conversations, other_names, name) != .one) continue;
        try cache.putChat(name, conversation.id);
    }
}

/// Passes on `err` from a request to `found`'s chat, first forgetting the name that picked it
/// (from the cache or a listing, which cached it) if that chat answers 404. Nothing is retried;
/// a rerun looks the name up.
fn forgetStaleChat(cache: *Cache, found: *const FoundChat, err: RunError) RunError {
    if (err != error.NotFound) return err;
    switch (found.*) {
        .given => {},
        // A listing caches the name too, so one that went stale since is forgotten as well.
        .listed, .cached => |named| cache.removeChat(named.name),
    }
    return err;
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
/// there's none to show. A cached name saves a lookup; past the cache, at most
/// `name_lookup_count_limit` chats get a lookup, one request each. Every name found is cached.
fn otherPersonNames(
    client: *chat.Client,
    cache: *Cache,
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
                if (cache.personName(conversation.id)) |cached| {
                    break :lookup try arena.dupe(u8, cached);
                }
                if (name_lookup_count_left == 0) break :lookup null;
                name_lookup_count_left -= 1;
                break :lookup try lookUpOtherName(client, arena, conversation.id, self_mri);
            },
        };
        if (name.*) |found| try cache.putPerson(conversation.id, found);
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

/// A count from the command line: a whole number, or null. `Command.init…` check its range.
fn parseCount(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
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

/// Prints `err`'s hint as one `teams-zig:` line on `stderr`, and returns the exit code.
pub fn reportError(
    stderr: *Io.Writer,
    err: CommandError,
    response_status: ?std.http.Status,
) Io.Writer.Error!u8 {
    try stderr.writeAll("teams-zig: ");
    try writeErrorHint(stderr, err, response_status);
    try stderr.writeByte('\n');
    try stderr.flush();
    return 1;
}

/// Writes a one-line hint, with no line break, for every way a command can fail. The switch is
/// exhaustive, so a new error in the client or keychain doesn't compile until it has a hint.
/// `response_status` is the response's, set whenever the error is UnexpectedStatus.
pub fn writeErrorHint(
    writer: *Io.Writer,
    err: CommandError,
    response_status: ?std.http.Status,
) Io.Writer.Error!void {
    const rerun_login = "run teams-zig login";
    const hint = switch (err) {
        error.ItemNotFound => "no token in the login keychain; " ++ rerun_login,
        error.InvalidToken => "the token contains a line break; " ++ rerun_login,
        error.UnknownRegion => "the region is missing or unknown; " ++ rerun_login ++
            " (in test mode, set " ++ region_variable ++ ")",
        error.KeychainReadFailed => "couldn't read the teams-zig items with " ++
            keychain.security_path ++
            "; is the keychain locked?",
        error.OutOfMemory => "out of memory",
        error.TokenExpired => "the skype token has expired; " ++ rerun_login,
        error.NotFound => "no conversation with that id, or it isn't yours; if you named the " ++
            "chat, run the command again",
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
            return writer.print(
                "the Chat Service answered HTTP {d}",
                .{@backingInt(response_status.?)},
            );
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
    try writer.writeAll(hint);
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
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();

    const long_text: [send_text_size_max + 1]u8 = @splat('a');
    const too_long: Command.Send = .{ .chat = .{ .id = "48:notes" }, .text = &long_text };
    const too_long_result = runSend(&client, &cache, &clock, &out.writer, &started_at, &too_long);
    try std.testing.expectError(error.SendTextTooLong, too_long_result);

    // Under the text cap, but `"` becomes `&quot;`, so the HTML is far over its own.
    const quotes: [send_text_size_max]u8 = @splat('"');
    const quoted: Command.Send = .{ .chat = .{ .id = "48:notes" }, .text = &quotes };
    const quoted_result = runSend(&client, &cache, &clock, &out.writer, &started_at, &quoted);
    try std.testing.expectError(error.SendTextTooLong, quoted_result);
    try std.testing.expectEqual(null, client.response_status);
    try std.testing.expectEqualStrings("", out.written());
}

test "writeErrorHint writes one hint per error, with the status for an unexpected one" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeErrorHint(&out.writer, error.TokenExpired, .unauthorized);
    try out.writer.writeByte('\n');
    try writeErrorHint(&out.writer, error.UnexpectedStatus, .service_unavailable);
    try out.writer.writeByte('\n');
    try writeErrorHint(&out.writer, error.ChatNameAmbiguous, null);
    try std.testing.expectEqualStrings(
        \\the skype token has expired; run teams-zig login
        \\the Chat Service answered HTTP 503
        \\several chats have that name; use one of the ids above
    , out.written());
}

test "reportError writes the hint as one teams-zig line and exits 1" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectEqual(1, try reportError(&out.writer, error.ConnectFailed, null));
    const forbidden = try reportError(&out.writer, error.UnexpectedStatus, .forbidden);
    try std.testing.expectEqual(1, forbidden);
    try std.testing.expectEqualStrings(
        \\teams-zig: couldn't reach the Chat Service; check the network
        \\teams-zig: the Chat Service answered HTTP 403
        \\
    , out.written());
}

test "Command.init… apply the CLI's limits to typed arguments" {
    try std.testing.expectEqual(conversation_count_default, Command.initChats(null).?.chats);
    try std.testing.expectEqual(1, Command.initChats(1).?.chats);
    try std.testing.expectEqual(100, Command.initChats(100).?.chats);
    try std.testing.expectEqual(null, Command.initChats(0));
    try std.testing.expectEqual(null, Command.initChats(101));

    const messages = Command.initMessages("Fake Person", null).?.messages;
    try std.testing.expectEqualStrings("Fake Person", messages.chat.name);
    try std.testing.expectEqual(message_count_default, messages.count);
    try std.testing.expectEqual(12800, Command.initMessages("19:fake", 12800).?.messages.count);
    try std.testing.expectEqual(null, Command.initMessages("19:fake", 0));
    try std.testing.expectEqual(null, Command.initMessages("19:fake", 12801));
    try std.testing.expectEqual(null, Command.initMessages("", null));

    const send = Command.initSend("48:notes", "fake").?.send;
    try std.testing.expectEqualStrings("48:notes", send.chat.id);
    try std.testing.expectEqualStrings("fake", send.text);
    try std.testing.expectEqual(null, Command.initSend("", "fake"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", " \n"));
    // Tab and newline stay; every other C0 control and DEL is refused, from argv or JSON.
    // Printable ASCII and UTF-8 pass.
    try std.testing.expect(Command.initSend("48:notes", "fake\tone\nfake two") != null);
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\x00"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\r\n"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\x1b[31m"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\x7f"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\x1f"));
    try std.testing.expect(Command.initSend("48:notes", "fake ~ é") != null);
    // UTF-8 C1 controls (U+0080 to U+009F) are refused too, as `messages` shows them escaped;
    // U+00A0, the first character after them, passes.
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\xc2\x9b31m"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\xc2\x80"));
    try std.testing.expectEqual(null, Command.initSend("48:notes", "fake\xc2\x9f"));
    try std.testing.expect(Command.initSend("48:notes", "fake\xc2\xa0") != null);
}

test "selfUser takes your user from the cache without a request" {
    var client: chat.Client = undefined;
    // A fake token: a request would fail with another error, and `response_status` would be set.
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putSelf(&.{ .mri = "8:orgid:fake-self", .name = "Fake Self", .upn = "fake@x" });

    const user = try selfUser(&client, &cache);
    try std.testing.expectEqualStrings("8:orgid:fake-self", user.mri);
    try std.testing.expectEqualStrings("Fake Self", user.name);
    try std.testing.expectEqual(null, client.response_status);
}

test "otherPersonNames takes cached names, with no lookup, and caches the names it knows" {
    var client: chat.Client = undefined;
    // A fake token: a lookup would fail and set `response_status`.
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const self_mri = "8:orgid:fake-self";
    const template: chat.Conversation = .{
        .id = "19:fake-self_fake-a@unq.gbl.spaces",
        .kind = .chat,
        .topic = null,
        .last_message_at = null,
        .last_sender = self_mri,
        .last_sender_name = "Fake Self",
        .last_message_id = null,
        .read_up_to_id = null,
    };
    var conversations: [2]chat.Conversation = @splat(template);
    // You wrote last here, so its name needs a lookup, unless it is cached.
    try cache.putPerson(conversations[0].id, "Fake A");
    // The other person wrote last here, so the name is known, and gets cached.
    conversations[1].id = "19:fake-self_fake-b@unq.gbl.spaces";
    conversations[1].last_sender = "8:orgid:fake-b";
    conversations[1].last_sender_name = "Fake B";

    const arena = arena_state.allocator();
    const names = try otherPersonNames(&client, &cache, arena, &conversations, self_mri);
    try std.testing.expectEqualStrings("Fake A", names[0].?);
    try std.testing.expectEqualStrings("Fake B", names[1].?);
    try std.testing.expectEqual(null, client.response_status);
    try std.testing.expectEqualStrings("Fake B", cache.personName(conversations[1].id).?);
}

test "findChat takes a cached name's id without a request" {
    var client: chat.Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putChat("Fake Standup", "19:fake-group@thread.v2");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const zone = try core_foundation.TimeZone.createFixed(0);
    defer core_foundation.release(zone);
    const clock: Clock = .{ .zone = zone, .now_seconds = 1_793_966_400 };
    var started_at: std.atomic.Value(i64) = .init(requests_idle);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const arena = arena_state.allocator();
    const name = "fake STANDUP";
    const found = try findChat(&client, &cache, arena, name, &clock, &out.writer, &started_at);
    try std.testing.expectEqualStrings("19:fake-group@thread.v2", found.cached.id);
    try std.testing.expectEqualStrings(name, found.cached.name);
    try std.testing.expectEqual(null, client.response_status);
}

test "findChatCacheNames rewrites the map with only names that pick one chat" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    // Cached earlier, when it picked one chat; the listing below shows two.
    try cache.putChat("Fake Standup", "19:fake-old@thread.v2");
    try cache.putChat("Fake Gone", "19:fake-gone@thread.v2");
    const template: chat.Conversation = .{
        .id = "19:fake-a@thread.v2",
        .kind = .chat,
        .topic = "Fake Standup",
        .last_message_at = null,
        .last_sender = null,
        .last_sender_name = null,
        .last_message_id = null,
        .read_up_to_id = null,
    };
    var conversations: [3]chat.Conversation = @splat(template);
    conversations[1].id = "19:fake-b@thread.v2";
    conversations[1].topic = "fake standup";
    conversations[2].id = "19:fake-c@thread.v2";
    conversations[2].topic = "Fake Retro";
    const other_names = [_]?[]const u8{ null, null, null };

    try findChatCacheNames(&cache, &conversations, &other_names);
    try std.testing.expectEqual(null, cache.chatId("fake standup"));
    try std.testing.expectEqual(null, cache.chatId("fake gone"));
    try std.testing.expectEqualStrings("19:fake-c@thread.v2", cache.chatId("fake retro").?);
}

test "forgetStaleChat drops a cached name whose chat answers 404, and nothing else" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putChat("Fake Standup", "19:fake-group@thread.v2");
    const given: FoundChat = .{ .given = "19:fake-group@thread.v2" };
    const kept = forgetStaleChat(&cache, &given, error.NotFound);
    try std.testing.expectEqual(error.NotFound, kept);
    try std.testing.expect(cache.chatId("fake standup") != null);

    const cached: FoundChat = .{
        .cached = .{ .id = "19:fake-group@thread.v2", .name = "Fake STANDUP" },
    };
    const failed = forgetStaleChat(&cache, &cached, error.ConnectFailed);
    try std.testing.expectEqual(error.ConnectFailed, failed);
    try std.testing.expect(cache.chatId("fake standup") != null);
    const forgotten = forgetStaleChat(&cache, &cached, error.NotFound);
    try std.testing.expectEqual(error.NotFound, forgotten);
    try std.testing.expectEqual(null, cache.chatId("fake standup"));

    try cache.putChat("Fake Retro", "19:fake-retro@thread.v2");
    const listed: FoundChat = .{
        .listed = .{ .id = "19:fake-retro@thread.v2", .name = "fake retro" },
    };
    try std.testing.expectEqual(error.NotFound, forgetStaleChat(&cache, &listed, error.NotFound));
    try std.testing.expectEqual(null, cache.chatId("fake retro"));
}

test "readCredentials takes test mode's token and region as its own copy, and refuses bad ones" {
    // A good token and region; then an unknown region, no region, and a token with a line break.
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();

    try environment.put(token_variable, "fake-token");
    try environment.put(region_variable, "amer");

    var credentials = try readCredentials(std.testing.allocator, std.testing.io, &environment);
    defer credentials.deinit();

    try std.testing.expectEqualStrings("fake-token", credentials.token);
    try std.testing.expectEqual(chat.Client.Region.amer, credentials.region);

    try environment.put(region_variable, "fake");
    const unknown = readCredentials(std.testing.allocator, std.testing.io, &environment);
    try std.testing.expectError(error.UnknownRegion, unknown);

    _ = environment.orderedRemove(region_variable);
    const missing = readCredentials(std.testing.allocator, std.testing.io, &environment);
    try std.testing.expectError(error.UnknownRegion, missing);

    try environment.put(region_variable, "amer");
    try environment.put(token_variable, "fake\r\nX-Injected: 1");
    const broken = readCredentials(std.testing.allocator, std.testing.io, &environment);
    try std.testing.expectError(error.InvalidToken, broken);
}
