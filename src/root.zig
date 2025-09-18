//! wav_io: Simple wav encoding/decoding library.
//!
//! For simple cases, see `write_wav` and `read_wav`, for more specific use
//! cases, see the  Encoder  and `Decoder` structures.
//!
//! Supports PCM and IEEE Float formats.
//!
//! Also see the `utils` module.
//!
//! Uses `std.log` to report information. 

const std = @import("std");
const builtin = @import("builtin");

const sample = @import("sample.zig");
pub const utils = @import("utils.zig");

test {
    _ = utils;
}

const bad_type_message = (
    "sample type must be u8, i16, i24, or f32 got: "
);

/// returns the number of bytes to serialize the given type
fn byte_size_of(
    comptime Type: type,
) usize
{
    return @bitSizeOf(Type) / 8;
}

/// Wav sample format.  this library supports pcm and ieee_float
const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,

    // unsupported
    alaw = 6,
    mulaw = 7,
    extensible = 0xFFFE,
    _,
};

/// Encodes the header WAV format chunk
const FormatInfo = packed struct {
    code: FormatCode,
    channels: u16,
    /// samples per second
    sample_rate: u32,
    bytes_per_second: u32,
    block_align: u16,
    bits_per_sample: u16,

    /// format function for `FormatInfo`
    pub fn format(
        self: @This(),
        writer: *std.io.Writer,
    ) std.io.Writer.Error!void
    {
        try writer.print(
            (
                  "FormatInfo{{"
                  ++ " .code: {s},"
                  ++ " .channels: {d},"
                  ++ " .sample_rate: {d},"
                  ++ " .bytes_per_second: {d},"
                  ++ " .block_align: {d},"
                  ++ " .bits_per_sample: {d},"
                  ++ " }} (Sample Type: {s}{d})"
            )
            , 
            .{
                @tagName(self.code),
                self.channels,
                self.sample_rate,
                self.bytes_per_second,
                self.block_align,
                self.bits_per_sample,
                switch (self.code) {
                    .pcm => "i",
                    .ieee_float => "f",
                    else => "?",
                },
                self.bits_per_sample,
            },
        );
    }

    /// parse the format chunk from the reader
    fn parse(
        reader: *std.Io.Reader,
        chunk_size: usize,
    ) !FormatInfo 
    {
        if (chunk_size < @sizeOf(FormatInfo)) 
        {
            return error.InvalidSize;
        }

        // because the struct can be (is) smaller than the chunk size, peek the
        // value out of the buffer, then advance by the chunk size.
        const fmt = try reader.peekStruct(
            FormatInfo,
            .little,
        );
        try reader.discardAll(chunk_size);

        return fmt;
    }

    /// ensure that the values in the format info are valid
    fn validate(
        self: FormatInfo,
    ) !void 
    {
        switch (self.code) {
            .pcm, .ieee_float, .extensible => {},
            else => {
                std.log.err(
                    // show the hex code for the enum
                    "unsupported format code {x}",
                    .{@intFromEnum(self.code)},
                );
                return error.Unsupported;
            },
        }
        if (self.channels == 0) 
        {
            std.log.debug("invalid channels (0)", .{});
            return error.InvalidValue;
        }
        switch (self.bits_per_sample) {
            0 => return error.InvalidValue,
            8, 16, 24, 32 => {},
            else => {
                std.log.debug(
                    "unsupported bits per sample {}",
                    .{self.bits_per_sample}
                );
                return error.Unsupported;
            },
        }
        if (
            self.bytes_per_second != (
                (self.bits_per_sample / 8) * self.sample_rate * self.channels
            )
        ) 
        {
            std.log.debug(
                "invalid bytes_per_second: {d}",
                .{self.bytes_per_second},
            );
            return error.InvalidValue;
        }
    }
};

/// Decode wav data from a *std.Io.Reader.  After calling `Decoder.init`, 
/// use `Decoder.read_samples`.
pub const Decoder = struct {
    /// Format as reported by the wav header.
    fmt: FormatInfo,

    /// Total samples as reported by the wav header.
    data_total_samples: usize,

    /// Total samples that have been read by `Decoder.read_samples`.
    /// `Decoder.remaining_samples` will compute the remaining samples in the
    /// file.
    data_samples_read: usize,

    /// Errors produced by this struct
    const DecoderError = (
        std.Io.Reader.Error
        || error{ 
            InvalidFileType,
            InvalidArgument,
            InvalidSize,
            InvalidValue,
            Overflow,
            Unsupported,
        }
    );

    /// Number of samples remaining.
    pub fn remaining_samples(
        self: Decoder,
    ) usize 
    {
        return self.data_total_samples - self.data_samples_read;
    }

    /// Create a Decoder object by reading the header block.  After calling
    /// this, Decoder should be ready to have `Decoder.read_samples` called.
    pub fn init(
        reader: *std.Io.Reader,
    ) DecoderError!Decoder 
    {
        comptime std.debug.assert(
            builtin.target.cpu.arch.endian() == .little
        );

        var bytes_read:usize = 0;

        var chunk_id: [4]u8 = undefined;
        const chunk_id_size_bytes = std.mem.sliceAsBytes(&chunk_id).len;

        try reader.readSliceAll(&chunk_id);
        bytes_read += chunk_id_size_bytes;

        if (!std.mem.eql(u8, "RIFF", &chunk_id)) 
        {
            std.log.err(
                "not a RIFF file, instead found: {s}",
                .{chunk_id}
            );
            return error.InvalidFileType;
        }

        const total_size = try std.math.add(
            u32,
            try reader.takeInt(u32, .little),
            8
        );
        bytes_read += byte_size_of(u32);

        try reader.readSliceAll(&chunk_id);
        bytes_read += chunk_id_size_bytes;

        if (!std.mem.eql(u8, "WAVE", &chunk_id)) {
            std.log.debug("not a WAVE file", .{});
            return error.InvalidFileType;
        }

        // Iterate through chunks. Require fmt and data.
        var maybe_fmt: ?FormatInfo = null;
        var data_size_bytes: usize = 0; // Bytes in data chunk.
        while (true) 
        {
            try reader.readSliceAll(&chunk_id);
            bytes_read += chunk_id_size_bytes;

            const next_chunk_size_bytes:usize = @intCast(
                try reader.takeInt(
                    u32,
                    .little,
                )
            );
            bytes_read += byte_size_of(u32);

            if (std.mem.eql(u8, "fmt ", &chunk_id)) 
            {
                maybe_fmt = try FormatInfo.parse(
                    reader,
                    next_chunk_size_bytes,
                );
                bytes_read += next_chunk_size_bytes;

                if (maybe_fmt)
                    |fmt|
                {
                    try fmt.validate();

                    const bytes_per_sample = (
                        fmt.block_align / fmt.channels
                    );
                    if (bytes_per_sample * 8 != fmt.bits_per_sample) 
                    {
                        return error.Unsupported;
                    }
                }
                else 
                {
                    unreachable;
                }

                // TODO: Support 32-bit aligned i24 blocks.
            } 
            else if (std.mem.eql(u8, "data", &chunk_id)) 
            {
                // Expect data chunk to be last.
                data_size_bytes = next_chunk_size_bytes;
                break;
            } 
            else 
            {
                std.log.debug("Skipping chunk: {s}\n", .{chunk_id});
                try reader.discardAll(next_chunk_size_bytes);
                bytes_read += next_chunk_size_bytes;
            }
        }

        if (maybe_fmt == null) 
        {
            std.log.err("no fmt chunk present", .{});
            return error.InvalidFileType;
        }

        const fmt = maybe_fmt.?;

        const data_start = bytes_read;
        if (data_start + data_size_bytes > total_size) {
            return error.InvalidSize;
        }
        if (data_size_bytes % (fmt.channels * fmt.bits_per_sample / 8) != 0) {
            return error.InvalidSize;
        }

        const total_samples = (
            data_size_bytes * 8 / (fmt.bits_per_sample)
        );

        return .{
            .fmt = fmt,
            .data_total_samples = total_samples,
            .data_samples_read = 0,
        };
    }

    /// Read samples, decode them to `DecodedType`, and place them into
    /// `decoded_buffer`. 
    ///
    /// Multi-channel samples are interleaved: samples for time `t` for all
    /// channels are written to `t * channels`. `decoded_buffer.len` must be
    /// evenly divisible by `channels`.
    ///
    /// Note that `utils` library includes `utils.interleave` and
    /// `utils.deinterleave` functions for dealing with interleaving of
    /// samples.
    ///
    /// Returns: number of bytes read. 0 indicates end of stream.
    pub fn read_samples(
        self: *Decoder,
        reader: *std.Io.Reader,
        /// Type to decode samples into.
        comptime DecodedType: type,
        decoded_buffer: []DecodedType,
    ) DecoderError!usize 
    {
        return switch (self.fmt.code) {
            .pcm => switch (self.fmt.bits_per_sample) {
                8 => self._read_and_convert (
                    reader,
                    u8,
                    DecodedType,
                    decoded_buffer,
                ),
                16 => self._read_and_convert(
                    reader,
                    i16,
                    DecodedType,
                    decoded_buffer,
                ),
                24 => self._read_and_convert(
                    reader,
                    i24,
                    DecodedType,
                    decoded_buffer,
                ),
                32 => self._read_and_convert(
                    reader,
                    i32,
                    DecodedType,
                    decoded_buffer,
                ),
                else => std.debug.panic(
                    "invalid decoder state, unexpected fmt bits {}",
                    .{self.fmt.bits_per_sample},
                ),
            },
            .ieee_float => self._read_and_convert(
                reader,
                f32,
                DecodedType,
                decoded_buffer,
            ),
            else => std.debug.panic(
                "invalid decoder state, unexpected fmt code {}",
                .{@intFromEnum(self.fmt.code)},
            ),
        };
    }

    /// internal read function.  Returns the number of bytes read - 0 means
    /// empty, all samples read from file.
    fn _read_and_convert(
        self: *Decoder,
        reader: *std.Io.Reader,
        /// read a buffer of type SourceSampleType from the reader
        comptime SourceSampleType: type,
        /// convert to type DestinationSampleType 
        comptime DestinationSampleType: type,
        /// fill this buffer -- if longer than the remaining samples, will only
        /// read as many samples as are remaining
        dest_buf: []DestinationSampleType,
    ) DecoderError!usize 
    {
        if (self.data_samples_read >= self.data_total_samples)
        {
            return 0;
        }

        const samples_to_read = @min(dest_buf.len, self.remaining_samples());

        const actual_dest_buf = dest_buf[0..samples_to_read];

        if (
            SourceSampleType == DestinationSampleType 
            // XXX: readSliceEndian with i24 will assume that the i24 is
            //      written with i32 alignment, which is unsupported at the
            //      moment by this library
            and SourceSampleType != i24
        )
        {
            try reader.readSliceEndian(
                SourceSampleType,
                actual_dest_buf,
                .little,
            );

            self.data_samples_read += actual_dest_buf.len;
            return actual_dest_buf.len;
        }

        for (actual_dest_buf)
            |*dest_val|
        {
            dest_val.* = sample.convert(
                DestinationSampleType,
                switch (@typeInfo(SourceSampleType)) {
                    .int => try reader.takeInt(
                        SourceSampleType,
                        .little,
                    ),
                    .float => std.mem.bytesAsValue(
                        SourceSampleType,
                        try reader.take(4)
                    ).*,
                    else => unreachable,
                }
            );
        }

        self.data_samples_read += actual_dest_buf.len;

        return actual_dest_buf.len;
    }
};

/// Construct an `Encoder` type, for serializing wav data to the writer.
///
/// Wav file structure has a header which describes the file followed by
/// samples.  To create a valid file, after calling `Encoder.init`, call
/// `Encoder.write_header` followed by `Encoder.write_samples` however many
/// times is needed to serialize all the samples.  Example usage:
///
/// ```
/// var enc = try Encoder(EncodedSampleType).init(sample_rate, channels);
/// try enc.write_header(writer, nsamples);
/// try enc.write_samples(SourceSampleType, sample_buffer);
/// ```
///
/// `Encoder.write_samples` will convert to the `EncodedSampleType` before writing. 
pub fn Encoder(
    /// Data type to encode samples into before writing.  Must be one of u8,
    /// i16, i24, f32.
    ///
    /// *NOTE* i24 samples are written in a 24 bit container, not a 32 bit
    ///        container.
    comptime EncodedSampleType: type,
) type 
{
    return struct {
        const Error = (
            std.Io.Writer.Error
            || error{ InvalidArgument, Overflow }
        );

        fmt: FormatInfo,
        /// Number of samples that have been written by this encoder.  Will be
        /// updated after calls to `Encoder.write_samples`.
        samples_written: usize = 0,

        /// Construct an `Encoder`
        pub fn init(
            sample_rate: usize,
            channels: usize,
        ) Error!@This() 
        {
            const bits = (
                switch (EncodedSampleType) {
                    u8 => 8,
                    i16 => 16,
                    i24 => 24,
                    f32 => 32,
                    else => @compileError(
                        bad_type_message ++ @typeName(EncodedSampleType)
                    ),
                }
            );

            if (sample_rate == 0 or sample_rate > std.math.maxInt(u32)) 
            {
                std.log.debug(
                    "invalid sample_rate {}",
                    .{sample_rate},
                );
                return error.InvalidArgument;
            }
            if (channels == 0 or channels > std.math.maxInt(u16)) 
            {
                std.log.debug(
                    "invalid channels {}",
                    .{channels},
                );
                return error.InvalidArgument;
            }
            const bytes_per_second = sample_rate * channels * bits / 8;
            if (bytes_per_second > std.math.maxInt(u32)) 
            {
                std.log.debug(
                    "bytes_per_second, {}, too large",
                    .{bytes_per_second},
                );
                return error.InvalidArgument;
            }

            return .{
                .fmt = .{
                    .code = switch (EncodedSampleType) {
                        u8, i16, i24 => .pcm,
                        f32 => .ieee_float,
                        else => @compileError(
                            bad_type_message ++ @typeName(EncodedSampleType)
                        ),
                    },
                    .channels = @intCast(channels),
                    .sample_rate = @intCast(sample_rate),
                    .bytes_per_second = @intCast(bytes_per_second),
                    .block_align = @intCast(channels * bits / 8),
                    .bits_per_sample = @intCast(bits),
                },
            };
        }


        /// Read samples of type `NewSampleType` from `new_sample_buf`, convert
        /// to `EncodedSampleType`, and write the samples to writer.
        ///
        /// Multi-channel samples must be interleaved: samples for time `t` for
        /// all channels are written to `t * channels`.
        ///
        /// Note that `utils` library includes `utils.interleave` and
        /// `utils.deinterleave` functions for dealing with interleaving of
        /// samples.
        ///
        /// May be called multiple times, samples will be appended with each
        /// call.
        pub fn write_samples(
            self: *@This(),
            writer: *std.Io.Writer,
            /// Type of the samples in the `new_sample_buf`.  Will be converted
            /// to `EncodedSampleType` and written using the writer.
            comptime NewSampleType: type,
            /// Buffer of new samples to be encoded and passed to the writer
            new_sample_buf: []const NewSampleType,
        ) Error!void 
        {
            // XXX: i24 needs special handling because writeSliceEndian will
            //      write with the assumption of 32 bit alignment
            if (NewSampleType == EncodedSampleType and EncodedSampleType != i24)
            {
                try writer.writeSliceEndian(
                    EncodedSampleType,
                    new_sample_buf,
                    .little,
                );
            }
            else
            {
                for (new_sample_buf) 
                    |new_sample_src| 
                {
                    const new_sample_dst_type = sample.convert(
                        EncodedSampleType,
                        new_sample_src,
                    );

                    switch (EncodedSampleType) {
                        u8, i16, i24, => {
                            try writer.writeInt(
                                EncodedSampleType,
                                new_sample_dst_type,
                                .little,
                            );
                        },
                        f32 => {
                            // individually convert each sample to the target type
                            // and write to output buffer
                            try writer.writeSliceEndian(
                                EncodedSampleType,
                                &.{ new_sample_dst_type },
                                .little,
                            );
                        },
                        else => @compileError(
                            bad_type_message ++ @typeName(EncodedSampleType)
                        ),
                    }
                }
            }

            self.samples_written += new_sample_buf.len;
        }

        /// Serialize the wav header.  Called before `write_samples`.  
        ///
        /// If the number of samples is unknown, call first to ensure that the
        /// samples are written with the correct offset, then write the
        /// samples, and finally seek to the beginning of the write stream and
        /// call this again after the number of samples is known.
        pub fn write_header(
            self: *@This(),
            writer: *std.Io.Writer,
            nsamples: usize,
        ) Error!void 
        {
            const data_size = byte_size_of(EncodedSampleType) * nsamples;

            // Size of RIFF header + fmt id/size + fmt chunk + data id/size.
            const header_size: usize = 12 + 8 + byte_size_of(@TypeOf(self.fmt)) + 8;

            if (header_size + data_size > std.math.maxInt(u32)) 
            {
                return error.Overflow;
            }

            try writer.writeAll("RIFF");
            const size_to_write:u32 = @intCast(header_size + data_size);
            try writer.writeInt(
                u32,
                size_to_write,
                .little,
            ); // Overwritten by finalize().
            try writer.writeAll("WAVE");

            try writer.writeAll("fmt ");
            try writer.writeInt(
                u32,
                @sizeOf(@TypeOf(self.fmt)),
                .little,
            );
            try writer.writeStruct(self.fmt, .little);

            try writer.writeAll("data");
            try writer.writeInt(
                u32,
                @intCast(data_size),
                .little,
            );
        }
    };
}

/// Intended as a simple entry point for a basic use case where a sample buffer
/// is already filled and ready to be serialized.
/// One-shot build the encoder, write the header and then write all the samples
/// in the sample buffer to the writer.
pub fn write_wav(
    writer: *std.Io.Writer,
    /// supported encodings.  f32 implies the ieee_float encoding, otherwise
    /// pcm
    comptime fmt: enum { u8, i16, i24, f32 },
    samplerate: usize,
    channels: usize,
    /// type of the sample buffer
    comptime SampleType: type,
    /// array of samples to encode and write
    sample_buffer: []SampleType,
) !void
{
    var enc = try Encoder(
        switch(fmt) {
            .u8 => u8,
            .i16 => i16,
            .i24 => i24,
            .f32 => f32,
        }
    ).init(
        samplerate,
        channels,
    );

    try enc.write_header(writer, sample_buffer.len);
    try enc.write_samples(writer, SampleType, sample_buffer);
}

test "pcm(bits=8) sample_rate=22050 channels=1" 
{
    // @TODO: use the build to find the test data
    var file = try std.fs.cwd().openFile(
        "test/pcm8_22050_mono.wav",
        .{},
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    try std.testing.expectEqual(
        @as(usize, 22050),
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        wav_decoder.fmt.channels,
    );
    try std.testing.expectEqual(
        @as(usize, 8),
        wav_decoder.fmt.bits_per_sample,
    );
    try std.testing.expectEqual(
        @as(usize, 104676),
        wav_decoder.remaining_samples(),
    );

    var buf: [64]f32 = undefined;
    while (true) 
    {
        if (
            try wav_decoder.read_samples(
                &f_reader.interface,
                f32,
                &buf,
            ) < buf.len
        ) 
        {
            break;
        }
    }
}

test "pcm(bits=16) sample_rate=44100 channels=2" 
{
    const data_len: usize = 312542;

    var file = try std.fs.cwd().openFile(
        "test/pcm16_44100_stereo.wav",
        .{},
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    try std.testing.expectEqual(
        @as(usize, 44100),
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        wav_decoder.fmt.channels,
    );

    try std.testing.expectEqual(
        @as(usize, data_len),
        wav_decoder.remaining_samples(),
    );
    try std.testing.expectEqual(
        .pcm, 
        wav_decoder.fmt.code
    );
    try std.testing.expectEqual(
        16, 
        wav_decoder.fmt.bits_per_sample,
    );

    const buf = try std.testing.allocator.alloc(i16, data_len);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(
        data_len,
        try wav_decoder.read_samples(
            &f_reader.interface,
            i16,
            buf,
        ),
    );
    try std.testing.expectEqual(
        0,
        wav_decoder.remaining_samples(),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try wav_decoder.read_samples(
            &f_reader.interface,
            i16,
            buf,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        wav_decoder.remaining_samples(),
    );
}

test "pcm(bits=24) sample_rate=48000 channels=1" 
{
    var file = try std.fs.cwd().openFile(
        "test/pcm24_48000_mono.wav",
        .{},
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    try std.testing.expectEqual(
        @as(usize, 48000),
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        wav_decoder.fmt.channels,
    );
    try std.testing.expectEqual(
        @as(usize, 24),
        wav_decoder.fmt.bits_per_sample,
    );
    try std.testing.expect(f_reader.atEnd() == false);
    try std.testing.expectEqual(
        @as(usize, 508800),
        wav_decoder.remaining_samples(),
    );

    var buf: [1]f32 = undefined;
    var i: usize = 0;
    while (i < 1000) 
        : (i += 1) 
    {
        try std.testing.expectEqual(
            @as(usize, 1),
            try wav_decoder.read_samples(
                &f_reader.interface,
                f32,
                &buf,
            ),
        );
    }
    try std.testing.expectEqual(
        @as(usize, 507800),
        wav_decoder.remaining_samples(),
    );

    while (true) 
    {
        const samples_read = try wav_decoder.read_samples(
            &f_reader.interface,
            f32,
            &buf,
        );

        if (samples_read == 0) 
        {
            break;
        }
        try std.testing.expectEqual(
            @as(usize, 1),
            samples_read,
        );
    }
}

test "pcm(bits=24) sample_rate=44100 channels=2" 
{
    var file = try std.fs.cwd().openFile(
        "test/pcm24_44100_stereo.wav",
        .{},
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    try std.testing.expectEqual(
        @as(usize, 44100),
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        wav_decoder.fmt.channels,
    );
    try std.testing.expectEqual(
        @as(usize, 24),
        wav_decoder.fmt.bits_per_sample,
    );
    try std.testing.expectEqual(
        @as(usize, 157952),
        wav_decoder.remaining_samples()
    );

    var buf: [1]f32 = undefined;
    while (true) 
    {
        const samples_read = try wav_decoder.read_samples(
            &f_reader.interface,
            f32,
            &buf,
        );
        if (samples_read == 0) 
        {
            break;
        }
        try std.testing.expectEqual(
            @as(usize, 1),
            samples_read,
        );
    }
}

test "ieee_float(bits=32) sample_rate=48000 channels=2" 
{
    var file = try std.fs.cwd().openFile(
        "test/float32_48000_stereo.wav",
        .{},
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;

    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    try std.testing.expectEqual(
        @as(usize, 48000),
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        wav_decoder.fmt.channels,
    );
    try std.testing.expectEqual(
        @as(usize, 32),
        wav_decoder.fmt.bits_per_sample,
    );
    try std.testing.expectEqual(
        @as(usize, 592342),
        wav_decoder.remaining_samples()
    );

    var buf: [64]f32 = undefined;
    while (true) {
        if (
            try wav_decoder.read_samples(
                &f_reader.interface,
                f32,
                &buf,
            ) < buf.len
        ) 
        {
            break;
        }
    }
}

test "ieee_float(bits=32) sample_rate=96000 channels=2" 
{
    var file = try std.fs.cwd().openFile(
        "test/float32_96000_stereo.wav",
        .{}
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    try std.testing.expectEqual(
        @as(usize, 96000),
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        wav_decoder.fmt.channels,
    );
    try std.testing.expectEqual(
        @as(usize, 32),
        wav_decoder.fmt.bits_per_sample,
    );
    try std.testing.expectEqual(
        @as(usize, 67744),
        wav_decoder.remaining_samples(),
    );

    var buf: [64]f32 = undefined;
    while (true) 
    {
        if (
            try wav_decoder.read_samples(
                &f_reader.interface,
                f32,
                &buf,
            ) < buf.len
        ) 
        {
            break;
        }
    }

    try std.testing.expectEqual(
        @as(usize, 0),
        wav_decoder.remaining_samples(),
    );
}

test "error truncated" 
{
    var file = try std.fs.cwd(
        ).openFile("test/error-trunc.wav",
        .{},
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    var buf: [3000]f32 = undefined;
    try std.testing.expectError(
        error.EndOfStream,
        wav_decoder.read_samples(
            &f_reader.interface,
            f32,
            &buf,
        ),
    );
}

test "error data_size too big" 
{
    var file = try std.fs.cwd().openFile(
        "test/error-data_size1.wav",
        .{}
    );
    defer file.close();

    var rbuf:[1024]u8 = undefined;
    var f_reader = file.reader(&rbuf);

    var wav_decoder = try Decoder.init(&f_reader.interface);

    var buf: [1]i24 = undefined;
    var i: usize = 0;
    while (i < 44100) 
        : (i += 1) 
    {
        try std.testing.expectEqual(
            @as(usize, 1),
            try wav_decoder.read_samples(
                &f_reader.interface,
                i24,
                &buf
            )
        );
    }
    try std.testing.expectError(
        error.EndOfStream,
        wav_decoder.read_samples(
            &f_reader.interface,
            i24,
            &buf,
        ),
    );
}

/// test encoding and then decoding a file at the specific sample type and
/// sample rate
fn test_encode_decode(
    allocator: std.mem.Allocator,
    comptime SampleType: type,
    comptime sample_rate: usize,
) !void 
{
    // @TODO: collapse this w/ generate_sine

    const twopi = std.math.pi * 2.0;
    const freq = 440.0;
    const secs = 3;
    const increment = freq / @as(f32, @floatFromInt(sample_rate)) * twopi;
    const nchannels = 1;

    var buf = try allocator.alloc(
        u8,
        (
            // data (1 channel) + size of Data
            (sample_rate * byte_size_of(SampleType) * (secs) * nchannels) + 2
            // RIFF WAVE
            + 2 
            // header + a bit of extra space for the size of header and size of
            // the data
            + byte_size_of(FormatInfo) + 1
            + 23
        ),
    );
    defer allocator.free(buf);

    var writer = std.Io.Writer.fixed(buf);
    var wav_encoder = try Encoder(SampleType).init(
        sample_rate,
        nchannels,
    );

    try wav_encoder.write_header(
        &writer,
        // will write a header later after all the samples have been serialized
        0,
    );

    var phase: f32 = 0.0;
    var i: usize = 0;
    while (i < secs * sample_rate) 
        : (i += 1) 
    {
        const value: [1]f32 = .{ std.math.sin(phase) };
        try wav_encoder.write_samples(
            &writer,
            f32,
            &value,
        );
        phase += increment;
    }

    try writer.flush();

    try std.testing.expectEqualStrings(
        buf[0..4], 
        "RIFF",
    );

    const total_size_header:u32 = 44;
    try std.testing.expectEqualSlices(
        u8,
        buf[4..8], 
        std.mem.asBytes(&total_size_header),
    );

    try std.testing.expectEqualStrings(
        "WAVE",
        buf[8..12], 
    );

    // write the header after
    var header_writer = std.Io.Writer.fixed(buf);
    try wav_encoder.write_header(
        &header_writer,
        wav_encoder.samples_written,
    );
    try header_writer.flush();

    try std.testing.expectEqualStrings(
        buf[0..4], 
        "RIFF",
    );

    const read_size = std.mem.readInt(
        u32,
        buf[4..8],
        .little,
    );
    const total_size = (
        44 + secs * byte_size_of(SampleType) * sample_rate
    );
    try std.testing.expectEqual(
        read_size,
        total_size,
    );

    try std.testing.expectEqualStrings(
        "WAVE",
        buf[8..12], 
    );

    try std.testing.expectEqualStrings(
        "fmt ",
        buf[12..16], 
    );

    var read_stream = std.Io.Reader.fixed(buf);

    var wav_decoder = try Decoder.init(&read_stream);
    try std.testing.expectEqual(
        sample_rate,
        wav_decoder.fmt.sample_rate,
    );
    try std.testing.expectEqual(
        1,
        wav_decoder.fmt.channels,
    );
    try std.testing.expectEqual(
        secs * sample_rate,
        wav_decoder.remaining_samples(),
    );

    phase = 0.0;
    i = 0;
    while (i < secs * sample_rate) 
        : (i += 1) 
    {
        errdefer std.debug.print("[{d}] phase: {d}\n", .{i, phase});
        var value: [1]f32 = undefined;
        try std.testing.expectEqual(
            try wav_decoder.read_samples(
                &read_stream,
                f32,
                &value,
            ),
            1,
        );

        try std.testing.expectApproxEqAbs(
            std.math.sin(phase),
            value[0],
            0.0001,
        );
        phase += increment;
    }

    try std.testing.expectEqual(
        @as(usize, 0),
        wav_decoder.remaining_samples(),
    );
}

test "encode-decode sine" 
{
    const allocator = std.testing.allocator;

    inline for (
        &.{ 
            .{ f32, 44100 },
            .{ f32, 48000 },
            .{ i24, 48000 },
            .{ i24, 44100 },
            .{ i16, 48000 },
            .{ i16, 44100 },
        },
    ) |spec|
    {
        try test_encode_decode(
            allocator,
            spec[0],
            spec[1],
        );
    }
}

test "sine example test"
{
    // for testsing
    const alloc = std.testing.allocator;

    const SampleType = f32;

    // describe the wav data
    const sample_rate = 44100;
    const num_channels = 1;
    const duration_seconds = 10;
    const nsamples = (
        duration_seconds * sample_rate * num_channels
    );
    
    // generate the samples
    const sample_buffer = try alloc.alloc(SampleType, nsamples);
    defer alloc.free(sample_buffer);

    utils.generate_sine(
        SampleType,
        @floatFromInt(sample_rate),
        sample_buffer,
        .{},
    );

    // open a file handle for writing
    const tmpdir = std.testing.tmpDir(.{});
    var file = try tmpdir.dir.createFile(
        "givemeasine.wav",
        .{}
    );
    defer file.close();

    var buf:[1024]u8 = undefined;
    var f_writer = file.writer(&buf);

    // Encode samples as 16-bit PCM int.
    var encoder = try Encoder(i16).init(
        sample_rate,
        num_channels,
    );
    try encoder.write_header(&f_writer.interface, nsamples);
    try encoder.write_samples(&f_writer.interface, SampleType, sample_buffer);
    try f_writer.interface.flush();
}

test "open and read each audio file"
{
    const allocator = std.testing.allocator;

    const FILES:[]const []const u8 = &.{
        "test/pcm8_22050_mono.wav",
        "test/pcm24_48000_mono.wav",
        "test/pcm24_44100_stereo.wav",
        "test/pcm16_44100_stereo.wav",
        "test/float32_96000_stereo.wav",
        "test/float32_48000_stereo.wav",
    };

    inline for (&.{ u8, i16, i24, f32 })
        |DestType|
    {
        for (FILES)
            |fname|
        {
            var file = try std.fs.cwd().openFile(
                fname,
                .{},
            );
            defer file.close();

            var buf:[1024]u8 = undefined;
            var f_reader = file.reader(&buf);
            var dec = try Decoder.init(&f_reader.interface);

            const outbuf = try allocator.alloc(
                DestType,
                dec.remaining_samples(),
            );
            const initial_samples = dec.remaining_samples();
            defer allocator.free(outbuf);

            const samples_read =  try dec.read_samples(
                &f_reader.interface,
                DestType,
                outbuf,
            );

            try std.testing.expectEqual(
                samples_read,
                initial_samples,
            );
            try std.testing.expectEqual(
                0,
                dec.remaining_samples()
            );

            try std.testing.expectEqual(
                0,
                dec.read_samples(
                    &f_reader.interface,
                    DestType,
                    outbuf[0..1],
                )
            );

            const tmpdir = std.testing.tmpDir(.{});

            // write back out
            {
                var out_file = try tmpdir.dir.createFile(
                    "result.wav",
                    .{}
                );
                defer out_file.close();

                var w_out = out_file.writer(&buf);
                var enc = try Encoder(DestType).init(
                    dec.fmt.sample_rate,
                    dec.fmt.channels,
                );

                try enc.write_header(
                    &w_out.interface,
                    outbuf.len,
                );

                try enc.write_samples(&w_out.interface, DestType, outbuf);
                try w_out.interface.flush();
            }

            // read it back in
            {
                var test_file = try tmpdir.dir.openFile(
                    "result.wav",
                    .{}
                );
                defer test_file.close();

                var r_test = test_file.reader(&buf);
                var dec_test = try Decoder.init(&r_test.interface);

                try std.testing.expectEqual(
                    initial_samples,
                    dec_test.remaining_samples(),
                );

                const second_outbuf = try allocator.alloc(
                    DestType,
                    initial_samples,
                );
                defer allocator.free(second_outbuf);

                const samples_read_second = try dec_test.read_samples(
                    &r_test.interface,
                    DestType,
                    second_outbuf,
                );

                try std.testing.expectEqual(
                    0,
                    dec.remaining_samples(),
                );

                try std.testing.expectEqual(
                    initial_samples,
                    samples_read_second,
                );

                errdefer std.debug.print(
                    "Error: {s} / {s}\n",
                    .{fname, @typeName(DestType)},
                );

                try std.testing.expectEqualSlices(
                    DestType, 
                    outbuf,
                    second_outbuf,
                );
            }
        }
    }
}

test "write_wav / read_wav test"
{
    const DecodedSampleType = f32;

    // describe the wav data
    const sample_rate = 44100;
    const num_channels = 1;
    const duration_seconds = 10;
    const nsamples = (
        duration_seconds * sample_rate * num_channels
    );
    
    // generate the samples
    var sample_buffer: [nsamples]DecodedSampleType = undefined;

    utils.generate_sine(
        DecodedSampleType,
        @floatFromInt(sample_rate),
        &sample_buffer,
        .{},
    );
    // open a file handle for writing
    const tmpdir = std.testing.tmpDir(.{});

    // write test
    {
        var file = try tmpdir.dir.createFile(
            "sine.wav",
            .{},
        );
        defer file.close();

        var buf:[1024]u8 = undefined;
        var f_writer = file.writer(&buf);

        try write_wav(
            &f_writer.interface,
            .f32,
            sample_rate,
            num_channels,
            f32,
            &sample_buffer,
        );

        try f_writer.interface.flush();
    }

    // read_wav test
    {
        var file = try tmpdir.dir.openFile(
            "sine.wav",
            .{},
        );
        defer file.close();

        var buf:[1024]u8 = undefined;
        var reader = file.reader(&buf);

        var decoded_sample_buffer:[nsamples]DecodedSampleType = undefined;

        const read_samples = try read_wav(
            &reader.interface,
            DecodedSampleType,
            &decoded_sample_buffer,
        );

        try std.testing.expectEqual(
            nsamples,
            read_samples,
        );
        try std.testing.expectEqualSlices(
            DecodedSampleType,
            &sample_buffer,
            &decoded_sample_buffer,
        );
    }
}

/// Intended as a simple entry point for a basic use case where the entire contents
/// of the reader is to be decoded and converted into the `decoded_buffer`.
///
/// Will create a Decoder and use it to fill `decoded_buffer`.
pub fn read_wav(
    reader: *std.Io.Reader,
    /// Type to decode samples into.
    comptime DecodedType: type,
    decoded_buffer: []DecodedType,
) !usize
{
    var dec = try Decoder.init(reader);

    return try dec.read_samples(
        reader,
        DecodedType,
        decoded_buffer,
    );
}
