const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const keychain = teams.macos.keychain;

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

const chats_shown = 50;
const messages_shown = 50;

const Command = union(enum) {
    whoami,
    chats,
    messages: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = parseCommand(args) orelse {
        try stderr.writeAll(usage);
        try stderr.flush();
        return 2;
    };

    run(init.gpa, init.io, command, stdout) catch |err| {
        const hint = switch (err) {
            error.ItemNotFound => "no token in the login keychain; run scripts/teams-token.fish",
            error.TokenExpired => "the skype token has expired; run scripts/teams-token.fish",
            else => return err,
        };
        try stdout.flush();
        try stderr.print("teams-zig: {s}\n", .{hint});
        try stderr.flush();
        return 1;
    };
    try stdout.flush();
    return 0;
}

fn parseCommand(args: []const []const u8) ?Command {
    if (args.len == 2 and std.mem.eql(u8, args[1], "whoami")) return .whoami;
    if (args.len == 2 and std.mem.eql(u8, args[1], "chats")) return .chats;
    if (args.len == 3 and std.mem.eql(u8, args[1], "messages")) return .{ .messages = args[2] };
    return null;
}

fn run(gpa: std.mem.Allocator, io: Io, command: Command, stdout: *Io.Writer) !void {
    const token = try keychain.read(gpa, keychain_service, "skype-token");
    defer gpa.free(token);
    const region_name = try keychain.read(gpa, keychain_service, "region");
    defer gpa.free(region_name);
    const region = std.meta.stringToEnum(chat.Client.Region, region_name) orelse return error.UnknownRegion;

    var client: chat.Client = try .init(gpa, io, region, token);
    defer client.deinit();

    switch (command) {
        .whoami => {
            const user = try client.whoami();
            defer user.deinit(gpa);
            try stdout.print("{s} <{s}>\n", .{ user.name, user.upn });
        },
        .chats => {
            const list = try client.chats(chats_shown);
            defer list.deinit();
            for (list.items) |conversation| {
                try stdout.print("{s:<24}  {t:<7}  {s}  {s}\n", .{
                    conversation.last_message_at orelse "-",
                    conversation.kind,
                    if (conversation.topic.len > 0) conversation.topic else "(no topic)",
                    conversation.id,
                });
            }
        },
        .messages => |conversation_id| {
            const list = try client.messages(conversation_id, messages_shown);
            defer list.deinit();
            // The service returns newest first; print oldest first, like a chat window.
            var index = list.items.len;
            while (index > 0) {
                index -= 1;
                const message = list.items[index];
                const sender = if (message.sender_name.len > 0) message.sender_name else message.sender;
                try stdout.print("{s}  {s}: ", .{ message.arrived_at, sender });
                if (message.deleted_at != null) {
                    try stdout.writeAll("(deleted)");
                } else if (message.isText()) {
                    try message.writeText(stdout);
                } else {
                    try stdout.print("[{s}]", .{message.message_type});
                }
                try stdout.writeByte('\n');
            }
        },
    }
}

test "parseCommand accepts the three commands and rejects anything else" {
    try std.testing.expectEqual(Command.whoami, parseCommand(&.{ "teams-zig", "whoami" }).?);
    try std.testing.expectEqual(Command.chats, parseCommand(&.{ "teams-zig", "chats" }).?);
    try std.testing.expectEqualStrings("19:fake", parseCommand(&.{ "teams-zig", "messages", "19:fake" }).?.messages);
    try std.testing.expectEqual(null, parseCommand(&.{"teams-zig"}));
    try std.testing.expectEqual(null, parseCommand(&.{ "teams-zig", "messages" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "teams-zig", "send" }));
}
