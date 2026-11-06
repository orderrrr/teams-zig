const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const KeychainItem = teams.macos.KeychainItem;

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
    connect(&client, init.gpa, init.io) catch |err| return reportError(stderr, err, null);
    defer client.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    command.run(&client, stdout) catch |err| {
        try stdout.flush();
        return reportError(stderr, err, client.response_status);
    };
    try stdout.flush();
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
;

/// Shared with scripts/teams-token.fish, which writes these items.
const keychain_service = "teams-zig";

const chat_count_max = 50;
const message_count_max = 50;

comptime {
    std.debug.assert(chat_count_max > 0);
    std.debug.assert(message_count_max > 0);
}

const Command = union(enum) {
    whoami,
    chats,
    messages: []const u8,

    fn parse(arguments: []const []const u8) ?Command {
        std.debug.assert(arguments.len >= 1);
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

    fn run(command: *const Command, client: *chat.Client, stdout: *Io.Writer) !void {
        switch (command.*) {
            .whoami => {
                const user = try client.whoami();
                defer user.deinit();

                try stdout.print("{s} <{s}>\n", .{ user.name, user.upn });
            },
            .chats => {
                const list = try client.chats(chat_count_max);
                defer list.deinit();

                for (list.items) |conversation| {
                    try stdout.print("{s:<24}  {t:<7}  {s}  {s}\n", .{
                        conversation.last_message_at orelse "-",
                        conversation.kind,
                        conversation.topic orelse "(no topic)",
                        conversation.id,
                    });
                }
            },
            .messages => |conversation_id| {
                const list = try client.messages(conversation_id, message_count_max);
                defer list.deinit();

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

/// Reads the token and region the token script stored, and starts a Chat Service client.
fn connect(client: *chat.Client, gpa: std.mem.Allocator, io: Io) !void {
    const token_item: KeychainItem = .{ .service = keychain_service, .account = "skype-token" };
    const token = try token_item.read(gpa);
    defer gpa.free(token);

    // An empty item means the script never stored a real token.
    if (token.len == 0) return error.ItemNotFound;

    const region_item: KeychainItem = .{ .service = keychain_service, .account = "region" };
    const region_name = try region_item.read(gpa);
    defer gpa.free(region_name);

    const Region = chat.Client.Region;
    const region = std.meta.stringToEnum(Region, region_name) orelse return error.UnknownRegion;
    std.debug.assert(token.len > 0);
    try client.init(gpa, io, region, token);
}

fn printMessage(stdout: *Io.Writer, message: *const chat.Message) Io.Writer.Error!void {
    const sender = message.sender_name orelse message.sender orelse "(unknown sender)";
    try stdout.print("{s}  {s}: ", .{ message.arrived_at, sender });

    if (message.deleted_at_ms != null) {
        try stdout.writeAll("(deleted)");
    } else if (message.isText()) {
        try message.writeText(stdout);
    } else {
        try stdout.print("[{s}]", .{message.message_type});
    }
    try stdout.writeByte('\n');
}

/// Prints a one-line hint for errors you can act on. Anything else is a bug and propagates.
fn reportError(stderr: *Io.Writer, err: anyerror, response_status: ?std.http.Status) !u8 {
    const rerun_script = "run scripts/teams-token.fish";
    switch (err) {
        error.ItemNotFound => try stderr.writeAll(
            "teams-zig: no token in the login keychain; " ++ rerun_script ++ "\n",
        ),
        error.UnknownRegion => try stderr.writeAll(
            "teams-zig: the stored region isn't amer, emea or apac; " ++ rerun_script ++ "\n",
        ),
        error.TokenExpired => try stderr.writeAll(
            "teams-zig: the skype token has expired; " ++ rerun_script ++ "\n",
        ),
        error.NotFound => try stderr.writeAll(
            "teams-zig: no conversation with that id, or it isn't yours\n",
        ),
        error.UnexpectedStatus => {
            // Client sets response_status before it returns UnexpectedStatus.
            std.debug.assert(response_status != null);
            try stderr.print(
                "teams-zig: the Chat Service answered HTTP {d}\n",
                .{@backingInt(response_status.?)},
            );
        },
        error.ForeignLink => try stderr.writeAll(
            "teams-zig: the Chat Service linked to another host; not following it\n",
        ),
        // Client refuses redirects, so std reports any redirect as too many.
        error.TooManyHttpRedirects => try stderr.writeAll(
            "teams-zig: the Chat Service redirected; not following it, to keep the token there\n",
        ),
        error.ResponseTooLarge => try stderr.writeAll(
            "teams-zig: the Chat Service sent a response larger than teams-zig accepts\n",
        ),
        else => return err,
    }
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
