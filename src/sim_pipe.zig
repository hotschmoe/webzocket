const std = @import("std");
const assert = @import("assert").assert;
const wire = @import("sim_wire.zig");

pub const capacity: u32 = 1 << 16;
pub const segments_max: u32 = 64;

const Segment = struct { length: u32, ready_at: u64 };

pub const Pipe = struct {
    data: [capacity]u8 = undefined,
    start: u32 = 0,
    end: u32 = 0,
    segments: [segments_max]Segment = undefined,
    segment_head: u32 = 0,
    segment_count: u32 = 0,
    written: u64 = 0,
    delivered: u64 = 0,
    scanner: wire.Scanner = .{},
    dead: bool = false,

    pub fn reset(self: *Pipe) void {
        self.start = 0;
        self.end = 0;
        self.segment_head = 0;
        self.segment_count = 0;
        self.written = 0;
        self.delivered = 0;
        self.scanner = .{};
        self.dead = false;
        assert(self.pending() == 0 and self.written == 0);
        assert(!self.dead);
    }

    pub fn space(self: *const Pipe) u32 {
        assert(self.start <= self.end and self.end <= capacity);
        assert(self.segment_count <= segments_max);
        if (self.dead or self.segment_count == segments_max) return 0;
        return capacity - (self.end - self.start);
    }

    pub fn pending(self: *const Pipe) u32 {
        assert(self.start <= self.end);
        assert(self.end <= capacity);
        return self.end - self.start;
    }

    pub fn push(self: *Pipe, bytes: []const u8, ready_at: u64) void {
        assert(bytes.len > 0 and bytes.len <= self.space());
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
        if (capacity - self.end < bytes.len) {
            const held = self.end - self.start;
            std.mem.copyForwards(u8, self.data[0..held], self.data[self.start..self.end]);
            self.start = 0;
            self.end = held;
        }
        @memcpy(self.data[self.end..][0..bytes.len], bytes);
        self.end += @intCast(bytes.len);
        self.written += bytes.len;
        const slot = (self.segment_head + self.segment_count) % segments_max;
        self.segments[slot] = .{ .length = @intCast(bytes.len), .ready_at = ready_at };
        self.segment_count += 1;
        assert(self.segment_count <= segments_max and self.end <= capacity);
    }

    pub fn peek(self: *const Pipe, now: u64, limit: u32) ?[]const u8 {
        assert(self.segment_count <= segments_max);
        if (self.dead or self.segment_count == 0) return null;
        const head = self.segments[self.segment_head];
        if (head.ready_at > now or limit == 0) return null;
        assert(head.length <= self.end - self.start);
        return self.data[self.start..][0..@min(head.length, limit)];
    }

    pub fn consume(self: *Pipe, count: u32) void {
        assert(self.segment_count > 0);
        const head = &self.segments[self.segment_head];
        assert(count > 0 and count <= head.length);
        self.scanner.feed(self.data[self.start..][0..count]);
        self.start += count;
        self.delivered += count;
        head.length -= count;
        if (head.length == 0) {
            self.segment_head = (self.segment_head + 1) % segments_max;
            self.segment_count -= 1;
        }
        assert(self.start <= self.end and self.delivered <= self.written);
    }

    pub fn cut(self: *Pipe) void {
        assert(self.delivered <= self.written);
        self.dead = true;
        self.start = 0;
        self.end = 0;
        self.segment_count = 0;
        assert(self.dead and self.pending() == 0);
    }
};
