//! The rules of a system exported for WASM (src/rules_wasm.zig), tested
//! natively: `run` is what each export does between reading its input and
//! packing its result. The contract: the input is the record instance as
//! JSON; the result is "" when the instance passes, the name of the Zig error
//! when the rule rejects it, "InvalidInput" when the JSON is not an instance
//! of the record. The packing (`ptr << 32 | len`) and `alloc` only fit on
//! wasm32 (32-bit pointers), so they are tested from Node in their own step.
//!
//! The system is test/test_system.zig, given to the module as "system".
//! `std.testing.allocator` also checks that `run` frees what it parses.

const std = @import("std");
const rules_wasm = @import("rules_wasm");

const expectEqualStrings = std.testing.expectEqualStrings;

fn run(comptime rule_name: []const u8, input: []const u8) []const u8 {
    return rules_wasm.run(std.testing.allocator, rule_name, input);
}

test "an instance that passes its rule gives an empty string" {
    try expectEqualStrings("", run("checkRoom",
        \\{"room": "A", "capacity": 10}
    ));
    try expectEqualStrings("", run("checkBooking",
        \\{"room": "A", "start": 9, "end": 11}
    ));
}

test "an instance that its rule rejects gives the name of the domain error" {
    try expectEqualStrings("NoCapacity", run("checkRoom",
        \\{"room": "A", "capacity": 0}
    ));
    try expectEqualStrings("EndBeforeStart", run("checkBooking",
        \\{"room": "A", "start": 11, "end": 9}
    ));
    try expectEqualStrings("Empty", run("checkBooking",
        \\{"room": "A", "start": 9, "end": 9}
    ));
}

test "input that is not an instance of the record gives InvalidInput" {
    // not JSON
    try expectEqualStrings("InvalidInput", run("checkRoom", "not json"));
    // a missing field (the instance type has no defaults)
    try expectEqualStrings("InvalidInput", run("checkRoom",
        \\{"room": "A"}
    ));
    // a field the record does not have
    try expectEqualStrings("InvalidInput", run("checkRoom",
        \\{"room": "A", "capacity": 10, "floor": 2}
    ));
    // a string where the record has an integer
    try expectEqualStrings("InvalidInput", run("checkRoom",
        \\{"room": "A", "capacity": "ten"}
    ));
    // a number with decimals where the record has an integer
    try expectEqualStrings("InvalidInput", run("checkRoom",
        \\{"room": "A", "capacity": 1.5}
    ));
    // null in a field that is not nullable
    try expectEqualStrings("InvalidInput", run("checkRoom",
        \\{"room": "A", "capacity": null}
    ));
}

test "an integer field reads the whole i64 range exactly, and nothing outside it" {
    try expectEqualStrings("", run("checkRoom",
        \\{"room": "A", "capacity": 9223372036854775807}
    ));
    try expectEqualStrings("", run("checkBooking",
        \\{"room": "A", "start": -9223372036854775808, "end": 0}
    ));
    try expectEqualStrings("InvalidInput", run("checkRoom",
        \\{"room": "A", "capacity": 9223372036854775808}
    ));
}
