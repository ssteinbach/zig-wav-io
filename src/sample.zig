//! utilities for dealing with samples + unit tests
const std = @import("std");

const bad_type = (
    "sample type must be u8, i16, i24, i32, or f32, not: "
);

/// Converts between integer/PCM and float sample formats.  Only allows source
/// types that are also supported integer/floating point types.
pub fn convert(
    /// type to convert value to
    comptime TargetType: type,
    /// value to convert
    value: anytype,
) TargetType 
{
    const SourceType = @TypeOf(value);
    if (SourceType == TargetType) 
    {
        return value;
    }

    // PCM uses unsigned 8-bit ints instead of signed. Special case.
    if (SourceType == u8) 
    {
        return convert(
            TargetType,
            @as(i8, @bitCast(value -% 128)),
        );
    } 
    else if (TargetType == u8) 
    {
        return @as(u8, @bitCast(convert(i8, value))) +% 128;
    }

    return switch (SourceType) {
        i8, i16, i24, i32 => switch (TargetType) {
            i8, i16, i24, i32 => (
                convert_signed_int(TargetType, value)
            ),
            f32 => convert_int_to_float(TargetType, value),
            else => @compileError(bad_type ++ @typeName(SourceType)),
        },
        f32 => switch (TargetType) {
            i8, i16, i24, i32 => (
                convert_float_to_int(TargetType, value)
            ),
            f32 => value,
            else => @compileError(bad_type),
        },
        else => @compileError(bad_type ++ @typeName(SourceType)),
    };
}

/// internal: convert a float to an int
fn convert_float_to_int(
    /// target type to convert to
    comptime TargetType: type,
    /// floating point value to convert
    value: anytype,
) TargetType 
{
    const SourceType = @TypeOf(value);

    const min : SourceType = comptime @floatFromInt(std.math.minInt(TargetType));
    const max : SourceType = comptime @floatFromInt(std.math.maxInt(TargetType));

    // Need lossyCast instead of @floatToInt because float representation of
    // max/min TargetType may be out of range.
    return std.math.lossyCast(
        TargetType,
        std.math.clamp(
            @round(value * (1.0 + max)),
            min,
            max,
        )
    );
}

fn convert_int_to_float(
    comptime TargetType: type,
    value: anytype,
) TargetType 
{
    const SourceType = @TypeOf(value);
    return (
        (
         1.0 / (
             1.0 + @as(TargetType, @floatFromInt(std.math.maxInt(SourceType)))
         )
        ) * @as(TargetType, @floatFromInt(value))
    );
}

/// convert one int to another integer type
fn convert_signed_int(
    comptime TargetType: type,
    value: anytype,
) TargetType 
{
    const SourceType = @TypeOf(value);

    const src_bits = @typeInfo(SourceType).int.bits;
    const dst_bits = @typeInfo(TargetType).int.bits;

    if (src_bits < dst_bits) {
        const shift = dst_bits - src_bits;
        return @as(TargetType, value) << shift;
    } else if (src_bits > dst_bits) {
        const shift = src_bits - dst_bits;
        return @intCast(value >> shift);
    }

    comptime std.debug.assert(SourceType == TargetType);
    return value;
}

fn expectApproxEqualInt(
    expected: anytype,
    actual: @TypeOf(expected),
    tolerance: @TypeOf(expected),
) !void 
{
    const abs = (
        if (expected > actual) expected - actual 
        else actual - expected
    );
    try std.testing.expect(abs <= tolerance);
}

fn test_downward_conversions(
    float32: f32,
    uint8: u8,
    int16: i16,
    int24: i24,
    int32: i32,
) !void 
{
    try std.testing.expectEqual(uint8, convert(u8, uint8));
    try std.testing.expectEqual(uint8, convert(u8, int16));
    try std.testing.expectEqual(uint8, convert(u8, int24));
    try std.testing.expectEqual(uint8, convert(u8, int32));

    try std.testing.expectEqual(int16, convert(i16, int16));
    try std.testing.expectEqual(int16, convert(i16, int24));
    try std.testing.expectEqual(int16, convert(i16, int32));

    try std.testing.expectEqual(int24, convert(i24, int24));
    try std.testing.expectEqual(int24, convert(i24, int32));

    try std.testing.expectEqual(int32, convert(i32, int32));

    const tolerance: f32 = 0.00001;
    try std.testing.expectApproxEqAbs(float32, convert(f32, uint8), tolerance * 512.0);
    try std.testing.expectApproxEqAbs(float32, convert(f32, int16), tolerance * 4.0);
    try std.testing.expectApproxEqAbs(float32, convert(f32, int24), tolerance * 2.0);
    try std.testing.expectApproxEqAbs(float32, convert(f32, int32), tolerance);

    try std.testing.expectApproxEqAbs(uint8, convert(u8, float32), 1);
    try expectApproxEqualInt(int16, convert(i16, float32), 2);
    try expectApproxEqualInt(int24, convert(i24, float32), 2);
    try expectApproxEqualInt(int32, convert(i32, float32), 200);
}

test "sanity test" 
{
    try test_downward_conversions(0.0, 0x80, 0, 0, 0);
    try test_downward_conversions(0.0122069996, 0x81, 0x18F, 0x18FFF, 0x18FFFBB);
    try test_downward_conversions(0.00274699973, 0x80, 0x5A, 0x5A03, 0x5A0381);
    try test_downward_conversions(-0.441255282, 0x47, -14460, -3701517, -947588300);

    var uint8: u8 = 0x81;
    try std.testing.expectEqual(@as(i16, 0x100), convert(i16, uint8));
    try std.testing.expectEqual(@as(i24, 0x10000), convert(i24, uint8));
    try std.testing.expectEqual(@as(i32, 0x1000000), convert(i32, uint8));
    var int16: i16 = 0x18F;
    try std.testing.expectEqual(@as(i24, 0x18F00), convert(i24, int16));
    try std.testing.expectEqual(@as(i32, 0x18F0000), convert(i32, int16));
    var int24: i24 = 0x18FFF;
    try std.testing.expectEqual(@as(i32, 0x18FFF00), convert(i32, int24));

    uint8 = 0x80;
    try std.testing.expectEqual(@as(i16, 0), convert(i16, uint8));
    try std.testing.expectEqual(@as(i24, 0), convert(i24, uint8));
    try std.testing.expectEqual(@as(i32, 0), convert(i32, uint8));
    int16 = 0x5A;
    try std.testing.expectEqual(@as(i24, 0x5A00), convert(i24, int16));
    try std.testing.expectEqual(@as(i32, 0x5A0000), convert(i32, int16));
    int24 = 0x5A03;
    try std.testing.expectEqual(@as(i32, 0x5A0300), convert(i32, int24));

    uint8 = 0x47;
    try std.testing.expectEqual(@as(i16, -14592), convert(i16, uint8));
    try std.testing.expectEqual(@as(i24, -3735552), convert(i24, uint8));
    try std.testing.expectEqual(@as(i32, -956301312), convert(i32, uint8));
    int16 = -14460;
    try std.testing.expectEqual(@as(i24, -3701760), convert(i24, int16));
    try std.testing.expectEqual(@as(i32, -947650560), convert(i32, int16));
    int24 = -3701517;
    try std.testing.expectEqual(@as(i32, -947588352), convert(i32, int24));
}
