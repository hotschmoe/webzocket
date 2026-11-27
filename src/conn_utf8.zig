const assert = @import("assert").assert;

pub const Utf8 = struct {
    need: u8 = 0,
    lo: u8 = 0x80,
    hi: u8 = 0xbf,

    pub fn feed(self: *Utf8, bytes: []const u8) bool {
        assert(self.need <= 3);
        assert(self.lo <= self.hi);
        for (bytes) |byte| {
            if (self.need > 0) {
                if (byte < self.lo or byte > self.hi) return false;
                self.need -= 1;
                self.lo = 0x80;
                self.hi = 0xbf;
            } else if (byte < 0x80) {
                continue;
            } else if (!self.start(byte)) return false;
        }
        assert(self.need <= 3);
        return true;
    }

    fn start(self: *Utf8, lead: u8) bool {
        assert(self.need == 0);
        assert(lead >= 0x80);
        switch (lead) {
            0xc2...0xdf => self.need = 1,
            0xe0 => {
                self.need = 2;
                self.lo = 0xa0;
            },
            0xe1...0xec, 0xee...0xef => self.need = 2,
            0xed => {
                self.need = 2;
                self.hi = 0x9f;
            },
            0xf0 => {
                self.need = 3;
                self.lo = 0x90;
            },
            0xf1...0xf3 => self.need = 3,
            0xf4 => {
                self.need = 3;
                self.hi = 0x8f;
            },
            else => return false,
        }
        return true;
    }

    pub fn complete(self: *const Utf8) bool {
        return self.need == 0;
    }
};

pub fn valid(bytes: []const u8) bool {
    var state: Utf8 = .{};
    const ok = state.feed(bytes) and state.complete();
    assert(!ok or state.need == 0);
    return ok;
}
