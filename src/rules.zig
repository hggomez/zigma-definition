//! Rules: the domain validations of a system, written once in Zig. A rule is
//! a function that takes an instance of a record and either passes or returns
//! a domain error (`error{...}!void`). Declaring the rules with `defineRules`
//! is what makes them visible to the generators; `zigma` re-exports it.
//!
//! A rule definition names its record explicitly: the function's parameter is
//! only the derived instance struct, which has lost what a generator needs
//! (the domain types, `nullable`, which record it came from). `defineRules`
//! checks that both agree.

const std = @import("std");
const zigma = @import("zigma.zig");

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn checkRule(comptime type_defs: anytype, comptime rule_def: anytype, comptime name: []const u8) void {
    const RuleDefType = @TypeOf(rule_def);
    const info = @typeInfo(RuleDefType);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("rule '" ++ name ++ "': a rule definition must be a struct like .{ .record = ..., .rule = ... }");
    inline for (info.@"struct".field_names) |prop_name| {
        if (!eql(prop_name, "record") and !eql(prop_name, "rule"))
            @compileError("rule '" ++ name ++ "': unknown property '" ++ prop_name ++ "'");
    }
    if (!@hasField(RuleDefType, "record"))
        @compileError("rule '" ++ name ++ "': missing 'record'");
    if (!@hasField(RuleDefType, "rule"))
        @compileError("rule '" ++ name ++ "': missing 'rule'");

    const fn_info = @typeInfo(@TypeOf(rule_def.rule));
    if (fn_info != .@"fn")
        @compileError("rule '" ++ name ++ "': 'rule' must be a function");
    const param_types = fn_info.@"fn".param_types;
    if (param_types.len != 1)
        @compileError("rule '" ++ name ++ "': must take exactly one parameter, an instance of its record");
    if (param_types[0] != zigma.RecordInstanceType(type_defs, rule_def.record))
        @compileError("rule '" ++ name ++ "': its parameter must be the instance type of its record");

    const return_type = fn_info.@"fn".return_type orelse
        @compileError("rule '" ++ name ++ "': must be a validation, returning error{...}!void");
    const return_info = @typeInfo(return_type);
    if (return_info != .error_union or return_info.error_union.payload != void)
        @compileError("rule '" ++ name ++ "': must be a validation, returning error{...}!void");
}

fn checkRules(comptime type_defs: anytype, comptime rule_defs: anytype) void {
    const info = @typeInfo(@TypeOf(rule_defs));
    // `.{}` (a system without rules) is an empty tuple: accepted
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len != 0))
        @compileError("a rule collection must be a struct of rule definitions");
    inline for (info.@"struct".field_names) |rule_name| {
        checkRule(type_defs, @field(rule_defs, rule_name), rule_name);
    }
}

/// The declaration-site check of the rules of a system: each one is
/// `.{ .record = ..., .rule = ... }`, named by its key, where `rule` takes
/// exactly the instance of `record` over `type_defs` and returns
/// `error{...}!void`. Returns the collection unchanged.
pub fn defineRules(comptime type_defs: anytype, comptime rule_defs: anytype) @TypeOf(rule_defs) {
    comptime checkRules(type_defs, rule_defs);
    return rule_defs;
}
