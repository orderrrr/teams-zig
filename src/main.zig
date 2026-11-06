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

    // Started after connect so a keychain prompt can take as long as it needs. Without a watchdog
    // a stalled request would hang forever; if the thread can't start, the command still runs,
    // just unbounded.
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
    \\  whoami                     show the signed-in user
    \\  chats                      list your chats
    \\  messages <conversation-id> show a conversation's messages
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

/// Apple's keychain tool, which reads the items without a prompt (see `readKeychain`).
const security_path = "/usr/bin/security";

/// Far larger than any token; a bigger value means something else is stored there.
const keychain_value_size_max = 64 * 1024;

/// Test mode: set these to skip the keychain. See `usage`.
const token_variable = "TEAMS_ZIG_SKYPE_TOKEN";
const region_variable = "TEAMS_ZIG_REGION";

const conversation_count_max = 50;
const message_count_max = 50;

/// Set once the Chat Service has answered. Static, so the detached watchdog can't outlive it.
var chat_service_answered: std.atomic.Value(bool) = .init(false);

/// Every command normally finishes in a few seconds; past this, the network has stalled.
const command_seconds_max = 60;

/// Pads the `chats` timestamp column to the width of the service's ISO timestamps.
const timestamp_width = "2026-11-01T10:00:00.000Z".len;

/// Failures reading the keychain or starting the client.
const ConnectError = error{
    ItemNotFound,
    KeychainReadFailed,
    OutOfMemory,
    UnknownRegion,
    InvalidToken,
};

/// Failures running a command: the Chat Service's, or writing the output.
const RunError = chat.Client.Error || Io.Writer.Error;

/// Every way a command can fail.
const CommandError = ConnectError || RunError;

const Command = union(enum) {
    whoami,
    chats,
    /// The conversation id. Borrows the argument slice, which lives as long as `main`.
    messages: []const u8,

    fn parse(arguments: []const []const u8) ?Command {
        switch (arguments.len) {
            2 => {
                if (std.mem.eql(u8, arguments[1], "whoami")) return .whoami;
                if (std.mem.eql(u8, arguments[1], "chats")) return .chats;
                return null;
            },
            3 => {
                if (!std.mem.eql(u8, arguments[1], "messages")) return null;
                if (arguments[2].len == 0) return null;
                return .{ .messages = arguments[2] };
            },
            else => return null,
        }
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
            .chats => {
                const list = try client.conversations(conversation_count_max);
                defer list.deinit();

                requests_done.store(true, .release);

                for (list.items) |conversation| {
                    const last_message_at = conversation.last_message_at orelse "-";
                    try writeVisible(stdout, last_message_at);
                    try stdout.splatByteAll(' ', timestamp_width -| last_message_at.len);
                    try stdout.print("  {t:<7}  ", .{conversation.kind});
                    try writeVisible(stdout, conversation.topic orelse "(no topic)");
                    try stdout.writeAll("  ");
                    try writeVisible(stdout, conversation.id);
                    try stdout.writeByte('\n');
                }
            },
            .messages => |conversation_id| {
                const list = try client.messages(conversation_id, message_count_max);
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
/// writes with. Items made by `security` trust it, so no build of teams-zig is ever prompted, as
/// it would be reading through Security.framework itself. Owned by the caller.
fn readKeychain(
    gpa: std.mem.Allocator,
    io: Io,
    account: []const u8,
) error{ ItemNotFound, KeychainReadFailed, OutOfMemory }![]u8 {
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
            // security's exit status for errSecItemNotFound.
            44 => return error.ItemNotFound,
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
        error.KeychainReadFailed => "couldn't read the teams-zig items with " ++ security_path,
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
    try std.testing.expectEqual(Command.chats, Command.parse(&.{ "teams-zig", "chats" }).?);

    const messages = Command.parse(&.{ "teams-zig", "messages", "19:fake" }).?;
    try std.testing.expectEqualStrings("19:fake", messages.messages);

    try std.testing.expectEqual(null, Command.parse(&.{"teams-zig"}));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "messages", "" }));
    try std.testing.expectEqual(null, Command.parse(&.{ "teams-zig", "send" }));
}

test "checkToken rejects line breaks" {
    try checkToken("fake-token");
    try std.testing.expectError(error.InvalidToken, checkToken("fake\r\nX-Injected: 1"));
    try std.testing.expectError(error.InvalidToken, checkToken("fake\n"));
}
