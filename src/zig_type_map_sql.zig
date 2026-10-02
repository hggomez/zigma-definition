//! Type resolution to Postgres types. All the conversion information lives
//! here, in `sql_type_defs` (keyed by `@typeName` of the Zig type); a system
//! only names its domains in its `type_defs`, which resolve through their Zig
//! type. Does not know about any concrete system.

const std = @import("std");

/// The SQL type for `type_name`, resolved in this order:
/// 1. an entry in `sql_type_defs` (a Zig type name, or in the future a domain
///    with its own mapping); an integer narrower than its Postgres integer is
///    its domain instead (see `sqlDomain`);
/// 2. a named domain in the system's `type_defs`: a struct-backed one is the
///    composite type named after the domain, any other resolves through the
///    `@typeName` of its Zig type;
/// 3. otherwise, a compile error.
pub fn sqlType(comptime type_defs: anytype, comptime type_name: []const u8) []const u8 {
    if (@hasField(@TypeOf(sql_type_defs), type_name)) {
        if (integerNamed(type_name)) |T| {
            if (sqlDomain(T)) |domain| return domain.name;
        }
        return @field(sql_type_defs, type_name);
    }
    if (@hasField(@TypeOf(type_defs), type_name)) {
        const T = @field(type_defs, type_name).Type;
        return switch (@typeInfo(T)) {
            .@"struct" => type_name,
            else => sqlType(type_defs, @typeName(T)),
        };
    }
    @compileError("type '" ++ type_name ++ "' has no SQL mapping");
}

/// A Postgres domain over an integer column, checked to the range of a Zig
/// integer type: `CREATE DOMAIN <name> AS <base> CHECK (VALUE BETWEEN <min>
/// AND <max>)` (emitted by `sql_generator.createDomainSql`).
pub const SqlDomain = struct { name: []const u8, base: []const u8, min: i128, max: i128 };

/// The domain of a Zig integer type narrower than the Postgres integer that
/// holds it (`u8` in `SMALLINT` -> `zig_u8`, 0..255), so the column cannot
/// hold what the Zig type cannot; null for any other type (an integer with
/// exactly the range of its Postgres integer needs none). The range comes
/// from the Zig type.
pub fn sqlDomain(comptime T: type) ?SqlDomain {
    if (@typeInfo(T) != .int) return null;
    if (!@hasField(@TypeOf(sql_type_defs), @typeName(T))) return null;
    const base = @field(sql_type_defs, @typeName(T));
    const Base = @field(sql_integer_bases, base);
    if (std.math.minInt(T) == std.math.minInt(Base) and std.math.maxInt(T) == std.math.maxInt(Base))
        return null;
    return .{ .name = "zig_" ++ @typeName(T), .base = base, .min = std.math.minInt(T), .max = std.math.maxInt(T) };
}

/// The Zig integer type of exactly the range of each Postgres integer.
const sql_integer_bases = .{ .SMALLINT = i16, .INTEGER = i32, .BIGINT = i64 };

/// The integer types of `sql_type_defs`, to go back from a name to its type.
const sql_integers = .{ u8, i8, i16, u16, i32, i64 };

fn integerNamed(comptime name: []const u8) ?type {
    inline for (sql_integers) |T| {
        if (comptime std.mem.eql(u8, @typeName(T), name)) return T;
    }
    return null;
}

/// SQL type for each supported Zig primitive type, keyed by `@typeName`. An
/// integer narrower than its entry resolves to its domain (`sqlDomain`); the
/// entry is the domain's base.
pub const sql_type_defs = .{
    .bool = "BOOLEAN",
    .u8 = "SMALLINT",
    .i8 = "SMALLINT",
    .i16 = "SMALLINT",
    // u16 does not fit in SMALLINT (max 32767)
    .u16 = "INTEGER",
    .i32 = "INTEGER",
    .i64 = "BIGINT",
    .@"[]const u8" = "TEXT",
};
