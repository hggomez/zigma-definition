//! expected: field 'nombre' of type 'lugar': text inside a composite type is not read yet
//! (the text form of a composite quotes and escapes text fields)
const zigma = @import("zigma");
const ts = @import("ts_server_generator");

const Lugar = struct { nombre: []const u8, piso: u8 };

const types = zigma.defineTypes(.{
    .text = zigma.TypeDef{ .Type = []const u8 },
    .lugar = zigma.TypeDef{ .Type = Lugar },
});

const salas = zigma.defineEntity(.{
    .pk = .{"sala"},
    .fields = zigma.record(types, .{
        .sala = .{ .type = "text" },
        .lugar = .{ .type = "lugar" },
    }),
});

comptime {
    _ = ts.generateTsServer(types, .{ .salas = salas });
}
