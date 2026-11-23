//! The MCP server behind `teams-zig mcp`: JSON-RPC 2.0 requests, one per line on `reader`, each
//! answered with one line on `writer`, as MCP's stdio transport has it.

const std = @import("std");
const Io = std.Io;
const teams = @import("teams");
const json = teams.chat.json;

const Server = @This();

gpa: std.mem.Allocator,
/// Its buffer's size is the longest request line taken (see `request_size_max`).
reader: *Io.Reader,
writer: *Io.Writer,

/// The longest request line, the size `main` gives the stdin reader's buffer. A `send` of 16 KiB
/// can grow about six times with JSON escapes, so this leaves room.
pub const request_size_max = 256 * 1024;

pub const Error = Io.Writer.Error || error{ ReadFailed, OutOfMemory };

/// JSON-RPC's error codes, as MCP uses them.
const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
};

/// A request's id, echoed in its answer. MCP never uses null.
const Id = union(enum) {
    number: i64,
    string: []const u8,

    /// `value` as an id, if it is one of the kinds MCP allows. Borrows `value`.
    fn fromJson(value: std.json.Value) ?Id {
        return switch (value) {
            .integer => |number| .{ .number = number },
            .string => |string| .{ .string = string },
            else => null,
        };
    }

    pub fn jsonStringify(id: Id, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (id) {
            .number => |number| try writer.write(number),
            .string => |string| try writer.write(string),
        }
    }
};

/// Answers every request until `reader` ends.
pub fn serve(server: *Server) Error!void {
    // Holds each request while it is answered.
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const line = server.reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => {
                try server.skipLongLine();
                continue;
            },
        } orelse return;
        try server.answer(arena_state.allocator(), line);
    }
}

/// Drops the rest of a line too long for the reader's buffer, and answers it as unreadable.
fn skipLongLine(server: *Server) Error!void {
    _ = server.reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        // The last line had no newline; it still gets its answer.
        error.EndOfStream => {},
    };
    try server.answerError(null, .parse_error, "Parse error: the request line is too long");
}

fn answer(server: *Server, arena: std.mem.Allocator, line: []const u8) Error!void {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = true,
        .max_value_len = null,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return server.answerError(null, .parse_error, "Parse error"),
    };
    const request = Request.parse(value) catch |err| switch (err) {
        error.InvalidRequest => {
            return server.answerError(Request.readId(value), .invalid_request, "Invalid Request");
        },
    };
    // Notifications get no answer.
    const id = request.id orelse return;
    return server.answerError(id, .method_not_found, "Method not found");
}

/// A JSON-RPC request's envelope: `{"jsonrpc":"2.0","id":…,"method":…,"params":{…}}`.
const Request = struct {
    /// Null for a notification.
    id: ?Id,
    method: []const u8,
    /// Empty when the request has none.
    params: std.json.ObjectMap,

    /// Borrows `value`.
    fn parse(value: std.json.Value) error{InvalidRequest}!Request {
        // A batch (an array) is no longer part of JSON-RPC as MCP uses it.
        if (value != .object) return error.InvalidRequest;
        const object = value.object;

        const version = object.get("jsonrpc") orelse return error.InvalidRequest;
        if (version != .string) return error.InvalidRequest;
        if (!std.mem.eql(u8, version.string, "2.0")) return error.InvalidRequest;

        const method = object.get("method") orelse return error.InvalidRequest;
        if (method != .string) return error.InvalidRequest;

        const id: ?Id = if (object.get("id")) |id_value|
            Id.fromJson(id_value) orelse return error.InvalidRequest
        else
            null;

        const params: std.json.ObjectMap = if (object.get("params")) |params| switch (params) {
            .object => |params_object| params_object,
            else => return error.InvalidRequest,
        } else .empty;

        return .{ .id = id, .method = method.string, .params = params };
    }

    /// The id of a request that `parse` refuses, if it can be read, for its error answer.
    fn readId(value: std.json.Value) ?Id {
        if (value != .object) return null;
        return Id.fromJson(value.object.get("id") orelse return null);
    }
};

/// Writes a JSON-RPC error answer as one line. `id` is null when the request's id can't be read.
fn answerError(server: *Server, id: ?Id, code: ErrorCode, message: []const u8) Error!void {
    const Answer = struct {
        jsonrpc: []const u8 = "2.0",
        id: ?Id,
        @"error": struct { code: i32, message: []const u8 },
    };
    const error_answer: Answer = .{ .id = id, .@"error" = .{
        .code = @backingInt(code),
        .message = message,
    } };
    try std.json.Stringify.value(error_answer, json.stringify_options, server.writer);
    try server.writer.writeByte('\n');
    try server.writer.flush();
}

/// Reads `source` through a buffer smaller than it, as stdin is read. (std.testing.ReaderIndirect
/// hangs once a line fills its buffer.)
const SliceReader = struct {
    source: []const u8,
    interface: Io.Reader,

    fn stream(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const slice_reader: *SliceReader = @alignCast(@fieldParentPtr("interface", reader));
        if (slice_reader.source.len == 0) return error.EndOfStream;
        const source = slice_reader.source;
        const written = try writer.write(source[0..limit.minInt(source.len)]);
        slice_reader.source = slice_reader.source[written..];
        return written;
    }
};

/// Runs `server` over `input` and checks that its answers are `expected`.
fn expectAnswers(input: []const u8, expected: []const u8) !void {
    var reader: Io.Reader = .fixed(input);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var server: Server = .{ .gpa = std.testing.allocator, .reader = &reader, .writer = &out.writer };
    try server.serve();
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an unknown method is answered with its id and -32601" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":7,"method":"fake/method"}
        \\{"jsonrpc":"2.0","id":"fake-id","method":"fake/method","params":{}}
        \\
    ,
        \\{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found"}}
        \\{"jsonrpc":"2.0","id":"fake-id","error":{"code":-32601,"message":"Method not found"}}
        \\
    );
}

test "a notification gets no answer" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","method":"notifications/fake"}
        \\
    , "");
}

test "a line that isn't JSON gets -32700 with a null id" {
    try expectAnswers(
        \\{"jsonrpc":"2.0","id":1,
        \\
    ,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
        \\
    );
}

test "a batch, a missing method or a wrong envelope gets -32600" {
    try expectAnswers(
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"}]
        \\{"jsonrpc":"2.0","id":2}
        \\{"jsonrpc":"1.0","id":3,"method":"ping"}
        \\{"jsonrpc":"2.0","id":4,"method":5}
        \\{"jsonrpc":"2.0","id":5,"method":"ping","params":[]}
        \\{"jsonrpc":"2.0","id":null,"method":"ping"}
        \\
    ,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":5,"error":{"code":-32600,"message":"Invalid Request"}}
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
        \\
    );
}

test "a line longer than the reader's buffer gets -32700 and is skipped to its newline" {
    const long_line: [100]u8 = @splat('x');
    var buffer: [64]u8 = undefined;
    var reader: SliceReader = .{
        .source = long_line ++ "\n" ++
            \\{"jsonrpc":"2.0","id":1,"method":"fake"}
            \\
        ++ long_line,
        .interface = .{ .vtable = &.{ .stream = SliceReader.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var server: Server = .{
        .gpa = std.testing.allocator,
        .reader = &reader.interface,
        .writer = &out.writer,
    };
    try server.serve();
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: the request line is too long"}}
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: the request line is too long"}}
        \\
    , out.written());
}
