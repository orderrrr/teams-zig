const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const writeVisible = chat.text.writeVisible;

pub fn main(init: std.process.Init) !u8 {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const command = Command.parse(arguments) orelse {
        try stderr.writeAll(usage);
        try stderr.flush();
        return 2;
    };

    var client: chat.Client = undefined;
    // No request has been made yet, so there is no response status to report.
    connect(&client, init.gpa, init.io, init.environ_map) catch |err| {
        return reportError(stderr, err, null);
    };
    defer client.deinit();

    // Started after connect so a keychain unlock dialog (security shows one when the keychain is
    // locked) can take as long as it needs. Without a watchdog a stalled request would hang
    // forever; if the thread can't start, the command still runs, just unbounded.
    const spawn_config: std.Thread.SpawnConfig = .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .allocator = null,
    };
    const watchdog_arguments = .{ init.io, &chat_service_answered };
    if (std.Thread.spawn(spawn_config, watchdog, watchdog_arguments)) |watchdog_thread| {
        watchdog_thread.detach();
    } else |_| {}

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    command.run(&client, stdout, &chat_service_answered) catch |err| {
        const exit_code = try reportError(stderr, err, client.response_status);
        // The run error is the one worth reporting; a failed flush (say, a closed pipe) after it
        // would only hide that.
        stdout.flush() catch {};
        return exit_code;
    };
    stdout.flush() catch |err| return reportError(stderr, err, null);
    return 0;
}

const usage =
    \\usage: teams-zig <command>
    \\
    \\commands:
    \\  whoami                       show the signed-in user
    \\  chats [count]                list your chats (default 50, at most 100)
    \\  messages <id> [count]        show a conversation's messages (default 50)
    \\
    \\Sign in first with scripts/teams-token.fish, which stores the token in the login keychain.
    \\
    \\Test mode (less secure: the token is in the environment, readable by child processes):
    \\set TEAMS_ZIG_SKYPE_TOKEN and TEAMS_ZIG_REGION to skip the keychain, for example in fish:
    \\  set -lx TEAMS_ZIG_SKYPE_TOKEN (security find-generic-password -s teams-zig \
    \\      -a skype-token -w)
    \\  set -lx TEAMS_ZIG_REGION (security find-generic-password -s teams-zig -a region -w)
    \\
;

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
const conversation_count_max = 100;

/// At most this many 1:1 chats get a recent-messages lookup per run; at about a second each on a
/// slow link, they stay inside the watchdog's 60 seconds. Chats past it show "(no topic)".
const name_lookup_count_max = 40;

comptime {
    std.debug.assert(conversation_count_max <= std.math.maxInt(u16));
    std.debug.assert(name_lookup_count_max < command_seconds_max);
    std.debug.assert(conversation_count_default <= conversation_count_max);
    std.debug.assert(message_count_default <= message_count_max);
}

const message_count_max = chat.Client.message_count_limit;

/// How far back `chats` looks for the other person's name in a 1:1 chat where you spoke last.
const message_count_recent = 20;

/// Set once the Chat Service has answered. Static, so the detached watchdog can't outlive it.
var chat_service_answered: std.atomic.Value(bool) = .init(false);

/// Every command normally finishes in a few seconds; past this, the network has stalled.
const command_seconds_max = 60;

/// Pads the `chats` timestamp column to the width of the service's ISO timestamps.
const timestamp_width = "2026-11-01T10:00:00.000Z".len;

/// Failures reading the keychain or starting the client.
const ConnectError = KeychainReadError || error{ UnknownRegion, InvalidToken };

/// Failures reading a keychain item through `security`.
const KeychainReadError = error{ ItemNotFound, KeychainReadFailed, OutOfMemory };

/// Failures running a command: the Chat Service's, or writing the output.
const RunError = chat.Client.Error || Io.Writer.Error;

/// Every way a command can fail.
const CommandError = ConnectError || RunError;

const Command = union(enum) {
    whoami,
    /// How many conversations to list.
    chats: u16,
    messages: Messages,

    const Messages = struct {
        /// Borrows the argument slice, which lives as long as `main`.
        conversation_id: []const u8,
        count: u32,
    };

    fn parse(arguments: []const []const u8) ?Command {
        if (arguments.len < 2) return null;
        const name = arguments[1];
        const rest = arguments[2..];

        if (std.mem.eql(u8, name, "whoami")) {
            if (rest.len != 0) return null;
            return .whoami;
        }
        if (std.mem.eql(u8, name, "chats")) {
            if (rest.len > 1) return null;
            if (rest.len == 0) return .{ .chats = conversation_count_default };
            const count = parseCount(rest[0], conversation_count_max) orelse return null;
            return .{ .chats = @intCast(count) };
        }
        if (std.mem.eql(u8, name, "messages")) {
            if (rest.len == 0) return null;
            if (rest.len > 2) return null;
            if (rest[0].len == 0) return null;
            const count = if (rest.len == 2)
                parseCount(rest[1], message_count_max) orelse return null
            else
                message_count_default;
            return .{ .messages = .{ .conversation_id = rest[0], .count = count } };
        }
        return null;
    }

    /// Sets `requests_done` once the Chat Service has answered, before any output is written.
    fn run(
        command: *const Command,
        client: *chat.Client,
        stdout: *Io.Writer,
        requests_done: *std.atomic.Value(bool),
    ) RunError!void {
        switch (command.*) {
            .whoami => {
                const user = try client.whoami();
                defer user.deinit();

                requests_done.store(true, .release);

                try writeVisible(stdout, user.name);
                try stdout.writeAll(" <");
                try writeVisible(stdout, user.upn);
                try stdout.writeAll(">\n");
            },
            .chats => |conversation_count| {
                const user = try client.whoami();
                defer user.deinit();

                const list = try client.conversations(conversation_count);
                defer list.deinit();

                // Holds the 1:1 chat names; freed with the command.
                var names_arena: std.heap.ArenaAllocator = .init(client.gpa);
                defer names_arena.deinit();

                const arena = names_arena.allocator();
                const names = try otherPersonNames(client, arena, list.items, user.mri);
                requests_done.store(true, .release);

                for (list.items, names) |conversation, name| {
                    const last_message_at = conversation.last_message_at orelse "-";
                    try writeVisible(stdout, last_message_at);
                    try stdout.splatByteAll(' ', timestamp_width -| last_message_at.len);
                    try stdout.print("  {t:<7}  ", .{conversation.kind});
                    try writeVisible(stdout, conversation.topic orelse name orelse "(no topic)");
                    try stdout.writeAll("  ");
                    try writeVisible(stdout, conversation.id);
                    try stdout.writeByte('\n');
                }
            },
            .messages => |messages| {
                const list = try client.messages(messages.conversation_id, messages.count);
                defer list.deinit();

                requests_done.store(true, .release);

                // The service returns newest first; print oldest first, like a chat window.
                var index = list.items.len;
                while (index > 0) {
                    index -= 1;
                    try printMessage(stdout, &list.items[index]);
                }
            },
        }
    }
};

/// Ends the process if the Chat Service hasn't answered within `command_seconds_max`. std 0.17
/// has no read timeout and ignores its connect timeout, so a held connection (say, one a
/// per-app firewall is waiting to approve) would hang indefinitely. Output time isn't counted: a
/// slow pager reading the output is fine.
fn watchdog(io: Io, requests_done: *const std.atomic.Value(bool)) void {
    io.sleep(.fromSeconds(command_seconds_max), .awake) catch |err| switch (err) {
        // Only cancellation ends the sleep early, and nothing cancels this detached thread; if
        // something ever does, the watchdog's job is over.
        error.Canceled => return,
    };
    if (requests_done.load(.acquire)) return;

    std.debug.print(
        "teams-zig: no answer from the Chat Service in {d} seconds; check the network\n",
        .{command_seconds_max},
    );
    // _exit, not exit: exit handlers mustn't run on this thread while main is still working.
    std.c._exit(1);
}

/// Starts a Chat Service client with the token and region from the environment (test mode) or,
/// normally, from the login keychain where the token script stored them.
fn connect(
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

/// The other person's name for each 1:1 chat in `conversations`, owned by `arena`; null where
/// there's none to show. At most `name_lookup_count_max` chats get a lookup, one request each.
fn otherPersonNames(
    client: *chat.Client,
    arena: std.mem.Allocator,
    conversations: []const chat.Conversation,
    self_mri: []const u8,
) chat.Client.Error![]?[]const u8 {
    const names = try arena.alloc(?[]const u8, conversations.len);
    var name_lookup_count_left: u32 = name_lookup_count_max;
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
        switch (err) {
            // One chat that can't be read shouldn't hide the rest of the list.
            error.NotFound, error.UnexpectedJson => return null,
            error.UnexpectedStatus => {
                // Throttling and server errors would hit every chat, so they stop the command.
                const status = client.response_status.?;
                if (status == .too_many_requests) return err;
                if (status.class() == .server_error) return err;
                return null;
            },
            else => return err,
        }
    };
    defer recent.deinit();

    const name = otherWriterName(recent.items, self_mri) orelse return null;
    return try arena.dupe(u8, name);
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

fn printMessage(stdout: *Io.Writer, message: *const chat.Message) Io.Writer.Error!void {
    const sender = message.sender_name orelse message.sender orelse "(unknown sender)";
    try writeVisible(stdout, message.arrived_at);
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
fn reportError(
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
        error.SendFailed => "couldn't send the request to the Chat Service; try again",
        error.ConnectionDropped => "the connection dropped mid-response; try again",
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

test "Command.parse accepts the three commands and rejects anything else" {
    try std.testing.expectEqual(Command.whoami, Command.parse(&.{ "teams-zig", "whoami" }).?);

    const chats = Command.parse(&.{ "teams-zig", "chats" }).?;
    try std.testing.expectEqual(conversation_count_default, chats.chats);
    const chats_ten = Command.parse(&.{ "teams-zig", "chats", "10" }).?;
    try std.testing.expectEqual(10, chats_ten.chats);
    const chats_max = Command.parse(&.{ "teams-zig", "chats", "100" }).?;
    try std.testing.expectEqual(conversation_count_max, chats_max.chats);

    const messages = Command.parse(&.{ "teams-zig", "messages", "19:fake" }).?;
    try std.testing.expectEqualStrings("19:fake", messages.messages.conversation_id);
    try std.testing.expectEqual(message_count_default, messages.messages.count);
    const messages_five = Command.parse(&.{ "teams-zig", "messages", "19:fake", "5" }).?;
    try std.testing.expectEqual(5, messages_five.messages.count);
    const messages_one = Command.parse(&.{ "teams-zig", "messages", "19:fake", "1" }).?;
    try std.testing.expectEqual(1, messages_one.messages.count);
    const messages_max = Command.parse(&.{ "teams-zig", "messages", "19:fake", "12800" }).?;
    try std.testing.expectEqual(message_count_max, messages_max.messages.count);
    const too_many = Command.parse(&.{ "teams-zig", "messages", "19:x", "12801" });
    try std.testing.expectEqual(null, too_many);

    try std.testing.expectEqual(null, Command.parse(&.{"teams-zig"}));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "whoami", "x" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "chats", "0" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "chats", "101" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "chats", "ten" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages", "" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages", "19:x", "-1" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send" }));
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
