//! An authenticated connection to the Teams Chat Service,
//! at `{region}.ng.msg.teams.microsoft.com/v1`.

const Client = @This();

const std = @import("std");
const json = @import("json.zig");
const Conversation = @import("Conversation.zig");
const Message = @import("Message.zig");
const User = @import("User.zig");

gpa: std.mem.Allocator,
http: std.http.Client,
region: Region,
/// The `Authentication` header value, `skypetoken=<token>`. Owned.
authentication: []u8,
/// Holds the latest response body, decompressed. Allocated once, `body_size_max` long.
body_buffer: []u8,
/// The window a gzip body is decompressed through. Allocated once, `flate.max_window_len` long.
decompress_window: []u8,
/// The status of the latest response, for error messages.
response_status: ?std.http.Status = null,

pub const Region = enum {
    amer,
    emea,
    apac,

    pub fn baseUrl(region: Region) []const u8 {
        return switch (region) {
            inline else => |tag| "https://" ++ @tagName(tag) ++ ".ng.msg.teams.microsoft.com/v1",
        };
    }
};

pub const Error = error{
    /// The skype token was rejected: it expires after about a day, so rerun the token script.
    TokenExpired,
    /// 404: usually a conversation id that doesn't exist or isn't yours.
    NotFound,
    /// Any other non-200 status; `response_status` has it.
    UnexpectedStatus,
    /// A link from the service pointed outside the Chat Service, or carried bytes that don't belong
    /// on a request line. It isn't followed, so the token stays with the Chat Service.
    ForeignLink,
    ResponseTooLarge,
    /// Couldn't reach the Chat Service: the name lookup, the connection or TLS failed.
    ConnectFailed,
    /// Sending the request failed, such as on a connection the server had closed.
    SendFailed,
    /// The connection dropped before the whole response arrived.
    ConnectionDropped,
    /// The response broke HTTP: malformed headers or chunks, or an unsupported encoding.
    BadResponse,
    /// The service redirected. Redirects are refused, so the token stays with the Chat Service.
    Redirected,
    /// The JSON didn't have the shape the client expects; the service may have changed it.
    UnexpectedJson,
    OutOfMemory,
};

/// Big enough for a full page of HTML-heavy messages; anything larger is refused, not truncated.
const body_size_max = 8 * 1024 * 1024;

/// Keeps each response bounded; larger counts take more pages.
const page_item_count_limit = 200;

/// Bounds how many pages `messages` follows. The service can send empty pages that still link to
/// older ones, so the page count isn't tied to the message count.
const page_count_limit = 64;

/// The most messages `messages` can ever collect.
pub const message_count_limit = page_item_count_limit * page_count_limit;

/// Teams refuses messages much past 28 KB of HTML; callers check before sending.
pub const content_size_max = 28 * 1024;

/// The newest message id `send` accepts: a day before the end of 9999, so the time shown for it
/// fits a four-digit year in every zone. Checked against the display's own bound in main.
pub const message_id_max = 253_402_300_799_999 - std.time.ms_per_day;

/// A message to send. A struct, so the two strings can't be swapped at a call site.
pub const NewMessage = struct {
    /// The message's HTML (see `teams_html`), at most `content_size_max` bytes.
    content: []const u8,
    /// Your name, shown as the sender.
    display_name: []const u8,
};

/// What a request carries: nothing, for a GET, or JSON, for a POST.
const Payload = union(enum) {
    none,
    json: []u8,
};

pub fn init(
    client: *Client,
    gpa: std.mem.Allocator,
    io: std.Io,
    region: Region,
    skype_token: []const u8,
) error{OutOfMemory}!void {
    std.debug.assert(skype_token.len > 0);
    // The token goes into a header, where a line break would end it early.
    std.debug.assert(std.mem.indexOfAny(u8, skype_token, "\r\n") == null);

    const authentication = try std.fmt.allocPrint(gpa, "skypetoken={s}", .{skype_token});
    errdefer {
        std.crypto.secureZero(u8, authentication);
        gpa.free(authentication);
    }

    client.* = .{
        .gpa = gpa,
        // Configuration spelled out; the connection pool and CA bundle are state, left to std.
        // No TLS key log: it would let anyone reading it decrypt the token.
        .http = .{
            .allocator = gpa,
            .io = io,
            .tls_buffer_size = std.crypto.tls.Client.min_buffer_len,
            .ssl_key_log = null,
            // std's defaults. The read buffer also bounds a response head, and Chat Service
            // heads fit in 8 KiB.
            .read_buffer_size = 8192,
            .write_buffer_size = 1024,
            // Null: std reads the clock and rescans root certificates on the first HTTPS request.
            .now = null,
            .http_proxy = null,
            .https_proxy = null,
        },
        .region = region,
        .authentication = authentication,
        .body_buffer = try gpa.alloc(u8, body_size_max),
        .decompress_window = undefined,
    };
    errdefer gpa.free(client.body_buffer);
    client.decompress_window = try gpa.alloc(u8, std.compress.flate.max_window_len);
}

pub fn deinit(client: *Client) void {
    client.http.deinit();
    // It holds the token: zero our copy. std's connection buffers keep their own until exit.
    std.crypto.secureZero(u8, client.authentication);
    client.gpa.free(client.authentication);
    client.gpa.free(client.body_buffer);
    client.gpa.free(client.decompress_window);
    client.* = undefined;
}

/// GETs `path` (starting with `/`) under the Chat Service base URL.
/// The body is borrowed: it's valid until the next request.
pub fn get(client: *Client, path: []const u8) Error![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, path, "/"));

    const url = try std.mem.concat(client.gpa, u8, &.{ client.region.baseUrl(), path });
    defer client.gpa.free(url);

    return client.getUrl(url);
}

/// GETs a full URL, such as a pagination link the service sent. It must be under the base URL.
/// The body is borrowed: it's valid until the next request.
pub fn getUrl(client: *Client, url: []const u8) Error![]const u8 {
    // Cleared first, so a status only ever describes this request.
    client.response_status = null;
    const uri = try checkLink(client.region, url);
    return client.fetch(uri, &.none);
}

/// POSTs `payload`, JSON, to `path` (starting with `/`) under the base URL. Never retried: after a
/// lost answer the service may already have acted, and a second try could act twice.
/// The body is borrowed: it's valid until the next request.
fn post(client: *Client, path: []const u8, payload: []u8) Error![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, path, "/"));
    std.debug.assert(payload.len > 0);
    client.response_status = null;

    const url = try std.mem.concat(client.gpa, u8, &.{ client.region.baseUrl(), path });
    defer client.gpa.free(url);

    const uri = try checkLink(client.region, url);
    return client.fetch(uri, &.{ .json = payload });
}

/// One request to `uri`, a GET or a POST by `payload`. 200 and 201 are success.
/// The body is borrowed: it's valid until the next request.
fn fetch(client: *Client, uri: std.Uri, payload: *const Payload) Error![]const u8 {
    std.debug.assert(client.response_status == null);
    const method: std.http.Method, const content_type: std.http.Client.Request.Headers.Value =
        switch (payload.*) {
            .none => .{ .GET, .default },
            .json => .{ .POST, .{ .override = "application/json" } },
        };
    var request = client.http.request(method, uri, .{
        .version = .@"HTTP/1.1",
        .handle_continue = true,
        .keep_alive = true,
        // Redirects are refused so the token never leaves the Chat Service host. std would keep
        // extra headers across a cross-domain redirect, and in 0.17 it never sends
        // privileged_headers at all, so those can't carry the token instead.
        .redirect_behavior = .not_allowed,
        .connection = null,
        .headers = .{
            .host = .default,
            .authorization = .default,
            .user_agent = .default,
            .connection = .default,
            // Written out: std 0.17 writes a list of one encoding as a bare "accept-encoding" line
            // with no colon (it undoes the ", " of a list it never wrote), which gets a 400.
            .accept_encoding = .{ .override = "gzip, identity" },
            .content_type = content_type,
        },
        .extra_headers = &.{
            .{ .name = "Authentication", .value = client.authentication },
            .{ .name = "Accept", .value = "application/json" },
        },
        .privileged_headers = &.{},
    }) catch |err| return requestError(err);
    defer request.deinit();

    // gzip or none: receiveHead refuses any encoding not listed here, so `readBody` sees only
    // these two (std's zstd path would need a bigger window than the client keeps).
    request.accept_encoding = @splat(false);
    request.accept_encoding[@backingInt(std.http.ContentEncoding.identity)] = true;
    request.accept_encoding[@backingInt(std.http.ContentEncoding.gzip)] = true;

    switch (payload.*) {
        .none => request.sendBodiless() catch return error.SendFailed,
        .json => |bytes| request.sendBodyComplete(bytes) catch return error.SendFailed,
    }
    // Redirects are refused, so receiveHead never needs a redirect buffer.
    var response = request.receiveHead(&.{}) catch |err| return receiveHeadError(err);

    client.response_status = response.head.status;
    switch (response.head.status) {
        .ok, .created => {},
        .unauthorized => return error.TokenExpired,
        .not_found => return error.NotFound,
        else => return error.UnexpectedStatus,
    }

    const encoding = response.head.content_encoding;
    std.debug.assert(encoding == .identity or encoding == .gzip);

    var body: std.Io.Writer = .fixed(client.body_buffer);
    var transfer_buffer: [64]u8 = undefined;
    const transfer = response.reader(&transfer_buffer);
    // Read here rather than through fetch: fetch unwraps bodyErr() on ReadFailed, which is null
    // when the connection drops mid-body, and crashes.
    readBody(transfer, encoding, client.decompress_window, &body) catch |err| switch (err) {
        error.ReadFailed => return bodyError(error.ReadFailed, response.bodyErr()),
        else => |other| return other,
    };

    try bodyEndCheck(request.reader.state);
    return body.buffered();
}

/// How reading a body fails. ReadFailed is the transfer's own failure, which `bodyError` sorts
/// out from the response.
const ReadBodyError = error{ ResponseTooLarge, BadResponse, ConnectionDropped, ReadFailed };

/// Reads the whole body from `transfer` into `body`, decompressing a gzip body through `window`.
/// The limit is `body`'s size, on the decompressed bytes.
fn readBody(
    transfer: *std.Io.Reader,
    encoding: std.http.ContentEncoding,
    window: []u8,
    body: *std.Io.Writer,
) ReadBodyError!void {
    std.debug.assert(encoding == .identity or encoding == .gzip);
    std.debug.assert(window.len >= std.compress.flate.max_window_len);
    var decompress: std.http.Decompress = undefined;
    const reader = decompress.init(transfer, window, encoding);
    _ = reader.streamRemaining(body) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseTooLarge,
        error.ReadFailed => {
            // Identity: only the transfer can fail. gzip: the transfer, or the data itself.
            if (decompress != .flate) return error.ReadFailed;
            const flate_err = decompress.flate.err orelse return error.ReadFailed;
            return switch (flate_err) {
                error.ReadFailed => error.ReadFailed,
                // The body ended before the gzip stream did.
                error.EndOfStream => error.ConnectionDropped,
                else => error.BadResponse,
            };
        },
    };
    // The decompressor stops at the end of the gzip data, before its footer and a chunked body's
    // last chunk. Reading the rest leaves the connection ready for the next request.
    if (decompress == .flate) {
        _ = transfer.discardRemaining() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

/// Parses `url` if it's safe to send the token to: under the region's base URL, and free of
/// bytes that don't belong on a request line.
fn checkLink(region: Region, url: []const u8) error{ForeignLink}!std.Uri {
    const base = region.baseUrl();
    if (!std.mem.startsWith(u8, url, base)) return error.ForeignLink;
    if (!std.mem.startsWith(u8, url[base.len..], "/")) return error.ForeignLink;

    // std writes the path and query onto the request line as given, so a link carrying spaces,
    // control bytes or non-ASCII could add headers or a second request.
    for (url) |byte| {
        if (byte <= ' ') return error.ForeignLink;
        if (byte >= 0x7f) return error.ForeignLink;
    }
    // The checks above pin the scheme and authority to the base URL's, and std.Uri.parse only
    // fails on those two parts, so it can't fail here.
    return std.Uri.parse(url) catch unreachable;
}

/// After a clean read, says whether the whole body arrived. A clean close mid-body reads as the
/// end of the stream, so a content length not yet met means the connection dropped.
fn bodyEndCheck(state: std.http.Reader.State) error{ConnectionDropped}!void {
    switch (state) {
        .ready => {},
        // No length to check against: the body runs until the server closes the connection.
        .body_none => {},
        .body_remaining_content_length => return error.ConnectionDropped,
        // streamRemaining only ends cleanly in the states above, and a client never closes.
        .received_head, .body_remaining_chunk_len, .closing => unreachable,
    }
}

/// Name lookup, TCP and TLS failures, and failing to load the system's root certificates, all
/// mean the Chat Service couldn't be reached.
fn requestError(err: std.http.Client.RequestError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ConnectFailed,
    };
}

fn receiveHeadError(err: std.http.Client.Request.ReceiveHeadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyHttpRedirects => error.Redirected,
        error.ReadFailed, error.HttpRequestTruncated, error.HttpConnectionClosing => {
            return error.ConnectionDropped;
        },
        error.WriteFailed => error.SendFailed,
        else => error.BadResponse,
    };
}

/// The body writer is a fixed buffer, so its only failure is running out of room. A read failure
/// with no body error is a socket or TLS failure; a truncated chunk is a dropped connection too;
/// other body errors mean the server broke HTTP.
fn bodyError(err: std.Io.Reader.StreamRemainingError, body_err: ?std.http.Reader.BodyError) Error {
    return switch (err) {
        error.WriteFailed => error.ResponseTooLarge,
        error.ReadFailed => {
            const reason = body_err orelse return error.ConnectionDropped;
            return switch (reason) {
                error.HttpChunkTruncated => error.ConnectionDropped,
                error.HttpChunkInvalid, error.HttpHeadersOversize => error.BadResponse,
            };
        },
    };
}

/// Running out of memory stays itself; any other parse failure means the JSON's shape changed.
fn parseError(err: json.ParseError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnexpectedJson,
    };
}

/// Posts `message` to a conversation, once. Returns the new message's id: its arrival time in
/// milliseconds.
pub fn send(client: *Client, conversation_id: []const u8, message: *const NewMessage) Error!u64 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(message.content.len > 0);
    std.debug.assert(message.content.len <= content_size_max);

    const path = try sendPath(client.gpa, conversation_id);
    defer client.gpa.free(path);

    const client_message_id: u64 = @intCast(std.Io.Clock.real.now(client.http.io).toMilliseconds());
    const payload = try sendPayload(client.gpa, message, client_message_id);
    defer client.gpa.free(payload);

    const body = try client.post(path, payload);
    return sendAnswerId(client.gpa, body);
}

/// `/users/ME/conversations/{id}/messages` with the id percent-encoded. Owned by the caller.
fn sendPath(gpa: std.mem.Allocator, conversation_id: []const u8) error{OutOfMemory}![]u8 {
    var path: std.Io.Writer.Allocating = .init(gpa);
    errdefer path.deinit();

    // An Allocating writer fails only when it can't grow, so every writer error here is OOM.
    const writer = &path.writer;
    writer.writeAll("/users/ME/conversations/") catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(writer, conversation_id, isUnreserved) catch
        return error.OutOfMemory;
    writer.writeAll("/messages") catch return error.OutOfMemory;
    return path.toOwnedSlice();
}

/// The JSON body of a send. `client_message_id` lets the service tell this message from others;
/// any fresh number does. Owned by the caller.
fn sendPayload(
    gpa: std.mem.Allocator,
    message: *const NewMessage,
    client_message_id: u64,
) error{OutOfMemory}![]u8 {
    // Sized for the longest u64, so the number always fits.
    var client_message_id_buffer: [std.fmt.count("{d}", .{std.math.maxInt(u64)})]u8 = undefined;
    const client_message_id_text = std.fmt.bufPrint(
        &client_message_id_buffer,
        "{d}",
        .{client_message_id},
    ) catch unreachable;
    const body = .{
        .content = message.content,
        .messagetype = "RichText/Html",
        .contenttype = "text",
        .clientmessageid = client_message_id_text,
        .imdisplayname = message.display_name,
    };
    return std.json.Stringify.valueAlloc(gpa, body, json.stringify_options);
}

/// The new message's id from a send's answer, `{"OriginalArrivalTime": <ms>, ...}`. An id from
/// before 1970-01-02 or after `message_id_max` means the answer isn't what it should be.
fn sendAnswerId(gpa: std.mem.Allocator, body: []const u8) Error!u64 {
    const Answer = struct { OriginalArrivalTime: u64 };
    const parsed = std.json.parseFromSlice(Answer, gpa, body, json.parse_options) catch |err|
        return parseError(err);
    defer parsed.deinit();
    if (parsed.value.OriginalArrivalTime < std.time.ms_per_day) return error.UnexpectedJson;
    if (parsed.value.OriginalArrivalTime > message_id_max) return error.UnexpectedJson;
    return parsed.value.OriginalArrivalTime;
}

/// Returns the signed-in user, owned by the caller: free it with `User.deinit`.
pub fn whoami(client: *Client) Error!User {
    const body = try client.get("/users/ME/properties");
    return User.parse(client.gpa, body) catch |err| parseError(err);
}

/// Returns up to `conversation_count_max` of your most recent conversations, newest first,
/// without system streams. The result is owned by the caller: free it with `List.deinit`.
pub fn conversations(
    client: *Client,
    conversation_count_max: u16,
) Error!Conversation.List {
    std.debug.assert(conversation_count_max > 0);
    std.debug.assert(conversation_count_max <= page_item_count_limit);

    const path_prefix = "/users/ME/conversations?view=mychats&pageSize=";
    // Sized for the largest count the assert above allows, so the formatted path always fits.
    const path_size_max = comptime path_prefix.len + std.fmt.count("{d}", .{page_item_count_limit});
    var path_buffer: [path_size_max]u8 = undefined;
    const path_format = path_prefix ++ "{d}";
    const path = std.fmt.bufPrint(&path_buffer, path_format, .{conversation_count_max}) catch
        unreachable;

    const body = try client.get(path);
    var list = Conversation.parseList(client.gpa, body) catch |err| return parseError(err);
    // The page size is a request, so a service sending more mustn't overrun callers' buffers.
    list.items = list.items[0..@min(list.items.len, conversation_count_max)];
    return list;
}

/// Returns up to `message_count_max` of a conversation's messages, newest first, following older
/// pages as needed. Stops early after `page_count_limit` pages, returning what it has.
/// The result is owned by the caller: free it with `List.deinit`.
pub fn messages(
    client: *Client,
    conversation_id: []const u8,
    message_count_max: u32,
) Error!Message.List {
    return client.fetchMessages(conversation_id, message_count_max, page_count_limit);
}

/// Like `messages`, but reads only the newest page, so it always costs exactly one request.
pub fn recentMessages(
    client: *Client,
    conversation_id: []const u8,
    message_count_max: u32,
) Error!Message.List {
    std.debug.assert(message_count_max <= page_item_count_limit);
    return client.fetchMessages(conversation_id, message_count_max, 1);
}

fn fetchMessages(
    client: *Client,
    conversation_id: []const u8,
    message_count_max: u32,
    page_count_max: u32,
) Error!Message.List {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(message_count_max > 0);
    // page_count_limit pages can't hold more, so a larger count would only reserve dead memory.
    std.debug.assert(message_count_max <= message_count_limit);
    const page_item_count = @min(message_count_max, page_item_count_limit);

    var list: Message.List = try .init(client.gpa);
    errdefer list.deinit();

    const url_first = try client.messagesUrl(conversation_id, page_item_count);
    defer client.gpa.free(url_first);

    const arena = list.arena.allocator();
    list.items = try collectMessages(arena, client, url_first, message_count_max, page_count_max);
    return list;
}

/// Walks pages from `url_first` through each `backwardLink`, keeping up to `message_count_max`
/// messages, and stops after `page_count_max` pages. `source.getUrl(url)` returns a page body,
/// borrowed until its next call: the Client in use, a canned source in tests.
fn collectMessages(
    arena: std.mem.Allocator,
    source: anytype,
    url_first: []const u8,
    message_count_max: u32,
    page_count_max: u32,
) Error![]const Message {
    std.debug.assert(url_first.len > 0);
    std.debug.assert(message_count_max > 0);
    std.debug.assert(message_count_max <= message_count_limit);
    std.debug.assert(page_count_max > 0);
    std.debug.assert(page_count_max <= page_count_limit);

    var items: std.ArrayList(Message) = try .initCapacity(arena, message_count_max);
    var link: ?[]const u8 = url_first;
    var page_count: u32 = 0;
    while (link) |page_url| : (page_count += 1) {
        if (items.items.len == message_count_max) break;
        if (page_count == page_count_max) break;

        const body = try source.getUrl(page_url);
        const page = Message.parsePage(arena, body) catch |err| return parseError(err);
        const room_count = message_count_max - items.items.len;
        items.appendSliceAssumeCapacity(page.items[0..@min(page.items.len, room_count)]);
        link = page.backward_link;
    }
    std.debug.assert(items.items.len <= message_count_max);
    std.debug.assert(page_count <= page_count_max);

    return items.items;
}

/// The first messages page for a conversation, with the id percent-encoded. Owned by the caller.
fn messagesUrl(
    client: *const Client,
    conversation_id: []const u8,
    page_item_count: u32,
) error{OutOfMemory}![]u8 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(page_item_count > 0);
    std.debug.assert(page_item_count <= page_item_count_limit);

    var url: std.Io.Writer.Allocating = .init(client.gpa);
    errdefer url.deinit();

    const writer = &url.writer;
    const base = client.region.baseUrl();
    // An Allocating writer fails only when it can't grow, so every writer error here is OOM.
    writer.print("{s}/users/ME/conversations/", .{base}) catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(writer, conversation_id, isUnreserved) catch
        return error.OutOfMemory;
    writer.print("/messages?view=superchat&pageSize={d}", .{page_item_count}) catch
        return error.OutOfMemory;

    const result = try url.toOwnedSlice();
    std.debug.assert(std.mem.startsWith(u8, result, base));
    return result;
}

fn isUnreserved(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

test "baseUrl puts the region in the host" {
    const expected = "https://emea.ng.msg.teams.microsoft.com/v1";
    try std.testing.expectEqualStrings(expected, Region.emea.baseUrl());
}

test "messagesUrl percent-encodes the conversation id" {
    var client: Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();

    const url = try client.messagesUrl("19:fake@thread.v2", 50);
    defer std.testing.allocator.free(url);

    const expected = "https://emea.ng.msg.teams.microsoft.com/v1/users/ME/conversations/" ++
        "19%3Afake%40thread.v2/messages?view=superchat&pageSize=50";
    try std.testing.expectEqualStrings(expected, url);
}

test "getUrl refuses links outside the Chat Service base URL" {
    var client: Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .emea, "fake-token");
    defer client.deinit();

    const foreign_urls = [_][]const u8{
        "https://example.com/v1/users/ME",
        "https://emea.ng.msg.teams.microsoft.com/v1.evil.com/x",
        "https://emea.ng.msg.teams.microsoft.com/v1",
        "https://amer.ng.msg.teams.microsoft.com/v1/users/ME",
        "https://emea.ng.msg.teams.microsoft.com/v1/x\r\nX-Injected: 1",
        "https://emea.ng.msg.teams.microsoft.com/v1/x HTTP/1.1",
        "https://emea.ng.msg.teams.microsoft.com/v1/caf\xc3\xa9",
    };
    for (foreign_urls) |foreign_url| {
        try std.testing.expectError(error.ForeignLink, client.getUrl(foreign_url));
    }
}

test "the Authentication header carries the skypetoken prefix" {
    var client: Client = undefined;
    try client.init(std.testing.allocator, std.testing.io, .amer, "fake-token");
    defer client.deinit();

    try std.testing.expectEqualStrings("skypetoken=fake-token", client.authentication);
}

/// Serves canned page bodies in order, repeating the last one, and counts the requests.
const CannedPages = struct {
    /// Borrowed: the canned bodies must outlive the source.
    bodies: []const []const u8,
    request_count: u32 = 0,

    fn getUrl(pages: *CannedPages, url: []const u8) Error![]const u8 {
        _ = url;
        std.debug.assert(pages.bodies.len > 0);
        const index = @min(pages.request_count, pages.bodies.len - 1);
        pages.request_count += 1;
        return pages.bodies[index];
    }
};

const canned_empty_with_link =
    \\{"_metadata":{"backwardLink":"https://x/older"},"messages":[]}
;
const canned_two_with_link =
    \\{"_metadata":{"backwardLink":"https://x/older"},"messages":[
    \\ {"id":"2","messagetype":"Text","originalarrivaltime":"2026-11-01T10:00:02Z"},
    \\ {"id":"1","messagetype":"Text","originalarrivaltime":"2026-11-01T10:00:01Z"}]}
;
const canned_one_oldest =
    \\{"_metadata":{"backwardLink":null},"messages":[
    \\ {"id":"0","messagetype":"Text","originalarrivaltime":"2026-11-01T10:00:00Z"}]}
;

test "collectMessages keeps going past empty pages that link to older ones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{
        .bodies = &.{ canned_empty_with_link, canned_empty_with_link, canned_one_oldest },
    };
    const items = try collectMessages(
        arena.allocator(),
        &pages,
        "https://x/first",
        50,
        page_count_limit,
    );
    try std.testing.expectEqual(1, items.len);
    try std.testing.expectEqualStrings("0", items[0].id);
    try std.testing.expectEqual(3, pages.request_count);
}

test "collectMessages stops at the message count without fetching further" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{ .bodies = &.{ canned_two_with_link, canned_two_with_link } };
    const items = try collectMessages(
        arena.allocator(),
        &pages,
        "https://x/first",
        3,
        page_count_limit,
    );
    try std.testing.expectEqual(3, items.len);
    try std.testing.expectEqual(2, pages.request_count);
}

test "collectMessages stops after page_count_limit endless empty pages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{ .bodies = &.{canned_empty_with_link} };
    const items = try collectMessages(
        arena.allocator(),
        &pages,
        "https://x/first",
        50,
        page_count_limit,
    );
    try std.testing.expectEqual(0, items.len);
    try std.testing.expectEqual(page_count_limit, pages.request_count);
}

test "bodyError tells a dropped connection from a broken chunk and a full buffer" {
    try std.testing.expectEqual(error.ConnectionDropped, bodyError(error.ReadFailed, null));
    const broken_chunk = bodyError(error.ReadFailed, error.HttpChunkInvalid);
    try std.testing.expectEqual(error.BadResponse, broken_chunk);
    try std.testing.expectEqual(error.ResponseTooLarge, bodyError(error.WriteFailed, null));
    const truncated_chunk = bodyError(error.ReadFailed, error.HttpChunkTruncated);
    try std.testing.expectEqual(error.ConnectionDropped, truncated_chunk);
}

test "request and head errors map to what the user can act on" {
    try std.testing.expectEqual(error.ConnectFailed, requestError(error.TlsInitializationFailed));
    try std.testing.expectEqual(error.OutOfMemory, requestError(error.OutOfMemory));
    try std.testing.expectEqual(error.Redirected, receiveHeadError(error.TooManyHttpRedirects));
    try std.testing.expectEqual(error.ConnectionDropped, receiveHeadError(error.ReadFailed));
    try std.testing.expectEqual(error.SendFailed, receiveHeadError(error.WriteFailed));
    try std.testing.expectEqual(error.BadResponse, receiveHeadError(error.HttpHeadersInvalid));
}

test "parse errors other than running out of memory mean unexpected JSON" {
    try std.testing.expectEqual(error.UnexpectedJson, parseError(error.MissingField));
    try std.testing.expectEqual(error.OutOfMemory, parseError(error.OutOfMemory));
}

test "bodyEndCheck catches a body short of its content length" {
    try bodyEndCheck(.ready);
    try bodyEndCheck(.body_none);
    const short = bodyEndCheck(.{ .body_remaining_content_length = 10 });
    try std.testing.expectError(error.ConnectionDropped, short);
}

test "checkLink parses a link under the base URL" {
    const link = "https://emea.ng.msg.teams.microsoft.com/v1/users/ME/messages?startTime=1";
    const uri = try checkLink(.emea, link);
    try std.testing.expectEqualStrings("https", uri.scheme);
    const host = uri.host.?.percent_encoded;
    try std.testing.expectEqualStrings("emea.ng.msg.teams.microsoft.com", host);
}

test "collectMessages reads one page when limited to one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var pages: CannedPages = .{ .bodies = &.{ canned_empty_with_link, canned_one_oldest } };
    const items = try collectMessages(arena.allocator(), &pages, "https://x/first", 50, 1);
    try std.testing.expectEqual(0, items.len);
    try std.testing.expectEqual(1, pages.request_count);
}

test "sendPath percent-encodes the conversation id" {
    const path = try sendPath(std.testing.allocator, "48:notes");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/users/ME/conversations/48%3Anotes/messages", path);
}

test "sendPayload writes the fields Teams expects, escaped as JSON" {
    const message: NewMessage = .{
        .content = "<p>fake \"one\"</p>",
        .display_name = "Fake Person",
    };
    const payload = try sendPayload(std.testing.allocator, &message, 1_700_000_000_000);
    defer std.testing.allocator.free(payload);

    const expected = "{\"content\":\"<p>fake \\\"one\\\"</p>\"," ++
        "\"messagetype\":\"RichText/Html\",\"contenttype\":\"text\"," ++
        "\"clientmessageid\":\"1700000000000\",\"imdisplayname\":\"Fake Person\"}";
    try std.testing.expectEqualStrings(expected, payload);
}

test "sendAnswerId reads the new message's id and rejects other shapes" {
    const body = "{\"OriginalArrivalTime\":1700000000000,\"other\":1}";
    try std.testing.expectEqual(1_700_000_000_000, try sendAnswerId(std.testing.allocator, body));
    const no_id = sendAnswerId(std.testing.allocator, "{}");
    try std.testing.expectError(error.UnexpectedJson, no_id);
    const early_id = sendAnswerId(std.testing.allocator, "{\"OriginalArrivalTime\":0}");
    try std.testing.expectError(error.UnexpectedJson, early_id);
    const last_body = "{\"OriginalArrivalTime\":253402214399999}";
    try std.testing.expectEqual(message_id_max, try sendAnswerId(std.testing.allocator, last_body));
    const late_body = "{\"OriginalArrivalTime\":253402214400000}";
    const late_id = sendAnswerId(std.testing.allocator, late_body);
    try std.testing.expectError(error.UnexpectedJson, late_id);
}

/// `{"fake":"gzip body"}`, gzipped.
const fake_gzip_body =
    "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\xab\x56\x4a\x4b\xcc\x4e\x55\xb2\x52\x4a\xaf\xca" ++
    "\x2c\x50\x48\xca\x4f\xa9\x54\xaa\x05\x00\x07\xd3\x31\x79\x14\x00\x00\x00";

/// Runs `readBody` over `transfer_bytes` into a body buffer of `body_size` bytes.
fn expectReadBody(
    transfer_bytes: []const u8,
    encoding: std.http.ContentEncoding,
    body_size: u32,
    expected: ReadBodyError![]const u8,
) !void {
    var transfer: std.Io.Reader = .fixed(transfer_bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const body_buffer = try std.testing.allocator.alloc(u8, body_size);
    defer std.testing.allocator.free(body_buffer);
    var body: std.Io.Writer = .fixed(body_buffer);

    const result = readBody(&transfer, encoding, &window, &body);
    const expected_body = expected catch |expected_err| {
        return std.testing.expectError(expected_err, result);
    };
    try result;
    try std.testing.expectEqualStrings(expected_body, body.buffered());
}

test "readBody decompresses gzip and passes identity through" {
    try expectReadBody(fake_gzip_body, .gzip, 64, "{\"fake\":\"gzip body\"}");
    try expectReadBody("{\"fake\":1}", .identity, 64, "{\"fake\":1}");
}

test "readBody refuses a body larger than the buffer once decompressed" {
    try expectReadBody(fake_gzip_body, .gzip, 8, error.ResponseTooLarge);
    try expectReadBody("{\"fake\":1}", .identity, 4, error.ResponseTooLarge);
}

test "readBody calls a bad gzip header bad, and a cut body dropped" {
    // A wrong magic number in the header. (std 0.17 doesn't check the footer's checksum; TLS
    // already guards the bytes on the way.)
    var wrong_header = fake_gzip_body.*;
    wrong_header[0] ^= 0xff;
    try expectReadBody(&wrong_header, .gzip, 64, error.BadResponse);
    try expectReadBody(fake_gzip_body[0..20], .gzip, 64, error.ConnectionDropped);
}

test "readBody reads a chunked gzip body to its end, so the connection is ready again" {
    // As the Chat Service sends it: one chunk of gzip, then the last, empty chunk.
    const chunked = std.fmt.comptimePrint("{x}\r\n", .{fake_gzip_body.len}) ++ fake_gzip_body ++
        "\r\n0\r\n\r\n";
    var input: std.Io.Reader = .fixed(chunked);
    var http_reader: std.http.Reader = .{
        .in = &input,
        .interface = undefined,
        .state = .received_head,
        .max_head_len = 0,
        .side = .response,
    };
    var transfer_buffer: [64]u8 = undefined;
    const transfer = http_reader.bodyReader(&transfer_buffer, .chunked, null);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var body_buffer: [64]u8 = undefined;
    var body: std.Io.Writer = .fixed(&body_buffer);

    try readBody(transfer, .gzip, &window, &body);
    try std.testing.expectEqualStrings("{\"fake\":\"gzip body\"}", body.buffered());
    try std.testing.expectEqual(.ready, http_reader.state);
}
