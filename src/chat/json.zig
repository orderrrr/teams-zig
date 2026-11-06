//! JSON settings shared by every Chat Service response.

const std = @import("std");

pub const ParseError = std.json.ParseError(std.json.Scanner);

/// Every option spelled out. Responses carry many fields we don't read, and parsed strings must
/// outlive the response body, so they're always copied. `max_value_len` null means the input
/// length, std's default for a slice: any body the client accepts parses.
pub const parse_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .@"error",
    .ignore_unknown_fields = true,
    .max_value_len = null,
    .allocate = .alloc_always,
};
