//! Example program for the wav_io library
const std = @import("std");
const wav_io = @import("wav_io");

const FILENAME = "sine.wav";

/// example usage of the writer
pub fn example_write_wav(
    comptime SampleType: type,
    samples_to_encode: []SampleType,
    sample_rate: usize,
    num_channels: usize,
) !void 
{

    // open a file handle for writing
    var file = try std.fs.cwd().createFile(
        FILENAME,
        .{}
    );
    defer file.close();

    // make a writer on that file
    var buf:[1024]u8 = undefined;
    var f_writer = file.writer(&buf);

    // encode and write to the f_writer.interface
    try wav_io.write_wav(
        &f_writer.interface,
        // encoded format to be written -- not the same as the samples that
        // were generated.  write_wav will convert the samples from the format
        // of the sample_buffer to this before passing them to the writer.
        .i24,
        sample_rate,
        num_channels,
        // in-memory sample buffer format
        f32,
        samples_to_encode,
    );

    try f_writer.interface.flush();
}

/// example usage of the writer
pub fn example_write_encoder(
    comptime SampleType: type,
    samples_to_encode: []SampleType,
    sample_rate: usize,
    num_channels: usize,
) !void 
{
    // open a file handle for writing
    var file = try std.fs.cwd().createFile(
        FILENAME,
        .{}
    );
    defer file.close();

    // make a writer on that file
    var buf:[1024]u8 = undefined;
    var f_writer = file.writer(&buf);

    // encode and write to the f_writer.interface
    var encoder = try wav_io.Encoder(i24).init(
        sample_rate,
        num_channels,
    );

    try encoder.write_header(
        &f_writer.interface,
        samples_to_encode.len,
    );

    try encoder.write_samples(
        &f_writer.interface,
        SampleType,
        samples_to_encode,
    );

    try f_writer.interface.flush();
}

pub fn example_read_buffered(
) !void
{
    // open the file
    var file = try std.fs.cwd().openFile(FILENAME, .{});
    defer file.close();

    // build the reader
    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    // build the decoder
    var wav_decoder = try wav_io.Decoder.init(&f_reader.interface);

    // read the data into this buffer -- artificially small for demonstration
    // purposes. Can be bigger or even can be alloced to fit all samples in one
    // go.
    var data: [64]f32 = undefined;

    var sample_count: usize = 0;

    while (true) 
    {
        // Read samples as f32. Channels are interleaved.
        const samples_read = try wav_decoder.read_samples(
            &f_reader.interface,
            f32,
            &data,
        );

        // < ------ Do something with samples in data. ------ >
        sample_count += samples_read;

        if (samples_read < data.len) {
            break;
        }
    }

    // verify that data was written
    try std.testing.expectEqual(
        wav_decoder.data_total_samples,
        sample_count,
    );
    try std.testing.expectEqual(
        0,
        wav_decoder.remaining_samples(),
    );
}

pub fn example_read_simple(
    allocator: std.mem.Allocator,
) !void
{ 
    // open the file
    var file = try std.fs.cwd().openFile(FILENAME, .{});
    defer file.close();

    // build the reader
    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    // build the decoder
    var wav_decoder = try wav_io.Decoder.init(&f_reader.interface);

    // read the data into this buffer
    const decoded_samples = try allocator.alloc(
        f32,
        wav_decoder.remaining_samples()
    );
    defer allocator.free(decoded_samples);

    // actually read the samples
    const samples_read = try wav_decoder.read_samples(
        &f_reader.interface,
        f32,
        decoded_samples,
    );

    // verify that data was written
    try std.testing.expectEqual(
        wav_decoder.data_total_samples,
        samples_read,
    );
    try std.testing.expectEqual(
        0,
        wav_decoder.remaining_samples(),
    );
}

/// Generate mono wav file
/// File is a 6 second sine wave, 3s of A 440 followed by 3s of middle C
pub fn main(
) !void 
{
    // encoding a wav file
    {
        const SampleType = f32;

        // parameters
        const sample_rate = 44100;
        const num_channels = 1;
        const duration_seconds = 6;
        const nsamples = (
            duration_seconds * sample_rate * num_channels
        );

        // generate the samples
        var samples_to_encode:[nsamples]SampleType = undefined;

        // 440
        wav_io.utils.generate_sine(
            SampleType,
            @floatFromInt(sample_rate),
            samples_to_encode[0..nsamples/2],
            .{ .pitch = 440, },
        );

        // middle C
        wav_io.utils.generate_sine(
            SampleType,
            @floatFromInt(sample_rate),
            samples_to_encode[nsamples/2..],
            // middle C
            .{ .pitch = 261.6256, },
        );

        try example_write_wav(
            SampleType,
            &samples_to_encode,
            sample_rate,
            num_channels,
        );

        try example_write_encoder(
            SampleType,
            &samples_to_encode,
            sample_rate,
            num_channels,
        );
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // decoding a wav file
    {
        try example_read_simple(allocator);
        try example_read_buffered();
    }
}
