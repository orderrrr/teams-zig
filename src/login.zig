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
