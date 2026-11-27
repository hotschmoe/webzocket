const std = @import("std");
const assert = @import("assert").assert;

pub const Tracking = struct {
    backing: std.mem.Allocator,
    live_bytes: u64 = 0,
    calls: u64 = 0,

    pub fn allocator(self: *Tracking) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        address: usize,
    ) ?[*]u8 {
        const self: *Tracking = @ptrCast(@alignCast(context));
        assert(length > 0);
        self.calls += 1;
        const memory = self.backing.rawAlloc(length, alignment, address) orelse return null;
        self.live_bytes += length;
        assert(self.live_bytes >= length);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        length: usize,
        address: usize,
    ) bool {
        const self: *Tracking = @ptrCast(@alignCast(context));
        assert(self.live_bytes >= memory.len);
        if (!self.backing.rawResize(memory, alignment, length, address)) return false;
        self.live_bytes = self.live_bytes - memory.len + length;
        assert(self.live_bytes >= length);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        length: usize,
        address: usize,
    ) ?[*]u8 {
        const self: *Tracking = @ptrCast(@alignCast(context));
        assert(self.live_bytes >= memory.len);
        const result = self.backing.rawRemap(memory, alignment, length, address) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + length;
        assert(self.live_bytes >= length);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Tracking = @ptrCast(@alignCast(context));
        assert(memory.len > 0);
        assert(self.live_bytes >= memory.len);
        self.backing.rawFree(memory, alignment, address);
        self.live_bytes -= memory.len;
    }
};
