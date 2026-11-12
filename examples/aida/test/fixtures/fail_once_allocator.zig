//! Falla una reserva y permite las siguientes, para detectar errores de memoria
//! ocultos por la construcción posterior de una respuesta HTTP de validación.
const std = @import("std");
const Self = @This();
backing: std.mem.Allocator,
fail_index: usize,
alloc_index: usize = 0,
failed: bool = false,

pub fn allocator(self: *Self) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    defer self.alloc_index += 1;
    if (self.alloc_index == self.fail_index) {
        self.failed = true;
        return null;
    }
    return self.backing.rawAlloc(len, alignment, ra);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.backing.rawResize(memory, alignment, len, ra);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.backing.rawRemap(memory, alignment, len, ra);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.backing.rawFree(memory, alignment, ra);
}
