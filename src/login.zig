//! `teams-zig login`: signs in to Teams in agent-browser and stores the skype token and region in
//! the login keychain. It replaced the M1 token script, and keeps its steps and names.

const std = @import("std");
const teams = @import("teams");
const Region = teams.chat.Client.Region;
const keychain = @import("keychain.zig");
const Cache = @import("Cache.zig");

/// agent-browser's Chrome profile for teams-zig, under your home directory: the script's, so a
/// profile that is already signed in keeps working.
pub const profile_sub_path = "Library/Application Support/teams-zig/browser";

pub const LoginError = SignInError || keychain.WriteError || error{
    ProfileDirFailed,
    CacheDeleteFailed,
};

pub const LoginOptions = struct {
    home: std.Io.Dir,
    /// `keychain.service`; tests use a throwaway one.
    service_name: []const u8,
    /// Where the sign-in note and the result go: stderr, as the script did.
    note: *std.Io.Writer,
    poll_interval: std.Io.Duration,
    poll_count_max: u32,
};

/// `teams-zig login`: signs in through agent-browser, stores the skype token and region in the
/// login keychain, and deletes the cache, since the new token may be another account's.
pub fn login(
    gpa: std.mem.Allocator,
    io: std.Io,
    agent_browser: AgentBrowser,
    options: *const LoginOptions,
) LoginError!void {
    options.home.createDirPath(io, profile_sub_path) catch return error.ProfileDirFailed;
    const profile_path = options.home.realPathFileAlloc(io, profile_sub_path, gpa) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProfileDirFailed,
        };
    };
    defer gpa.free(profile_path);

    var signed_in = try signIn(gpa, io, agent_browser, &.{
        .profile_path = profile_path,
        .poll_interval = options.poll_interval,
        .poll_count_max = options.poll_count_max,
        .note = options.note,
    });
    defer signed_in.deinit();

    try keychain.write(gpa, io, options.service_name, &.{
        .{ .account = "skype-token", .value = signed_in.token },
        .{ .account = "region", .value = @tagName(signed_in.region) },
    });
    Cache.delete(io, options.home) catch return error.CacheDeleteFailed;

    try options.note.print(
        "Stored the skype token and region {t} in the login keychain.\n",
        .{signed_in.region},
    );
    try options.note.flush();
}

/// A one-line hint, with no line break, for every way `login` can fail. No hint holds a value
/// agent-browser gave, since its output holds the token.
pub fn writeHint(writer: *std.Io.Writer, err: LoginError) std.Io.Writer.Error!void {
    const wait_seconds = std.fmt.comptimePrint("{d}", .{wait_seconds_default});
    const run_seconds = std.fmt.comptimePrint("{d}", .{ChildAgentBrowser.run_seconds_default});
    const hint = switch (err) {
        error.AgentBrowserMissing => "agent-browser isn't on PATH; install it with " ++
            "`brew install agent-browser`, then run `agent-browser install`",
        error.BrowserOpenFailed => "agent-browser couldn't open the browser; try " ++
            "`agent-browser doctor`",
        error.BrowserStopped => "agent-browser stopped answering; was the browser window closed?",
        error.AgentBrowserFailed => "agent-browser failed",
        error.AgentBrowserTimedOut => "agent-browser didn't answer in " ++ run_seconds ++
            " seconds; try `agent-browser doctor`",
        error.AgentBrowserOutputTooLarge => "agent-browser's request list was larger than " ++
            "teams-zig reads",
        error.UnexpectedOutput => "agent-browser's request list had an unexpected shape; " ++
            "teams-zig is tested with agent-browser 0.43.0 (see `agent-browser --version`)",
        error.TokenTooLong => "the skype token was longer than teams-zig accepts",
        error.NoTokenSeen => "no skype token seen in " ++ wait_seconds ++
            " seconds; did sign-in finish?",
        error.NoRegionSeen => "no Chat Service region seen in " ++ wait_seconds ++ " seconds",
        error.UnstorableValue => "the skype token has characters the keychain tool can't take",
        error.KeychainLocked => keychain.locked_hint,
        error.ItemNotFound, error.KeychainReadFailed, error.KeychainWriteFailed => "couldn't " ++
            "write the teams-zig items to the login keychain; is it locked?",
        error.ProfileDirFailed => "couldn't make the browser profile folder ~/" ++ profile_sub_path,
        error.CacheDeleteFailed => "stored the token, but couldn't delete ~/" ++ Cache.sub_path ++
            "; delete it before the next command",
        error.OutOfMemory => "out of memory",
        error.Canceled => "canceled",
        error.WriteFailed => "couldn't write to stderr",
    };
    try writer.writeAll(hint);
}

/// A sign-in's result. `token` is owned and zeroed by `deinit`.
pub const SignedIn = struct {
    gpa: std.mem.Allocator,
    token: []u8,
    region: Region,

    pub fn deinit(signed_in: *SignedIn) void {
        std.crypto.secureZero(u8, signed_in.token);
        signed_in.gpa.free(signed_in.token);
        signed_in.* = undefined;
    }
};

pub const SignInError = RunError || OutputError || std.Io.Writer.Error || std.Io.Cancelable ||
    error{
        /// `open` failed.
        BrowserOpenFailed,
        /// A later run failed: usually the user closed the window.
        BrowserStopped,
        NoTokenSeen,
        NoRegionSeen,
    };

/// `find`'s failures, by what they mean to the user.
const OutputError = error{ UnexpectedOutput, TokenTooLong };

pub const SignInOptions = struct {
    /// agent-browser's Chrome profile, so a sign-in lasts between runs.
    profile_path: []const u8,
    poll_interval: std.Io.Duration,
    poll_count_max: u32,
    /// Where to tell the user to sign in.
    note: *std.Io.Writer,
};

/// What the script used: a 2 s poll for up to 300 s.
const poll_seconds_default: u32 = 2;
const wait_seconds_default: u32 = 300;
pub const poll_interval_default: std.Io.Duration = .fromSeconds(poll_seconds_default);
pub const poll_count_default: u32 = @divExact(wait_seconds_default, poll_seconds_default);

const session = "teams-zig";
const requests_arguments = [_][]const u8{ "--session", session, "network", "requests", "--json" };
const close_arguments = [_][]const u8{ "--session", session, "close" };
const teams_url = "https://teams.microsoft.com";

/// Opens Teams in agent-browser's own session and profile, waits for the user to sign in, and
/// reads the token and region from the requests the web client makes. Always closes the browser.
pub fn signIn(
    gpa: std.mem.Allocator,
    io: std.Io,
    agent_browser: AgentBrowser,
    options: *const SignInOptions,
) SignInError!SignedIn {
    std.debug.assert(options.poll_count_max > 0);
    // Registered first: a failed `open` may still have started the window.
    defer signInClose(gpa, agent_browser);
    const opened = agent_browser.run(gpa, &.{
        "--session", session, "--headed", "--profile", options.profile_path, "open", teams_url,
    }) catch |err| switch (err) {
        error.AgentBrowserFailed => return error.BrowserOpenFailed,
        else => |other| return other,
    };
    gpa.free(opened);

    try options.note.print(
        "Sign in to Teams in the browser window if asked. Waiting up to {d} seconds...\n",
        .{options.poll_interval.toSeconds() * options.poll_count_max},
    );
    try options.note.flush();

    var token_seen = false;
    for (0..options.poll_count_max) |_| {
        try io.sleep(options.poll_interval, .awake);
        const output = agent_browser.run(gpa, &requests_arguments) catch |err| switch (err) {
            error.AgentBrowserFailed => return error.BrowserStopped,
            else => |other| return other,
        };
        defer {
            // The output holds the token, and `find`'s strings point into it.
            std.crypto.secureZero(u8, output);
            gpa.free(output);
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const found = find(arena.allocator(), output) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TokenTooLong => return error.TokenTooLong,
            else => return error.UnexpectedOutput,
        };
        const token = found.token orelse continue;
        token_seen = true;
        const region = found.region orelse continue;
        // `find` gives no empty token and none over the limit.
        std.debug.assert(token.len > 0);
        std.debug.assert(token.len <= token_size_max);
        return .{ .gpa = gpa, .token = try gpa.dupe(u8, token), .region = region };
    }
    if (!token_seen) return error.NoTokenSeen;
    return error.NoRegionSeen;
}

/// The window stays open if this fails; it's not worth hiding the sign-in's own result for, so
/// the error is dropped on purpose.
fn signInClose(gpa: std.mem.Allocator, agent_browser: AgentBrowser) void {
    const output = agent_browser.run(gpa, &close_arguments) catch return;
    gpa.free(output);
}

/// Runs agent-browser with some arguments and gives its stdout, allocated with `gpa` and owned
/// by the caller. The seam tests replace.
pub const AgentBrowser = struct {
    context: *anyopaque,
    run_fn: *const fn (
        context: *anyopaque,
        gpa: std.mem.Allocator,
        arguments: []const []const u8,
    ) RunError![]u8,

    fn run(
        agent_browser: AgentBrowser,
        gpa: std.mem.Allocator,
        arguments: []const []const u8,
    ) RunError![]u8 {
        std.debug.assert(arguments.len > 0);
        return agent_browser.run_fn(agent_browser.context, gpa, arguments);
    }
};

pub const RunError = error{
    AgentBrowserMissing,
    AgentBrowserFailed,
    AgentBrowserTimedOut,
    AgentBrowserOutputTooLarge,
    OutOfMemory,
};

/// The largest output read from one run: Teams makes a few thousand requests while it loads.
pub const output_size_max: u32 = 64 * 1024 * 1024;

/// agent-browser as a child process, found on PATH.
pub const ChildAgentBrowser = struct {
    io: std.Io,
    /// Tests run other programs in its place.
    program: []const u8,
    /// How long one run may take to give all its output; past it, the daemon is stuck (say, on
    /// a locked profile).
    run_seconds_max: u32,

    /// The most arguments one run takes (`open` with its options is the longest).
    const argument_count_max: u32 = 8;
    const stderr_size_max: u32 = 64 * 1024;
    /// `open` waits for Teams to load, which can take a while on a slow network.
    pub const run_seconds_default: u32 = 60;

    pub fn interface(child: *ChildAgentBrowser) AgentBrowser {
        return .{ .context = child, .run_fn = run };
    }

    fn run(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        arguments: []const []const u8,
    ) RunError![]u8 {
        const child: *ChildAgentBrowser = @ptrCast(@alignCast(context));
        var argv_buffer: [argument_count_max + 1][]const u8 = undefined;
        std.debug.assert(arguments.len <= argument_count_max);
        std.debug.assert(child.run_seconds_max > 0);
        argv_buffer[0] = child.program;
        @memcpy(argv_buffer[1..][0..arguments.len], arguments);

        const result = std.process.run(gpa, child.io, .{
            .exe = .detect,
            .argv = argv_buffer[0 .. arguments.len + 1],
            .stderr_limit = .limited(stderr_size_max),
            .stdout_limit = .limited(output_size_max),
            .reserve_amount = 64 * 1024,
            .cwd = .inherit,
            .environ_map = null,
            .expand_arg0 = .no_expand,
            .progress_node = .none,
            .create_no_window = true,
            // A deadline, not a duration: std restarts a duration at each read, so output now
            // and then would extend it. Waiting for the exit after the output ends has no limit.
            .timeout = .{ .deadline = .fromNow(child.io, .{
                .raw = .fromSeconds(child.run_seconds_max),
                .clock = .awake,
            }) },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return error.AgentBrowserMissing,
            error.StreamTooLong => return error.AgentBrowserOutputTooLarge,
            error.Timeout => return error.AgentBrowserTimedOut,
            else => return error.AgentBrowserFailed,
        };
        // Its notes, such as an out-of-date browser, aren't shown: `login` says what failed.
        gpa.free(result.stderr);
        errdefer {
            std.crypto.secureZero(u8, result.stdout);
            gpa.free(result.stdout);
        }

        switch (result.term) {
            .exited => |code| if (code != 0) return error.AgentBrowserFailed,
            else => return error.AgentBrowserFailed,
        }
        return result.stdout;
    }
};

/// What one `agent-browser network requests --json` output shows. Each is null until a request
/// carries it. `token` borrows the output, or the arena when JSON escapes made a copy.
pub const Found = struct {
    token: ?[]const u8,
    region: ?Region,
};

pub const FindError = std.json.ParseError(std.json.Scanner) || error{TokenTooLong};

/// The longest skype token taken; they run to about 2 KiB.
pub const token_size_max: u32 = 16 * 1024;

comptime {
    // Every token `find` takes must fit the keychain.
    std.debug.assert(token_size_max <= keychain.value_size_max);
}

/// The part of agent-browser 0.43.0's output read here (see docs/PLAN.md M8.1).
const Output = struct {
    data: struct {
        requests: []const Request,
    },
};

const Request = struct {
    method: []const u8,
    url: []const u8,
    headers: std.json.ArrayHashMap([]const u8) = .{},
    /// Absent on a request with no body.
    postData: ?[]const u8 = null,
};

/// Strings point into `output` where they can, so the caller zeroes one buffer to wipe the
/// token; agent-browser's output holds no JSON escapes in a token. A string with escapes is
/// copied into the arena, which is freed without zeroing: a short-lived process accepts that.
const parse_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .use_last,
    .ignore_unknown_fields = true,
    .max_value_len = output_size_max,
    .allocate = .alloc_if_needed,
    .parse_numbers = true,
};

const token_body_prefix = "skypetoken=";
const token_header_name = "x-skypetoken";

/// Reads the skype token and the Chat Service region from the requests the Teams web client
/// made. As the script did: the token from the body of the POST to `/v1/skypetokenauth`, else
/// from an `x-skypetoken` header; the region from a Chat Service URL.
pub fn find(arena: std.mem.Allocator, output: []const u8) FindError!Found {
    const parsed = try std.json.parseFromSliceLeaky(Output, arena, output, parse_options);
    const requests = parsed.data.requests;
    const token = findBodyToken(requests) orelse findHeaderToken(requests);
    if (token) |value| {
        if (value.len > token_size_max) return error.TokenTooLong;
    }
    return .{ .token = token, .region = findRegion(requests) };
}

/// The web client posts the token to `/v1/skypetokenauth` as the form body `skypetoken=<token>`.
fn findBodyToken(requests: []const Request) ?[]const u8 {
    for (requests) |request| {
        if (!std.mem.eql(u8, request.method, "POST")) continue;
        if (!std.mem.endsWith(u8, request.url, "/v1/skypetokenauth")) continue;
        const body = request.postData orelse continue;
        if (!std.mem.startsWith(u8, body, token_body_prefix)) continue;
        if (body.len == token_body_prefix.len) continue;
        return body[token_body_prefix.len..];
    }
    return null;
}

/// Some loads also send the token in an `x-skypetoken` header, in any case, with or without
/// the `skypetoken=` prefix.
fn findHeaderToken(requests: []const Request) ?[]const u8 {
    for (requests) |request| {
        var iterator = request.headers.map.iterator();
        while (iterator.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.key_ptr.*, token_header_name)) continue;
            const value = header.value_ptr.*;
            const token = if (std.mem.startsWith(u8, value, token_body_prefix))
                value[token_body_prefix.len..]
            else
                value;
            if (token.len > 0) return token;
        }
    }
    return null;
}

/// Chat Service URLs carry the region in the host (`{region}.ng.msg.teams.microsoft.com`) or,
/// on the newer web host, in the path (`teams.cloud.microsoft/api/chatsvc/{region}/`, or
/// `/api/mt/{region}/`). The first URL with a known region wins; other names are passed over.
fn findRegion(requests: []const Request) ?Region {
    for (requests) |request| {
        const name = findRegionName(request.url) orelse continue;
        if (std.meta.stringToEnum(Region, name)) |region| return region;
    }
    return null;
}

/// Paths on the newer web host that name the region next.
const web_region_prefixes = [_][]const u8{
    "teams.cloud.microsoft/api/chatsvc/",
    "teams.cloud.microsoft/api/mt/",
};

fn findRegionName(url: []const u8) ?[]const u8 {
    const https = "https://";
    const host_suffix = ".ng.msg.teams.microsoft.com/";
    if (!std.mem.startsWith(u8, url, https)) return null;
    const rest = url[https.len..];
    if (std.mem.indexOf(u8, rest, host_suffix)) |end| {
        const name = rest[0..end];
        if (std.mem.indexOfScalar(u8, name, '/') == null) return name;
    }
    for (web_region_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, rest, prefix)) continue;
        const path = rest[prefix.len..];
        const end = std.mem.indexOfScalar(u8, path, '/') orelse return null;
        return path[0..end];
    }
    return null;
}

test "find takes the token from the skypetokenauth POST and the region from a Chat Service host" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output =
        \\{"success":true,"data":{"requests":[
        \\{"method":"GET","url":"https://emea.ng.msg.teams.microsoft.com/v1/users/ME","headers":{}},
        \\{"method":"POST","url":"https://teams.microsoft.com/api/v1/skypetokenauth",
        \\ "headers":{"Content-Type":"application/x-www-form-urlencoded"},
        \\ "postData":"skypetoken=FAKE.TOKEN-1"}
        \\]},"error":null}
    ;
    const found = try find(arena.allocator(), output);
    try std.testing.expectEqualStrings("FAKE.TOKEN-1", found.token.?);
    try std.testing.expectEqual(Region.emea, found.region.?);
}

test "find falls back to an x-skypetoken header in any case, with or without the prefix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const prefixed =
        \\{"data":{"requests":[
        \\{"method":"GET","url":"https://teams.microsoft.com/v1/skypetokenauth","headers":{}},
        \\{"method":"GET","url":"https://example.com/",
        \\ "headers":{"X-SkypeToken":"skypetoken=FAKE-H1"}}
        \\]}}
    ;
    const bare =
        \\{"data":{"requests":[
        \\{"method":"GET","url":"https://example.com/","headers":{"x-skypetoken":"FAKE-H2"}}
        \\]}}
    ;
    try std.testing.expectEqualStrings("FAKE-H1", (try find(arena.allocator(), prefixed)).token.?);
    try std.testing.expectEqualStrings("FAKE-H2", (try find(arena.allocator(), bare)).token.?);
}

test "find prefers the POST body to a header" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output =
        \\{"data":{"requests":[
        \\{"method":"GET","url":"https://example.com/","headers":{"x-skypetoken":"FAKE-HEADER"}},
        \\{"method":"POST","url":"https://teams.microsoft.com/v1/skypetokenauth","headers":{},
        \\ "postData":"skypetoken=FAKE-BODY"}
        \\]}}
    ;
    try std.testing.expectEqualStrings("FAKE-BODY", (try find(arena.allocator(), output)).token.?);
}

test "find reads the region from the newer web host's chatsvc and mt paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const chatsvc =
        \\{"data":{"requests":[
        \\{"method":"GET","url":"https://teams.cloud.microsoft/api/chatsvc/amer/v1/users/ME"}
        \\]}}
    ;
    const mt =
        \\{"data":{"requests":[
        \\{"method":"GET","url":"https://teams.cloud.microsoft/api/mt/apac/beta/me"}
        \\]}}
    ;
    try std.testing.expectEqual(Region.amer, (try find(arena.allocator(), chatsvc)).region.?);
    try std.testing.expectEqual(Region.apac, (try find(arena.allocator(), mt)).region.?);
}

test "find passes over unknown region names and other hosts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output =
        \\{"data":{"requests":[
        \\{"method":"GET","url":"https://teams.cloud.microsoft/api/mt/part/amer-01/x"},
        \\{"method":"GET","url":"https://example.com/x.ng.msg.teams.microsoft.com/"},
        \\{"method":"GET","url":"http://emea.ng.msg.teams.microsoft.com/v1"},
        \\{"method":"GET","url":"https://emea.ng.msg.teams.microsoft.com/v1"}
        \\]}}
    ;
    try std.testing.expectEqual(Region.emea, (try find(arena.allocator(), output)).region.?);
}

test "find gives nulls when no request carries a token or a region" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const output =
        \\{"success":true,"data":{"lifecycle":{},"requests":[
        \\{"method":"POST","url":"https://teams.microsoft.com/v1/skypetokenauth",
        \\ "postData":"other=1"},
        \\{"method":"POST","url":"https://teams.microsoft.com/v1/skypetokenauth",
        \\ "postData":"skypetoken="},
        \\{"method":"GET","url":"https://example.com/","headers":{"x-skypetoken":"skypetoken="}}
        \\]},"error":null}
    ;
    const found = try find(arena.allocator(), output);
    try std.testing.expectEqual(null, found.token);
    try std.testing.expectEqual(null, found.region);
}

test "find refuses output that isn't agent-browser's, and a token over the limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SyntaxError, find(arena.allocator(), "not json"));
    try std.testing.expectError(error.MissingField, find(arena.allocator(), "{\"data\":{}}"));

    const head = "{\"data\":{\"requests\":[{\"method\":\"GET\",\"url\":\"https://example.com/\"," ++
        "\"headers\":{\"x-skypetoken\":\"";
    const tail = "\"}}]}}";
    const output = try arena.allocator().alloc(u8, head.len + token_size_max + 1 + tail.len);
    @memcpy(output[0..head.len], head);
    @memset(output[head.len..][0 .. token_size_max + 1], 'A');
    @memcpy(output[head.len + token_size_max + 1 ..], tail);
    try std.testing.expectError(error.TokenTooLong, find(arena.allocator(), output));
}

test "ChildAgentBrowser tells missing, failed, oversized and stuck runs apart" {
    const gpa = std.testing.allocator;
    var missing: ChildAgentBrowser = .{
        .io = std.testing.io,
        .program = "teams-zig-no-such-program",
        .run_seconds_max = 5,
    };
    const not_found = missing.interface().run(gpa, &.{"open"});
    try std.testing.expectError(error.AgentBrowserMissing, not_found);

    // Runs that should end on their own get ample time, so a busy machine can't fail them.
    var roomy_shell: ChildAgentBrowser = .{
        .io = std.testing.io,
        .program = "/bin/sh",
        .run_seconds_max = 30,
    };
    const said_script = "printf fake-output; echo note >&2";
    const said = try roomy_shell.interface().run(gpa, &.{ "-c", said_script });
    defer gpa.free(said);
    try std.testing.expectEqualStrings("fake-output", said);

    const failed = roomy_shell.interface().run(gpa, &.{ "-c", "exit 3" });
    try std.testing.expectError(error.AgentBrowserFailed, failed);
    const too_much = std.fmt.comptimePrint("head -c {d} /dev/zero", .{output_size_max + 1});
    try std.testing.expectError(
        error.AgentBrowserOutputTooLarge,
        roomy_shell.interface().run(gpa, &.{ "-c", too_much }),
    );

    // Runs that should hit the limit get a short one.
    var shell: ChildAgentBrowser = .{
        .io = std.testing.io,
        .program = "/bin/sh",
        .run_seconds_max = 1,
    };
    const stuck = shell.interface().run(gpa, &.{ "-c", "sleep 5" });
    try std.testing.expectError(error.AgentBrowserTimedOut, stuck);
    // Output now and then doesn't extend the limit: it is on the whole run.
    const trickle_script = "for i in 1 2 3 4; do echo x; sleep 0.4; done";
    const trickle = shell.interface().run(gpa, &.{ "-c", trickle_script });
    try std.testing.expectError(error.AgentBrowserTimedOut, trickle);
}

/// Gives scripted outputs, one per run, and records each run's arguments.
const FakeAgentBrowser = struct {
    outputs: []const Step,
    runs: std.ArrayList([]const u8) = .empty,
    run_count: u32 = 0,

    const Step = union(enum) { text: []const u8, err: RunError };

    fn interface(fake: *FakeAgentBrowser) AgentBrowser {
        return .{ .context = fake, .run_fn = run };
    }

    fn run(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        arguments: []const []const u8,
    ) RunError![]u8 {
        const fake: *FakeAgentBrowser = @ptrCast(@alignCast(context));
        const joined = try std.mem.join(std.testing.allocator, " ", arguments);
        try fake.runs.append(std.testing.allocator, joined);
        // `close` always succeeds; the rest follow the steps, then the last one repeats.
        if (std.mem.endsWith(u8, joined, " close")) return gpa.dupe(u8, "");
        const index = @min(fake.run_count, fake.outputs.len - 1);
        fake.run_count += 1;
        return switch (fake.outputs[index]) {
            .text => |text| gpa.dupe(u8, text),
            .err => |err| err,
        };
    }

    fn deinit(fake: *FakeAgentBrowser) void {
        for (fake.runs.items) |joined| std.testing.allocator.free(joined);
        fake.runs.deinit(std.testing.allocator);
    }
};

const fake_found =
    \\{"data":{"requests":[
    \\{"method":"POST","url":"https://teams.microsoft.com/v1/skypetokenauth",
    \\ "postData":"skypetoken=FAKE-SIGNED-IN"},
    \\{"method":"GET","url":"https://emea.ng.msg.teams.microsoft.com/v1/users/ME"}
    \\]}}
;
const fake_nothing = "{\"data\":{\"requests\":[]}}";

fn testSignIn(fake: *FakeAgentBrowser, note: *std.Io.Writer) SignInError!SignedIn {
    return signIn(std.testing.allocator, std.testing.io, fake.interface(), &.{
        .profile_path = "/fake/profile",
        .poll_interval = .zero,
        .poll_count_max = 3,
        .note = note,
    });
}

test "signIn opens Teams, polls until the token and region show, then closes" {
    var fake: FakeAgentBrowser = .{
        .outputs = &.{
            .{ .text = "" }, // open
            .{ .text = fake_nothing },
            .{ .text = fake_found },
        },
    };
    defer fake.deinit();
    var note_buffer: [256]u8 = undefined;
    var note: std.Io.Writer = .fixed(&note_buffer);

    var signed_in = try testSignIn(&fake, &note);
    defer signed_in.deinit();

    try std.testing.expectEqualStrings("FAKE-SIGNED-IN", signed_in.token);
    try std.testing.expectEqual(Region.emea, signed_in.region);
    try std.testing.expectEqual(4, fake.runs.items.len);
    try std.testing.expectEqualStrings(
        "--session teams-zig --headed --profile /fake/profile open https://teams.microsoft.com",
        fake.runs.items[0],
    );
    try std.testing.expectEqualStrings(
        "--session teams-zig network requests --json",
        fake.runs.items[1],
    );
    try std.testing.expectEqualStrings("--session teams-zig close", fake.runs.items[3]);
    try std.testing.expect(std.mem.indexOf(u8, note.buffered(), "Sign in") != null);
}

test "signIn says which value never showed, and still closes the browser" {
    var nothing: FakeAgentBrowser = .{ .outputs = &.{
        .{ .text = "" },
        .{ .text = fake_nothing },
    } };
    defer nothing.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.NoTokenSeen, testSignIn(&nothing, &discard.writer));
    try std.testing.expectEqual(5, nothing.runs.items.len);
    try std.testing.expectEqualStrings("--session teams-zig close", nothing.runs.items[4]);

    const token_only =
        \\{"data":{"requests":[{"method":"GET","url":"https://example.com/",
        \\ "headers":{"x-skypetoken":"FAKE-NO-REGION"}}]}}
    ;
    var no_region: FakeAgentBrowser = .{ .outputs = &.{
        .{ .text = "" },
        .{ .text = token_only },
    } };
    defer no_region.deinit();
    try std.testing.expectError(error.NoRegionSeen, testSignIn(&no_region, &discard.writer));
}

test "signIn reports a failed open, a closed window and output it can't read" {
    var discard: std.Io.Writer.Discarding = .init(&.{});

    var missing: FakeAgentBrowser = .{ .outputs = &.{.{ .err = error.AgentBrowserMissing }} };
    defer missing.deinit();
    try std.testing.expectError(error.AgentBrowserMissing, testSignIn(&missing, &discard.writer));

    var open_failed: FakeAgentBrowser = .{ .outputs = &.{.{ .err = error.AgentBrowserFailed }} };
    defer open_failed.deinit();
    try std.testing.expectError(error.BrowserOpenFailed, testSignIn(&open_failed, &discard.writer));
    // A failed open may still have started the window, so it is closed too.
    try std.testing.expectEqual(2, open_failed.runs.items.len);
    try std.testing.expectEqualStrings("--session teams-zig close", open_failed.runs.items[1]);

    var stopped: FakeAgentBrowser = .{ .outputs = &.{
        .{ .text = "" },
        .{ .err = error.AgentBrowserFailed },
    } };
    defer stopped.deinit();
    try std.testing.expectError(error.BrowserStopped, testSignIn(&stopped, &discard.writer));
    try std.testing.expectEqualStrings("--session teams-zig close", stopped.runs.items[2]);

    var garbled: FakeAgentBrowser = .{ .outputs = &.{ .{ .text = "" }, .{ .text = "not json" } } };
    defer garbled.deinit();
    try std.testing.expectError(error.UnexpectedOutput, testSignIn(&garbled, &discard.writer));
    try std.testing.expectEqualStrings("--session teams-zig close", garbled.runs.items[2]);
}

test "signIn stops at the first poll that shows both values" {
    var fake: FakeAgentBrowser = .{ .outputs = &.{ .{ .text = "" }, .{ .text = fake_found } } };
    defer fake.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});

    var signed_in = try testSignIn(&fake, &discard.writer);
    defer signed_in.deinit();

    try std.testing.expectEqualStrings("FAKE-SIGNED-IN", signed_in.token);
    // open, one poll, close.
    try std.testing.expectEqual(3, fake.runs.items.len);
}

test "login signs in, stores the token and region, deletes the cache and says so" {
    var tmp = std.testing.tmpDir(.{
        .access_sub_paths = true,
        .iterate = false,
        .follow_symlinks = true,
    });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "Library/Caches/teams-zig");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = Cache.sub_path,
        .data = "chat\tfake\t19:x\n",
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

    var service_buffer: [64]u8 = undefined;
    const service_name = keychain.testServiceName(&service_buffer);
    defer keychain.testDelete(&.{ .service_name = service_name, .account = "skype-token" });
    defer keychain.testDelete(&.{ .service_name = service_name, .account = "region" });

    var fake: FakeAgentBrowser = .{ .outputs = &.{ .{ .text = "" }, .{ .text = fake_found } } };
    defer fake.deinit();
    var note_buffer: [512]u8 = undefined;
    var note: std.Io.Writer = .fixed(&note_buffer);

    try login(std.testing.allocator, std.testing.io, fake.interface(), &.{
        .home = tmp.dir,
        .service_name = service_name,
        .note = &note,
        .poll_interval = .zero,
        .poll_count_max = 3,
    });

    const token = try keychain.read(std.testing.allocator, std.testing.io, &.{
        .service_name = service_name,
        .account = "skype-token",
    });
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("FAKE-SIGNED-IN", token);
    const region = try keychain.read(std.testing.allocator, std.testing.io, &.{
        .service_name = service_name,
        .account = "region",
    });
    defer std.testing.allocator.free(region);
    try std.testing.expectEqualStrings("emea", region);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, Cache.sub_path, .{ .follow_symlinks = true }),
    );
    _ = try tmp.dir.statFile(std.testing.io, profile_sub_path, .{ .follow_symlinks = true });
    const profile_argument = "/" ++ profile_sub_path ++ " open";
    try std.testing.expect(std.mem.indexOf(u8, fake.runs.items[0], profile_argument) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        note.buffered(),
        "Stored the skype token and region emea in the login keychain.\n",
    ));
}

test "writeHint names the fix and never a value agent-browser gave" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeHint(&writer, error.NoTokenSeen);
    try std.testing.expectEqualStrings(
        "no skype token seen in 300 seconds; did sign-in finish?",
        writer.buffered(),
    );

    writer = .fixed(&buffer);
    try writeHint(&writer, error.AgentBrowserMissing);
    try std.testing.expectEqualStrings(
        "agent-browser isn't on PATH; install it with `brew install agent-browser`, " ++
            "then run `agent-browser install`",
        writer.buffered(),
    );
}
