const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const chat = teams.chat;
const core_foundation = teams.macos.core_foundation;
const commands = @import("commands.zig");
const Server = @import("Server.zig");
const Cache = @import("Cache.zig");
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

    const home = openHome(init.io, init.environ_map);
    defer if (home) |dir| dir.close(init.io);
    var cache = try loadCache(init.gpa, init.io, home);
    defer cache.deinit();
    // Saved even after a failure: what was learned, or a dropped entry, still holds.
    defer saveCacheOrSay(&cache, init.io, home, stderr);

    var clock: Clock = .{ .zone = zone, .now_seconds = Io.Clock.real.now(init.io).toSeconds() };
    requests_started_at.store(Io.Clock.awake.now(init.io).toSeconds(), .release);
    command.run(
        &client,
        &cache,
        init.io,
        &clock,
        stdout,
        stderr,
        &requests_started_at,
    ) catch |err| {
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
    defer runner.deinit();
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

/// Runs each tool's command with one client kept across calls, so its connection is reused. The
/// keychain is read again only when there is no client: at the first call, and after a token or
/// connection failure drops it. A read tool then runs once more; `send` never does.
const McpRunner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environment: *const std.process.Environ.Map,
    zone: *const core_foundation.TimeZone,
    /// `Command.run` takes it for `watch`'s notes, which no tool writes.
    stderr: *Io.Writer,
    /// Null until the first call, and after `dropClient`: a token or connection failure, or a
    /// send after an idle spell. Initialized in place, since the client must not move once its
    /// connections exist.
    kept: ?Kept = null,

    /// The client kept across calls, when it last finished one, and whether the cache's user
    /// may still be another token's.
    const Kept = struct {
        client: chat.Client,
        /// Awake-clock seconds.
        used_at_seconds: i64,
        /// True from connecting until a call forgets the cached user and writes the file
        /// without it: a new client read the keychain, and its token may be another account's.
        /// Kept here, not per call, so a failed save, or no home, forgets it again next call.
        cached_self_stale: bool,
    };

    /// A send on a connection idle longer than this starts on a fresh one: the service may have
    /// closed it, and a send can't be retried. Reads just retry once.
    const send_idle_seconds_max: i64 = 30;

    fn interface(runner: *McpRunner) Server.Runner {
        return .{ .context = runner, .run_fn = run };
    }

    fn deinit(runner: *McpRunner) void {
        runner.dropClient();
        runner.* = undefined;
    }

    /// Closes the kept client, so the next call connects again and reads the keychain.
    fn dropClient(runner: *McpRunner) void {
        if (runner.kept) |*kept| kept.client.deinit();
        runner.kept = null;
    }

    fn run(context: *anyopaque, command: *const Command, output: *Io.Writer) ?Server.Failure {
        const runner: *McpRunner = @ptrCast(@alignCast(context));
        // `watch` never ends, so no tool runs it.
        std.debug.assert(command.* != .watch);
        std.debug.assert(output.end == 0);
        const failure = runner.runOnce(command, output) orelse return null;
        if (!retries(command, failure.err)) return failure;
        // The second run starts from empty output; at most one more run.
        output.end = 0;
        return runner.runOnce(command, output);
    }

    /// Whether `err` leaves the client unusable or its token stale, so the next run connects
    /// again and reads the keychain.
    fn dropsClient(err: commands.CommandError) bool {
        return switch (err) {
            error.TokenExpired, error.ConnectFailed, error.SendFailed => true,
            error.ConnectionDropped => true,
            else => false,
        };
    }

    /// Whether a call that failed with `err` runs once more: only a read, and only after the
    /// client was dropped. A send never runs twice, since the first may have posted.
    fn retries(command: *const Command, err: commands.CommandError) bool {
        if (command.* == .send) return false;
        return dropsClient(err);
    }

    fn runOnce(runner: *McpRunner, command: *const Command, output: *Io.Writer) ?Server.Failure {
        const now_seconds = Io.Clock.awake.now(runner.io).toSeconds();
        if (command.* == .send) {
            if (runner.kept) |*kept| {
                if (sendsFresh(now_seconds, kept.used_at_seconds)) runner.dropClient();
            }
        }
        const client = runner.connected(now_seconds) catch |err| {
            return .{ .err = err, .status = null };
        };
        defer if (runner.kept) |*kept| {
            kept.used_at_seconds = Io.Clock.awake.now(runner.io).toSeconds();
        };

        // Read for every call, so a cache deleted at sign-in takes effect at once.
        const home = openHome(runner.io, runner.environment);
        defer if (home) |dir| dir.close(runner.io);
        var cache = loadCache(runner.gpa, runner.io, home) catch |err| {
            return .{ .err = err, .status = null };
        };
        defer cache.deinit();
        defer {
            // The server says nothing about a failed save: its stderr carries only the
            // watchdog's line and a failure that ends it. A failed save costs requests later,
            // and leaves the cached user marked stale, to forget again.
            if (saveCache(&cache, runner.io, home)) {
                // Without a home nothing was written, so the file may still hold the old user.
                if (home != null) {
                    if (runner.kept) |*kept| kept.cached_self_stale = false;
                }
            } else |_| {}
        }
        // The cached user may be the old token's, after a sign-in to another account.
        if (runner.kept.?.cached_self_stale) cache.forgetSelf();

        var clock: Clock = .{
            .zone = runner.zone,
            .now_seconds = Io.Clock.real.now(runner.io).toSeconds(),
        };
        requests_started_at.store(Io.Clock.awake.now(runner.io).toSeconds(), .release);
        // A failed command leaves the clock running; the server waits next, which mustn't count.
        defer requests_started_at.store(requests_idle, .release);
        command.run(
            client,
            &cache,
            runner.io,
            &clock,
            output,
            runner.stderr,
            &requests_started_at,
        ) catch |err| {
            // Client sets response_status before it returns UnexpectedStatus.
            if (err == error.UnexpectedStatus) std.debug.assert(client.response_status != null);
            const failure: Server.Failure = .{ .err = err, .status = client.response_status };
            if (dropsClient(err)) runner.dropClient();
            return failure;
        };
        return null;
    }

    /// Whether a send at `now_seconds` should start on a fresh connection, the kept one last
    /// used at `used_at_seconds` (both awake-clock seconds).
    fn sendsFresh(now_seconds: i64, used_at_seconds: i64) bool {
        return now_seconds -| used_at_seconds > send_idle_seconds_max;
    }

    /// The kept client, connecting first (and reading the keychain) if there is none.
    fn connected(runner: *McpRunner, now_seconds: i64) commands.CommandError!*chat.Client {
        if (runner.kept) |*kept| return &kept.client;
        runner.kept = .{
            .client = undefined,
            .used_at_seconds = now_seconds,
            .cached_self_stale = true,
        };
        connect(&runner.kept.?.client, runner.gpa, runner.io, runner.environment) catch |err| {
            runner.kept = null;
            return err;
        };
        return &runner.kept.?.client;
    }
};

/// Your home directory, which holds the cache (see `Cache.sub_path`), or null without one: then
/// the cache stays empty and isn't saved.
fn openHome(io: Io, environment: *const std.process.Environ.Map) ?Io.Dir {
    const home_path = environment.get("HOME") orelse return null;
    if (!std.fs.path.isAbsolute(home_path)) return null;
    const options: Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .iterate = false,
        .follow_symlinks = true,
    };
    return Io.Dir.openDirAbsolute(io, home_path, options) catch null;
}

/// The cache under `home`, or an empty one without a home.
fn loadCache(gpa: std.mem.Allocator, io: Io, home: ?Io.Dir) error{OutOfMemory}!Cache {
    const dir = home orelse return .init(gpa);
    return Cache.load(gpa, io, dir);
}

/// Saves `cache` under `home` if it changed; without a home there is nothing to save.
fn saveCache(cache: *const Cache, io: Io, home: ?Io.Dir) Cache.SaveError!void {
    const dir = home orelse return;
    if (!cache.changed) return;
    try cache.save(io, dir);
}

/// The CLI's save: a failed save only costs requests next time, so the command goes on, and one
/// line on `stderr` says why.
fn saveCacheOrSay(cache: *const Cache, io: Io, home: ?Io.Dir, stderr: *Io.Writer) void {
    saveCache(cache, io, home) catch |err| {
        // stderr is the last place to report anything; if writing there fails, nothing is left.
        stderr.print("teams-zig: couldn't save the cache: {t}\n", .{err}) catch return;
        stderr.flush() catch return;
    };
}

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
    \\  send <chat> <text>           send <text>, written in Markdown (quote it), to <chat>:
    \\                               at most 16 KiB of UTF-8, with no control characters but
    \\                               tab and newline
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
    _ = @import("Cache.zig");
    // Tests don't call `main`; this compiles the MCP path, which nothing else in them reaches.
    _ = &serveMcp;
}

test "servesMcp takes mcp alone" {
    try std.testing.expect(servesMcp(&.{ "teams-zig", "mcp" }));
    try std.testing.expect(!servesMcp(&.{ "teams-zig", "mcp", "fake" }));
    try std.testing.expect(!servesMcp(&.{ "teams-zig", "whoami" }));
    try std.testing.expect(!servesMcp(&.{"teams-zig"}));
}

test "McpRunner drops its client after a token or connection failure, and keeps it otherwise" {
    try std.testing.expect(McpRunner.dropsClient(error.TokenExpired));
    try std.testing.expect(McpRunner.dropsClient(error.ConnectFailed));
    try std.testing.expect(McpRunner.dropsClient(error.SendFailed));
    try std.testing.expect(McpRunner.dropsClient(error.ConnectionDropped));
    try std.testing.expect(!McpRunner.dropsClient(error.NotFound));
    try std.testing.expect(!McpRunner.dropsClient(error.ChatNameAmbiguous));
    try std.testing.expect(!McpRunner.dropsClient(error.UnexpectedStatus));
}

test "McpRunner runs a read once more after a dropped client, and never a send" {
    const send: Command = .{ .send = .{ .chat = .{ .id = "48:notes" }, .text = "fake" } };
    const chats: Command = .{ .chats = 5 };
    try std.testing.expect(McpRunner.retries(&chats, error.TokenExpired));
    try std.testing.expect(McpRunner.retries(&chats, error.ConnectionDropped));
    try std.testing.expect(!McpRunner.retries(&chats, error.NotFound));
    try std.testing.expect(!McpRunner.retries(&send, error.TokenExpired));
    try std.testing.expect(!McpRunner.retries(&send, error.ConnectionDropped));
}

test "McpRunner starts a send on a fresh connection after 30 idle seconds" {
    try std.testing.expect(!McpRunner.sendsFresh(1000, 1000));
    try std.testing.expect(!McpRunner.sendsFresh(1030, 1000));
    try std.testing.expect(McpRunner.sendsFresh(1031, 1000));
}

test "the CLI says on stderr when the cache can't be saved" {
    const tmp_options: Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .iterate = false,
        .follow_symlinks = true,
    };
    var tmp = std.testing.tmpDir(tmp_options);
    defer tmp.cleanup();
    // A file where the cache's directory should be, so the save fails.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Library",
        .data = "fake",
        .flags = .{
            .read = false,
            .truncate = true,
            .exclusive = false,
            .lock = .none,
            .lock_nonblocking = false,
            .permissions = .default_file,
            .resolve_beneath = false,
        },
    });

    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putChat("Fake Standup", "19:fake-group@thread.v2");
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    saveCacheOrSay(&cache, std.testing.io, tmp.dir, &out.writer);
    const line_start = "teams-zig: couldn't save the cache: ";
    try std.testing.expect(std.mem.startsWith(u8, out.written(), line_start));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\n"));
}
