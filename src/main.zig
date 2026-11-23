const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const core_foundation = teams.macos.core_foundation;
const commands = @import("commands.zig");
const Server = @import("Server.zig");
const Command = commands.Command;
const Clock = commands.Clock;
const connect = commands.connect;
const reportError = commands.reportError;
const requests_idle = commands.requests_idle;
const requests_seconds_max = commands.requests_seconds_max;

pub fn main(init: std.process.Init) !u8 {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (servesMcp(arguments)) return serveMcp(init, stderr);
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
    // locked) can take as long as it needs.
    startWatchdog(init.io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const zone = core_foundation.TimeZone.copySystem();
    defer core_foundation.release(zone);

    var clock: Clock = .{ .zone = zone, .now_seconds = Io.Clock.real.now(init.io).toSeconds() };
    requests_started_at.store(Io.Clock.awake.now(init.io).toSeconds(), .release);
    command.run(&client, init.io, &clock, stdout, stderr, &requests_started_at) catch |err| {
        const exit_code = try reportError(stderr, err, client.response_status);
        // The run error is the one worth reporting; a failed flush (say, a closed pipe) after it
        // would only hide that.
        stdout.flush() catch {};
        return exit_code;
    };
    stdout.flush() catch |err| return reportError(stderr, err, null);
    return 0;
}

/// Whether the arguments ask for the MCP server, `teams-zig mcp`.
fn servesMcp(arguments: []const []const u8) bool {
    if (arguments.len != 2) return false;
    return std.mem.eql(u8, arguments[1], "mcp");
}

/// Serves the tools on stdin and stdout until stdin ends. stdout carries only MCP messages;
/// stderr gets only the watchdog's line and a failure that ends the server.
fn serveMcp(init: std.process.Init, stderr: *Io.Writer) !u8 {
    // The watchdog counts only time spent waiting on the Chat Service (see `McpRunner.run`), so
    // waiting for the next request doesn't count.
    startWatchdog(init.io);

    var stdin_file_reader: Io.File.Reader = .init(.stdin(), init.io, &mcp_request_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);

    const zone = core_foundation.TimeZone.copySystem();
    defer core_foundation.release(zone);

    var runner: McpRunner = .{
        .gpa = init.gpa,
        .io = init.io,
        .environment = init.environ_map,
        .zone = zone,
        .stderr = stderr,
    };
    var server: Server = .{
        .reader = &stdin_file_reader.interface,
        .writer = &stdout_file_writer.interface,
        .request_memory = &mcp_request_memory,
        .output_buffer = &mcp_output_buffer,
        .runner = runner.interface(),
    };
    server.serve() catch |err| {
        try stderr.print("teams-zig: the MCP server stopped: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    return 0;
}

/// Static, since they are large and live as long as the server (STYLE 6.5).
var mcp_request_buffer: [Server.request_size_max]u8 = undefined;
var mcp_request_memory: [Server.request_memory_size_max]u8 = undefined;
var mcp_output_buffer: [Server.output_size_max]u8 = undefined;

/// Runs each tool's command as one CLI run does: it reads the token again, so one that the token
/// script stores while the server runs is used, and connects for that call only.
const McpRunner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environment: *const std.process.Environ.Map,
    zone: *const core_foundation.TimeZone,
    /// `Command.run` takes it for `watch`'s notes, which no tool writes.
    stderr: *Io.Writer,

    fn interface(runner: *McpRunner) Server.Runner {
        return .{ .context = runner, .run_fn = run };
    }

    fn run(context: *anyopaque, command: *const Command, output: *Io.Writer) ?Server.Failure {
        const runner: *McpRunner = @ptrCast(@alignCast(context));
        // `watch` never ends, so no tool runs it.
        std.debug.assert(command.* != .watch);
        var client: chat.Client = undefined;
        connect(&client, runner.gpa, runner.io, runner.environment) catch |err| {
            return .{ .err = err, .status = null };
        };
        defer client.deinit();

        var clock: Clock = .{
            .zone = runner.zone,
            .now_seconds = Io.Clock.real.now(runner.io).toSeconds(),
        };
        requests_started_at.store(Io.Clock.awake.now(runner.io).toSeconds(), .release);
        // A failed command leaves the clock running; the server waits next, which mustn't count.
        defer requests_started_at.store(requests_idle, .release);
        command.run(
            &client,
            runner.io,
            &clock,
            output,
            runner.stderr,
            &requests_started_at,
        ) catch |err| {
            // Client sets response_status before it returns UnexpectedStatus.
            if (err == error.UnexpectedStatus) std.debug.assert(client.response_status != null);
            return .{ .err = err, .status = client.response_status };
        };
        return null;
    }
};

/// Starts the watchdog thread. Without it a stalled request would hang forever; if the thread
/// can't start, commands still run, just unbounded.
fn startWatchdog(io: Io) void {
    const spawn_config: std.Thread.SpawnConfig = .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .allocator = null,
    };
    const watchdog_arguments = .{ io, &requests_started_at };
    if (std.Thread.spawn(spawn_config, watchdog, watchdog_arguments)) |watchdog_thread| {
        watchdog_thread.detach();
    } else |_| {}
}

const usage =
    \\usage: teams-zig <command>
    \\
    \\commands:
    \\  whoami                       show the signed-in user
    \\  chats [count]                list your chats (default 50, at most 100); * is unread
    \\  unread                       show what's new since you last read, in up to 10 of your
    \\                               50 newest chats
    \\  watch                        print new messages from your 50 newest chats as they
    \\                               arrive; Ctrl-C stops
    \\  messages <chat> [count]      show a chat's messages (default 50); <chat> is its exact
    \\                               name as chats shows it (quote it if it has spaces) or its id
    \\  send <chat> <text>           send <text>, written in Markdown (quote it), to <chat>
    \\  mcp                          serve these commands but watch as MCP tools, on stdin and
    \\                               stdout, until stdin ends
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

/// When the current batch of requests started, in awake-clock seconds, or `requests_idle` while
/// none is waiting on the Chat Service. Static, so the detached watchdog can't outlive it.
var requests_started_at: std.atomic.Value(i64) = .init(requests_idle);

/// Ends the process if a batch of requests hasn't been answered within `requests_seconds_max`.
/// std 0.17 has no read timeout and ignores its connect timeout, so a held connection (say, one
/// a per-app firewall is waiting to approve) would hang indefinitely. Output time isn't counted:
/// a slow pager reading the output is fine.
fn watchdog(io: Io, started_at: *const std.atomic.Value(i64)) void {
    while (true) {
        io.sleep(.fromSeconds(1), .awake) catch |err| switch (err) {
            // Only cancellation ends the sleep early, and nothing cancels this detached thread;
            // if something ever does, the watchdog's job is over.
            error.Canceled => return,
        };
        const now = Io.Clock.awake.now(io).toSeconds();
        if (requestsStalled(now, started_at.load(.acquire))) break;
    }

    std.debug.print(
        "teams-zig: no answer from the Chat Service in {d} seconds; check the network " ++
            "(after a send, check the chat first)\n",
        .{requests_seconds_max},
    );
    // _exit, not exit: exit handlers mustn't run on this thread while main is still working.
    std.c._exit(1);
}

/// Whether requests started at `started_at` (awake-clock seconds, or `requests_idle`) have gone
/// unanswered for `requests_seconds_max` by `now`.
fn requestsStalled(now: i64, started_at: i64) bool {
    return now -| started_at >= requests_seconds_max;
}

test "requestsStalled fires only after the limit, and never while idle" {
    try std.testing.expect(!requestsStalled(1000, 1000));
    try std.testing.expect(!requestsStalled(1000 + requests_seconds_max - 1, 1000));
    try std.testing.expect(requestsStalled(1000 + requests_seconds_max, 1000));
    try std.testing.expect(!requestsStalled(1000, requests_idle));
    try std.testing.expect(!requestsStalled(std.math.maxInt(i64), requests_idle));
}

test {
    _ = commands;
    _ = Server;
    // Tests don't call `main`; this compiles the MCP path, which nothing else in them reaches.
    _ = &serveMcp;
}

test "servesMcp takes mcp alone" {
    try std.testing.expect(servesMcp(&.{ "teams-zig", "mcp" }));
    try std.testing.expect(!servesMcp(&.{ "teams-zig", "mcp", "fake" }));
    try std.testing.expect(!servesMcp(&.{ "teams-zig", "whoami" }));
    try std.testing.expect(!servesMcp(&.{"teams-zig"}));
}
