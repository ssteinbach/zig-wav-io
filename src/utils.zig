//! useful utilities for the wav_io library

const std = @import("std");

/// interleave samples from each of the input buffers in the output buffer such
/// that given input buffers AAA BBB CCC the result will be ABCABCABC
///
/// Output buffer len must be n*input_buffer.len where n is the number of input
/// buffers.
pub fn interleave(
    comptime BufferType: type,
    input_buffers: []const []const BufferType,
    output_buffer: []BufferType,
) !void
{
    if (input_buffers.len == 0)
    {
        return;
    }

    if (output_buffer.len != input_buffers.len * input_buffers[0].len)
    {
        return error.InvalidArgument;
    }

    for (output_buffer, 0..)
        |*val, ind|
    {
        const src_buf = try std.math.mod(
            usize,
            ind,
            input_buffers.len,
        );
        val.* = input_buffers[src_buf][ind/3];
    }
}

test "interleave"
{
    {
        const ones = [_]usize{ 1, 1, 1 };
        const twos = [_]usize{ 2, 2, 2 };

        var result : [6]usize = undefined;

        try interleave(
            usize,
            &.{ &ones, &twos },
            &result
        );

        try std.testing.expectEqualSlices(
            usize, 
            &.{ 1, 2, 1, 2, 1, 2, }, 
            &result,
        );
    }

    {
        const inputs:[]const []const usize = &[_][]const usize{
            &.{ 1, 1, 1, },
            &.{ 2, 2, 2, },
            &.{ 3, 3, 3, },
        };

        var result : [inputs.len*3]usize = undefined;

        try interleave(
            usize,
            inputs,
            &result,
        );

        try std.testing.expectEqualSlices(
            usize, 
            &.{ 1, 2, 3, 1, 2, 3, 1, 2, 3, }, 
            &result,
        );
    }

    {
        const inputs:[]const []const usize = &[_][]const usize{
            &.{ 1, 1, 1, },
        };

        var result : [inputs.len*3]usize = undefined;

        try interleave(
            usize,
            inputs,
            &result,
        );

        try std.testing.expectEqualSlices(
            usize, 
            &.{ 1, 1, 1, }, 
            &result,
        );
    }
}

/// Deinterleave the `input_buffer` such that an array of the form ABCABCABC
/// will be split into the `output_buffers` AAA BBB and CCC.
pub fn deinterleave(
    comptime BufferType: type,
    input_buffer: []BufferType,
    output_buffers: []const []BufferType,
) !void
{ 
    if (input_buffer.len != output_buffers.len * output_buffers[0].len)
    {
        return error.InvalidArgument;
    }

    if (input_buffer.len == 0)
    {
        return;
    }

    for (input_buffer, 0..)
        |val, ind|
    {
        const buf = 
            try std.math.mod(
                usize,
                ind,
                output_buffers.len,
            );
        output_buffers[buf][ind / output_buffers.len] = val;
    }
}

test "deinterleave + roundtrip"
{
    var ones : [3]usize = undefined;
    var twos : [3]usize = undefined;
    var threes : [3]usize = undefined;

    // 3 arrays of 3
    var results : [3][]usize = .{
        &ones, &twos, &threes,
    };

    var input = [_]usize{ 1, 2, 3, 1, 2, 3, 1, 2, 3 };

    try deinterleave(
        usize,
        &input,
        &results,
    );

    const expected:[]const []const usize = &[_][]const usize{
        &.{ 1, 1, 1, },
        &.{ 2, 2, 2, },
        &.{ 3, 3, 3, },
    };

    for (expected, results)
        |e, result|
    {
        try std.testing.expectEqualSlices(
            usize,
            e,
            result,
        );
    }

    var roundtrip_results: [input.len]usize = undefined;

    // round trip
    try interleave(
        usize,
        &results,
        &roundtrip_results,
    );

    try std.testing.expectEqualSlices(
        usize,
        &input, 
        &roundtrip_results,
    );
}

/// Fill `sample_buf` with a sine wave.  Useful for generating test data.
pub fn generate_sine(
    comptime SampleType: type,
    sample_rate: SampleType,
    sample_buf: []SampleType,
    wave_options: struct {
        pitch: SampleType = 440,
        amplitude: SampleType = 0.5,
    },
) void 
{
    const radians_per_sec: SampleType = wave_options.pitch * 2.0 * std.math.pi;

    for (sample_buf, 0..)
        |*new_sample, i|
    {
        const ind_as_f: SampleType = @floatFromInt(i);
        new_sample.* = (
            wave_options.amplitude
            * std.math.sin(ind_as_f * radians_per_sec / sample_rate)
        );
    }
}

