//! Times from the service, written short: `14:05` today, `Mon 14:05` this past week, and
//! `2026-10-12 14:05` before that. Callers pass local times, as seconds since 1970-01-01 in their
//! own zone, so this file never needs to know the zone.

const std = @import("std");

/// The widest form `write` produces.
pub const width_max = "2026-10-12 14:05".len;

/// Teams started in 2017; an earlier year means the field holds something else. Keeping years
/// recent also keeps every time, local or not, after 1970.
const year_min = 2000;

/// Seconds since 1970-01-01 GMT for a service timestamp such as `2026-11-01T10:00:00.000Z`, or
/// null if `text` isn't one. The fraction of a second is ignored.
pub fn parseIso(text: []const u8) ?i64 {
    const shape = "0000-00-00T00:00:00";
    if (text.len < shape.len + 1) return null;
    if (text[text.len - 1] != 'Z') return null;
    for (shape, text[0..shape.len]) |want, byte| {
        if (want == '0') {
            if (!std.ascii.isDigit(byte)) return null;
        } else {
            if (byte != want) return null;
        }
    }
    const fraction = text[shape.len .. text.len - 1];
    if (fraction.len > 0) {
        if (fraction[0] != '.') return null;
        for (fraction[1..]) |byte| {
            if (!std.ascii.isDigit(byte)) return null;
        }
    }

    // Every field is digits by now, so only the ranges can be wrong.
    const date: Date = .{
        .year = parseIsoNumber(text[0..4]),
        .month = parseIsoNumber(text[5..7]),
        .day = parseIsoNumber(text[8..10]),
    };
    const hour = parseIsoNumber(text[11..13]);
    const minute = parseIsoNumber(text[14..16]);
    const second = parseIsoNumber(text[17..19]);
    if (date.year < year_min) return null;
    if (date.month < 1) return null;
    if (date.month > 12) return null;
    if (date.day < 1) return null;
    if (date.day > 31) return null;
    if (hour > 23) return null;
    if (minute > 59) return null;
    // 60 is a leap second.
    if (second > 60) return null;

    const days = parseIsoDays(date);
    return days * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min +
        second;
}

/// Two local times, as seconds since 1970 in the reader's zone. A struct, so they can't be
/// swapped at a call site.
pub const Times = struct {
    at_seconds: i64,
    now_seconds: i64,
};

/// Writes `times.at_seconds` relative to `times.now_seconds`. A time in a later day than now (a
/// clock running behind the service's) gets the full date.
pub fn write(writer: *std.Io.Writer, times: Times) std.Io.Writer.Error!void {
    std.debug.assert(times.at_seconds >= 0);
    std.debug.assert(times.now_seconds >= 0);
    const day_at = @divFloor(times.at_seconds, std.time.s_per_day);
    const day_now = @divFloor(times.now_seconds, std.time.s_per_day);
    const seconds_in_day = @mod(times.at_seconds, std.time.s_per_day);
    const hour = @divFloor(seconds_in_day, std.time.s_per_hour);
    const minute = @divFloor(@mod(seconds_in_day, std.time.s_per_hour), std.time.s_per_min);

    if (day_at != day_now) {
        // A negative count is a time in a later day; it gets the full date too.
        const days_ago = day_now - day_at;
        if (days_ago > 0) {
            if (days_ago <= 6) {
                try writeWeekday(writer, day_at);
            } else {
                try writeDate(writer, day_at);
            }
        } else {
            try writeDate(writer, day_at);
        }
    }
    try writer.print("{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(hour)), @as(u64, @intCast(minute)) });
}

fn writeWeekday(writer: *std.Io.Writer, day: i64) std.Io.Writer.Error!void {
    std.debug.assert(day >= 0);
    // 1970-01-01 was a Thursday.
    const weekday_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    try writer.writeAll(weekday_names[@intCast(@mod(day, 7))]);
    try writer.writeByte(' ');
}

fn writeDate(writer: *std.Io.Writer, day: i64) std.Io.Writer.Error!void {
    std.debug.assert(day >= 0);
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print("{d}-{d:0>2}-{d:0>2} ", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

/// Digits already checked: no sign, no overflow.
fn parseIsoNumber(digits: []const u8) i64 {
    std.debug.assert(digits.len <= 4);
    return std.fmt.parseUnsigned(i64, digits, 10) catch unreachable;
}

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

/// Days from 1970-01-01 to a date in the proleptic Gregorian calendar (Howard Hinnant's
/// `days_from_civil`). A day past the month's end, such as Feb 31, runs into the next month.
fn parseIsoDays(date: Date) i64 {
    std.debug.assert(date.year >= year_min);
    std.debug.assert(date.month >= 1);
    std.debug.assert(date.month <= 12);
    std.debug.assert(date.day >= 1);
    std.debug.assert(date.day <= 31);
    // Years start in March, so the leap day falls at the end of one.
    const march_year = if (date.month <= 2) date.year - 1 else date.year;
    const era = @divFloor(march_year, 400);
    const year_of_era = march_year - era * 400;
    const month_from_march = if (date.month > 2) date.month - 3 else date.month + 9;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + date.day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn expectWrite(expected: []const u8, times: Times) !void {
    var buffer: [width_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, times);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "parseIso reads the service's timestamps" {
    try std.testing.expectEqual(1_762_000_000, parseIso("2025-11-01T12:26:40.000Z").?);
    try std.testing.expectEqual(1_762_000_000, parseIso("2025-11-01T12:26:40Z").?);
    try std.testing.expectEqual(1_709_164_800, parseIso("2024-02-29T00:00:00.5Z").?);
    try std.testing.expectEqual(946_684_800, parseIso("2000-01-01T00:00:00.000Z").?);
}

test "parseIso rejects anything else" {
    const not_timestamps = [_][]const u8{
        "",
        "-",
        "2025-11-01T12:26:40.000",
        "2025-11-01T12:26:40.000+01:00",
        "2025-11-01 12:26:40Z",
        "2025-13-01T12:26:40Z",
        "2025-11-00T12:26:40Z",
        "2025-11-01T24:00:00Z",
        "2025-11-01T12:26:40.Z1",
        "1999-12-31T23:59:59Z",
        "+025-11-01T12:26:40Z",
    };
    for (not_timestamps) |text| try std.testing.expectEqual(null, parseIso(text));
}

test "write shortens by how long ago" {
    // 2025-11-01 12:26:40 is a Saturday.
    const at = 1_762_000_000;
    const hour = std.time.s_per_hour;
    const day = std.time.s_per_day;
    try expectWrite("12:26", .{ .at_seconds = at, .now_seconds = at });
    try expectWrite("12:26", .{ .at_seconds = at, .now_seconds = at + 11 * hour });
    try expectWrite("Sat 12:26", .{ .at_seconds = at, .now_seconds = at + 12 * hour });
    try expectWrite("Sat 12:26", .{ .at_seconds = at, .now_seconds = at + 6 * day });
    try expectWrite("2025-11-01 12:26", .{ .at_seconds = at, .now_seconds = at + 7 * day });
    try expectWrite("2025-11-01 12:26", .{ .at_seconds = at, .now_seconds = at - day });
}

test "write handles midnight and leap days" {
    // 2024-02-29, a Thursday, at midnight.
    const at = 1_709_164_800;
    const day = std.time.s_per_day;
    try expectWrite("2024-02-29 00:00", .{ .at_seconds = at, .now_seconds = at + 30 * day });
    try expectWrite("Thu 00:00", .{ .at_seconds = at, .now_seconds = at + day });
}
