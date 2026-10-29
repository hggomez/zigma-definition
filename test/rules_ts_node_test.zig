//! The generated rules.ts of the test system, run from Node against the
//! system's real rules.wasm, next to it (rules.ts loads ./rules.wasm): the
//! whole path the backend will use, with no hand-written half of the
//! contract. What it adds over rules_wasm_node_test.zig: the typed functions,
//! the RuleResult, the field-by-field serializer (extra properties stay out
//! of the JSON) and bigint crossing exactly.
//!
//! Run with `zig build test-rules-wasm`, which generates rules.ts, puts it next to
//! the compiled module and passes the path of rules.ts here. Not part of
//! `zig build test` (needs Node).

const std = @import("std");
const build_options = @import("build_options");

// An ES module run with `node --input-type=module -e`; the path of rules.ts
// (rules.wasm is next to it) is its first argument. Prints RULES_TS_OK when
// every assert holds.
const script =
    \\import assert from 'node:assert/strict';
    \\import { pathToFileURL } from 'node:url';
    \\
    \\const { checkRoom, checkBooking } = await import(pathToFileURL(process.argv[1]).href);
    \\
    \\// passes
    \\assert.deepEqual(checkRoom({ room: 'A', capacity: 10n }), { ok: true });
    \\assert.deepEqual(checkBooking({ room: 'A', start: 9n, end: 11n }), { ok: true });
    \\
    \\// rejected: the name of the domain error
    \\assert.deepEqual(checkRoom({ room: 'A', capacity: 0n }), { ok: false, error: 'NoCapacity' });
    \\assert.deepEqual(checkBooking({ room: 'A', start: 11n, end: 9n }), { ok: false, error: 'EndBeforeStart' });
    \\assert.deepEqual(checkBooking({ room: 'A', start: 9n, end: 9n }), { ok: false, error: 'Empty' });
    \\
    \\// an object with more properties than the rule's (e.g. a whole row): only
    \\// the rule's fields go into the JSON, so the rule still runs on them
    \\const row = { id: 42n, room: 'A', start: 11n, end: 9n, notes: 'x' };
    \\assert.deepEqual(checkBooking(row), { ok: false, error: 'EndBeforeStart' });
    \\
    \\// a bigint crosses exactly: the whole i64 range, and nothing outside it
    \\assert.deepEqual(checkRoom({ room: 'A', capacity: 9223372036854775807n }), { ok: true });
    \\assert.deepEqual(checkBooking({ room: 'A', start: -9223372036854775808n, end: 0n }), { ok: true });
    \\assert.deepEqual(checkRoom({ room: 'A', capacity: 9223372036854775808n }), { ok: false, error: 'InvalidInput' });
    \\// 2^53 + 1 is not representable as a number: it must not go through one
    \\assert.deepEqual(checkBooking({ room: 'A', start: 9007199254740992n, end: 9007199254740993n }), { ok: true });
    \\
    \\console.log('RULES_TS_OK');
;

test "the generated rules.ts runs the test system's rules from Node" {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", script, build_options.rules_ts_path },
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
        return error.RulesTsFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULES_TS_OK") != null);
}
