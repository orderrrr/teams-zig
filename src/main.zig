const std = @import("std");
const Io = std.Io;

const usage =
    \\usage: teams-zig <command>
    \\
    \\commands:
    \\  whoami                     show the signed-in user
    \\  chats                      list your chats
    \\  messages <conversation-id> show a conversation's messages
    \\
;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(usage);
    try stdout.flush();
}
