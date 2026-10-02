//! Test of the generated `backend/src/check.ts` from Node: the generic
//! `check` over aida's restrictions (`clasesRestrictions`), the TS-side check
//! that a value follows the real restriction of its Zig type. `check`
//! returns every problem as `{ field, problem }` (dotted path for a struct
//! field), an empty list when the value is fine. Needs Node, not Docker.
//!
//! Run with `zig build ts-backend`.

const std = @import("std");

// clases: periodo, materia (pk, text), orden (pk, integer -> i64 -> bigint),
// fecha (nullable Fecha { año: u16, mes: u8, día: u8 }), tema (nullable
// text). Prints CHECK_OK.
const check_script =
    \\import { check, clasesRestrictions } from './src/check.ts';
    \\import { deepStrictEqual } from 'node:assert';
    \\const clase = { periodo: '2026-1c', materia: 'AlgoI', orden: 1n, fecha: { año: 2026, mes: 3, día: 14 }, tema: 't' };
    \\const problems = (value) => check(clasesRestrictions, value);
    \\deepStrictEqual(problems(clase), [], 'una clase válida no tiene problemas');
    \\deepStrictEqual(problems({ ...clase, fecha: null, tema: null }), [], 'fecha y tema pueden ser null');
    \\deepStrictEqual(problems({ ...clase, fecha: { año: 2026, mes: 300, día: 14 } }),
    \\  [{ field: 'fecha.mes', problem: 'out of range 0..255' }], 'mes 300 no es un u8');
    \\deepStrictEqual(problems({ ...clase, fecha: { año: 2026, mes: 1.5, día: 14 } }),
    \\  [{ field: 'fecha.mes', problem: 'must be an integer' }], 'mes 1.5 no es un entero');
    \\deepStrictEqual(problems({ ...clase, orden: 2n ** 63n }),
    \\  [{ field: 'orden', problem: 'out of range -9223372036854775808..9223372036854775807' }], 'orden fuera de i64');
    \\deepStrictEqual(problems({ ...clase, orden: 1 }),
    \\  [{ field: 'orden', problem: 'expected a bigint' }], 'orden es bigint, no number');
    \\deepStrictEqual(problems({ ...clase, periodo: null }),
    \\  [{ field: 'periodo', problem: 'must not be null' }], 'un campo de la pk no puede ser null');
    \\deepStrictEqual(problems({ ...clase, tema: 5 }),
    \\  [{ field: 'tema', problem: 'expected a string' }], 'tema es texto');
    \\deepStrictEqual(problems({ ...clase, fecha: 'hoy' }),
    \\  [{ field: 'fecha', problem: 'expected an object' }], 'fecha es un objeto');
    \\const { tema, ...sinTema } = clase;
    \\deepStrictEqual(problems(sinTema), [{ field: 'tema', problem: 'missing' }], 'falta tema');
    \\deepStrictEqual(problems({ ...clase, oden: 1n }), [{ field: 'oden', problem: 'not a field' }], 'oden no es un campo');
    \\deepStrictEqual(problems({ ...clase, fecha: { año: 2026, mes: 3 } }),
    \\  [{ field: 'fecha.día', problem: 'missing' }], 'falta un campo de fecha');
    \\deepStrictEqual(problems({ ...clase, orden: 1, tema: 5 }),
    \\  [{ field: 'orden', problem: 'expected a bigint' }, { field: 'tema', problem: 'expected a string' }],
    \\  'se juntan todos los problemas, en el orden de los campos');
    \\deepStrictEqual(check(clasesRestrictions, 'texto'), [{ field: '', problem: 'expected an object' }],
    \\  'el valor entero tiene que ser un objeto');
    \\console.log('CHECK_OK');
;

/// Runs `script` with node from `backend/` and expects exit 0 and `marker` on
/// stdout; on failure dumps node's stdout/stderr.
fn expectNodeScriptOk(script: []const u8, marker: []const u8) !void {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", script },
        .cwd = .{ .path = "backend" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("could not run node: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "node exited {any}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.term, result.stdout, result.stderr },
        );
        return error.NodeScriptFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, marker) != null);
}

test "check finds every way a clases value breaks the restrictions of its Zig types" {
    try expectNodeScriptOk(check_script, "CHECK_OK");
}
