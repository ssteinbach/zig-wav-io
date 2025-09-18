# zig-wav-io Library

Simple wav decoding + encoding in Zig.  Originally a fork of the
[veloscillator/zig-wav](https://github.com/veloscillator/zig-wav) library.

## Features

- Using the post-writergate Reader/Writer interface, decode/encode wav data.
- Simple interface.
- Convert samples to desired type while reading to avoid extra steps.
- Fail gracefully on bad input.
- Utilities for interleaving/deinterleaving samples and generating sine waves

## Usage

Requires zig 0.15.1.

Add `zig-wav-io` to your `build.zig.zon`:
```bash
zig fetch --save "git+https://github.com/ssteinbach/zig-wav-io.git"
```

Add to your `build.zig`:
```zig
    const wav_dep = b.dependency(
        "wav_io",
        .{
            .target = options.target,
            .optimize = options.optimize,
        },
    ).module("wav_io");

    // ... to expose the import to the module
    my_module.addImport("wav_io", wav_dep);
```

See the unit tests and [src/demo.zig](src/demo.zig) for more examples.  To run
the demo program, use `zig build run`.  This will generate and read a file
named "sine.wav".

### Decoding

```zig
const std = @import("std");
const wav_io = @import("wav_io");

pub fn main(
) !void 
{
    // open the file
    var file = try std.fs.cwd().openFile("sine.wav", .{});
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
```

### Encoding

There are two ways to encode a file.  One presumes there is a pre-computed
buffer of samples up front, while the other does not have that restriction.

#### Pre Computed Buffer

Given an already full sample buffer,the `write_wav` function can be used to
serialize a sample buffer directly to a writer.

```zig
const std = @import("std");
const wav_io = @import("wav_io");

/// Generate mono wav file that plays 10 second sine wave.
pub fn main(
) !void 
{
    const SampleType = f32;

    // describe the wav data
    const sample_rate = 44100;
    const num_channels = 1;
    const duration_seconds = 10;
    const nsamples = (
        duration_seconds * sample_rate * num_channels
    );
    
    // generate the samples
    const sample_buffer:[nsamples]SampleType;

    wav_io.utils.generate_sine(
        SampleType,
        @floatFromInt(sample_rate),
        sample_buffer,
    );

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
```

#### Encoder Interface

Alternatively, you can use the Encoder struct to serialize samples.

```zig
const std = @import("std");
const wav_io = @import("wav_io");

/// Generate mono wav file that plays 10 second sine wave.
pub fn main(
) !void 
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const SampleType = f32;

    // describe the wav data
    const sample_rate = 44100;
    const num_channels = 1;
    const duration_seconds = 10;
    const nsamples = (
        duration_seconds * sample_rate * num_channels
    );

    var file = try std.fs.cwd().createFile("givemeasine.wav", .{});
    defer file.close();

    // generate the samples
    const sample_buffer = try alloc.alloc(SampleType, nsamples);
    defer alloc.free(sample_buffer);

    wav_io.utils.generate_sine(
        SampleType,
        @floatFromInt(sample_rate),
        sample_buffer,
    );

    // open a file handle for writing
    var file = try std.fs.cwd().createFile(
        "sine.wav",
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
    // the header can be re-written later if the number of samples isn't
    // known before hand
    try f_writer.seekTo(0);
    try encoder.write_header(&f_writer.interface, nsamples);
    try f_writer.interface.flush();
}
```


## Demo

Example program that creates a 6 second wav file, 3 seconds of A 440 and 3
seconds of middle C.

```
zig build run
ls -l sine.wav
```

## Future Work

- [ ] Handle `WAVFORMATEXTENSIBLE` format code https://msdn.microsoft.com/en-us/library/ms713497.aspx
- [ ] Handle 32-bit aligned i24.
- [ ] Add dithering option to deal with quantization error.
- [ ] Compile to big-endian target.
- [ ] Handle big-endian wav files.
- [ ] Encode/decode metadata via `LIST`, `INFO`, etc. chunks.
