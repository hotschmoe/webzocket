const std = @import("std");
const assert = @import("assert").assert;

pub const Checker = enum(u8) {
    delivery,
    ping,
    close,
    quiet,
    error_class,
    determinism,
    canary,
    cross_old,
    eof,
    liveness,
    limits,
    handshake,
    chunking,
};
pub const checker_count = std.meta.fieldNames(Checker).len;

pub const Violation = error{Violation};

pub const Report = struct {
    text: [320]u8 = undefined,
    length: u32 = 0,
    checker: ?Checker = null,
    caught: [checker_count]u64 = @splat(0),

    pub fn fail(
        self: *Report,
        checker: Checker,
        comptime format: []const u8,
        args: anytype,
    ) Violation {
        const text = std.fmt.bufPrint(&self.text, format, args) catch self.text[0..self.text.len];
        self.length = @intCast(text.len);
        self.checker = checker;
        self.caught[@backingInt(checker)] += 1;
        assert(self.length <= self.text.len);
        assert(self.caught[@backingInt(checker)] > 0);
        return error.Violation;
    }

    pub fn message(self: *const Report) []const u8 {
        return self.text[0..self.length];
    }
};

pub fn Ring(comptime T: type, comptime capacity: u32) type {
    return struct {
        const Self = @This();
        items: [capacity]T = undefined,
        head: u32 = 0,
        count: u32 = 0,

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.count = 0;
            assert(self.head == 0);
            assert(self.count == 0);
        }

        pub fn is_full(self: *const Self) bool {
            return self.count == capacity;
        }

        pub fn push(self: *Self, item: T) void {
            assert(self.count < capacity);
            self.items[(self.head + self.count) % capacity] = item;
            self.count += 1;
            assert(self.count <= capacity and self.head < capacity);
        }

        pub fn front(self: *const Self) ?T {
            assert(self.count <= capacity);
            assert(self.head < capacity);
            if (self.count == 0) return null;
            return self.items[self.head];
        }

        pub fn at(self: *const Self, index: u32) T {
            assert(index < self.count);
            assert(self.count <= capacity);
            return self.items[(self.head + index) % capacity];
        }

        pub fn pop(self: *Self) void {
            assert(self.count > 0);
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            assert(self.count < capacity and self.head < capacity);
        }
    };
}

const canary: u8 = 0xc5;
const poison: u8 = 0x3d;
pub const guard: u32 = 16;

pub fn Region(comptime max: u32) type {
    return struct {
        const Self = @This();
        bytes: [guard + max + guard]u8 = undefined,
        declared: u32 = 0,

        pub fn arm(self: *Self, declared: u32) []u8 {
            assert(declared <= max);
            const total = guard + declared + guard;
            @memset(self.bytes[0..total], poison);
            @memset(self.bytes[0..guard], canary);
            @memset(self.bytes[guard + declared .. total], canary);
            self.declared = declared;
            const slice = self.bytes[guard..][0..declared];
            assert(slice.len == declared and self.intact());
            return slice;
        }

        pub fn intact(self: *const Self) bool {
            assert(self.declared <= max);
            const front_ok = std.mem.allEqual(u8, self.bytes[0..guard], canary);
            const tail = self.bytes[guard + self.declared ..][0..guard];
            assert(tail.len == guard);
            return front_ok and std.mem.allEqual(u8, tail, canary);
        }
    };
}

pub const Trace = struct {
    hasher: std.hash.Wyhash = std.hash.Wyhash.init(0x7261636573696d),
    events: u64 = 0,

    pub fn mix(self: *Trace, value: u64) void {
        assert(self.events < std.math.maxInt(u64));
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.hasher.update(&bytes);
        self.events += 1;
        assert(self.events > 0);
    }

    pub fn mix_bytes(self: *Trace, bytes: []const u8) void {
        assert(bytes.len <= 1 << 24);
        const before = self.events;
        self.mix(bytes.len);
        self.hasher.update(bytes);
        assert(self.events == before + 1);
    }

    pub fn digest(self: *const Trace) u64 {
        assert(self.events < std.math.maxInt(u64));
        var copy = self.hasher;
        const value = copy.final();
        assert(self.events > 0 or value == std.hash.Wyhash.hash(0x7261636573696d, ""));
        return value;
    }
};

pub fn hash_bytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}
