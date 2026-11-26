pub fn assert(ok: bool) void {
    if (!ok) @panic("assertion failed");
}
