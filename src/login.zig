//! `teams-zig login`: signs in to Teams in agent-browser and stores the skype token and region in
//! the login keychain, as `scripts/teams-token.fish` did.

const std = @import("std");
const teams = @import("teams");
const Region = teams.chat.Client.Region;

/// What one `agent-browser network requests --json` output shows. Each is null until a request
/// carries it. `token` borrows the output, or the arena when JSON escapes made a copy.
pub const Found = struct {
    token: ?[]const u8,
    region: ?Region,
};

pub const FindError = std.json.ParseError(std.json.Scanner) || error{TokenTooLong};

/// The longest skype token taken; they run to about 2 KiB.
pub const token_size_max = 16 * 1024;

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
/// token; agent-browser's output holds no JSON escapes in a token.
const parse_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .use_last,
    .ignore_unknown_fields = true,
    .max_value_len = null,
    .allocate = .alloc_if_needed,
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
        const name = urlRegionName(request.url) orelse continue;
        if (std.meta.stringToEnum(Region, name)) |region| return region;
    }
    return null;
}

/// Paths on the newer web host that name the region next.
const web_region_prefixes = [_][]const u8{
    "teams.cloud.microsoft/api/chatsvc/",
    "teams.cloud.microsoft/api/mt/",
};

fn urlRegionName(url: []const u8) ?[]const u8 {
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

/// Runs agent-browser with some arguments and gives its stdout, owned by the caller. The seam
/// tests replace.
pub const AgentBrowser = struct {
    context: *anyopaque,
    run_fn: *const fn (context: *anyopaque, arguments: []const []const u8) RunError![]u8,

    fn run(agent_browser: AgentBrowser, arguments: []const []const u8) RunError![]u8 {
        std.debug.assert(arguments.len > 0);
        return agent_browser.run_fn(agent_browser.context, arguments);
    }
};

pub const RunError = error{
    AgentBrowserMissing,
    AgentBrowserFailed,
    AgentBrowserOutputTooLarge,
    OutOfMemory,
};

/// The largest output read from one run: Teams makes a few thousand requests while it loads.
pub const output_size_max = 64 * 1024 * 1024;

/// agent-browser as a child process, found on PATH.
pub const ChildAgentBrowser = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Tests run other programs in its place.
    program: []const u8 = "agent-browser",

    pub fn interface(child: *ChildAgentBrowser) AgentBrowser {
        return .{ .context = child, .run_fn = run };
    }

    fn run(context: *anyopaque, arguments: []const []const u8) RunError![]u8 {
        const child: *ChildAgentBrowser = @ptrCast(@alignCast(context));
        var argv_buffer: [argument_count_max + 1][]const u8 = undefined;
        std.debug.assert(arguments.len <= argument_count_max);
        argv_buffer[0] = child.program;
        @memcpy(argv_buffer[1..][0..arguments.len], arguments);

        const result = std.process.run(child.gpa, child.io, .{
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
            .timeout = .none,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return error.AgentBrowserMissing,
            error.StreamTooLong => return error.AgentBrowserOutputTooLarge,
            else => return error.AgentBrowserFailed,
        };
        // Its notes, such as an out-of-date browser, aren't shown: `login` says what failed.
        child.gpa.free(result.stderr);
        errdefer {
            std.crypto.secureZero(u8, result.stdout);
            child.gpa.free(result.stdout);
        }

        switch (result.term) {
            .exited => |code| if (code != 0) return error.AgentBrowserFailed,
            else => return error.AgentBrowserFailed,
        }
        return result.stdout;
    }

    /// The most arguments one run takes (`open` with its options is the longest).
    const argument_count_max = 8;
    const stderr_size_max = 64 * 1024;
};

/// A sign-in's result. `token` is owned and zeroed by `deinit`.
pub const SignedIn = struct {
    token: []u8,
    region: Region,

    pub fn deinit(signed_in: *SignedIn, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, signed_in.token);
        gpa.free(signed_in.token);
        signed_in.* = undefined;
    }
};

pub const SignInError = RunError || FindErrorKind || std.Io.Writer.Error || std.Io.Cancelable ||
    error{
        /// `open` failed.
        BrowserOpenFailed,
        /// A later run failed: usually the user closed the window.
        BrowserStopped,
        NoTokenSeen,
        NoRegionSeen,
    };

/// `find`'s failures, by what they mean to the user.
const FindErrorKind = error{ UnexpectedOutput, TokenTooLong };

pub const SignInOptions = struct {
    /// agent-browser's Chrome profile, so a sign-in lasts between runs.
    profile_path: []const u8,
    poll_interval: std.Io.Duration,
    poll_count_max: u32,
    /// Where to tell the user to sign in.
    note: *std.Io.Writer,
};

/// What the script used: a 2 s poll for up to 300 s.
pub const poll_interval_default: std.Io.Duration = .fromSeconds(2);
pub const poll_count_default: u32 = 150;

const session = "teams-zig";
const requests_arguments = [_][]const u8{ "--session", session, "network", "requests", "--json" };
const teams_url = "https://teams.microsoft.com";

/// Opens Teams in agent-browser's own session and profile, waits for the user to sign in, and
/// reads the token and region from the requests the web client makes. Always closes the browser.
pub fn signIn(
    gpa: std.mem.Allocator,
    io: std.Io,
    agent_browser: AgentBrowser,
    options: SignInOptions,
) SignInError!SignedIn {
    std.debug.assert(options.poll_count_max > 0);
    const opened = agent_browser.run(&.{
        "--session", session, "--headed", "--profile", options.profile_path, "open", teams_url,
    }) catch |err| switch (err) {
        error.AgentBrowserFailed => return error.BrowserOpenFailed,
        else => |other| return other,
    };
    gpa.free(opened);
    defer closeBrowser(gpa, agent_browser);

    try options.note.print(
        "Sign in to Teams in the browser window if asked. Waiting up to {d} seconds...\n",
        .{options.poll_interval.toSeconds() * options.poll_count_max},
    );
    try options.note.flush();

    var token_seen = false;
    for (0..options.poll_count_max) |_| {
        try io.sleep(options.poll_interval, .awake);
        const output = agent_browser.run(&requests_arguments) catch |err| switch (err) {
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
        return .{ .token = try gpa.dupe(u8, token), .region = region };
    }
    if (!token_seen) return error.NoTokenSeen;
    return error.NoRegionSeen;
}

/// The window stays open if this fails; it's not worth hiding the sign-in's own result for.
fn closeBrowser(gpa: std.mem.Allocator, agent_browser: AgentBrowser) void {
    const output = agent_browser.run(&.{ "--session", session, "close" }) catch return;
    gpa.free(output);
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

test "ChildAgentBrowser tells a missing program, a failed run and too much output apart" {
    var missing: ChildAgentBrowser = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .program = "teams-zig-no-such-program",
    };
    try std.testing.expectError(error.AgentBrowserMissing, missing.interface().run(&.{"open"}));

    var shell: ChildAgentBrowser = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .program = "/bin/sh",
    };
    const said = try shell.interface().run(&.{ "-c", "printf fake-output; echo note >&2" });
    defer std.testing.allocator.free(said);
    try std.testing.expectEqualStrings("fake-output", said);

    const failed = shell.interface().run(&.{ "-c", "exit 3" });
    try std.testing.expectError(error.AgentBrowserFailed, failed);
    const too_much = std.fmt.comptimePrint("head -c {d} /dev/zero", .{output_size_max + 1});
    try std.testing.expectError(
        error.AgentBrowserOutputTooLarge,
        shell.interface().run(&.{ "-c", too_much }),
    );
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

    fn run(context: *anyopaque, arguments: []const []const u8) RunError![]u8 {
        const fake: *FakeAgentBrowser = @ptrCast(@alignCast(context));
        const joined = try std.mem.join(std.testing.allocator, " ", arguments);
        try fake.runs.append(std.testing.allocator, joined);
        // `close` always succeeds; the rest follow the script, then the last one repeats.
        if (std.mem.endsWith(u8, joined, " close")) return std.testing.allocator.dupe(u8, "");
        const index = @min(fake.run_count, fake.outputs.len - 1);
        fake.run_count += 1;
        return switch (fake.outputs[index]) {
            .text => |text| std.testing.allocator.dupe(u8, text),
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
    return signIn(std.testing.allocator, std.testing.io, fake.interface(), .{
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
    defer signed_in.deinit(std.testing.allocator);

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
