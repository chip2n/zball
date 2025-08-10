const std = @import("std");
const root = @import("root");
const settings = @import("settings.zig");

const sokol = @import("sokol");
const saudio = sokol.audio;

const sample_buf_length = 4096;

const AudioHandle = usize;

const AudioCategory = enum { sfx, bg };

const AudioClip = enum {
    bounce,
    explode,
    powerup,
    death,
    laser,
    clink,
    coin,
    reveal,
};

const clips = std.enums.EnumArray(AudioClip, WavData).init(.{
    .bounce = embed("assets/bounce.wav"),
    .explode = embed("assets/explode.wav"),
    .powerup = embed("assets/powerup.wav"),
    .death = embed("assets/death.wav"),
    .laser = embed("assets/laser.wav"),
    .clink = embed("assets/clink.wav"),
    .coin = embed("assets/coin.wav"),
    .reveal = embed("assets/reveal.wav"),
});

var state = AudioState{};

pub fn init() void {
    saudio.setup(.{
        .num_channels = 2,
        .buffer_frames = 512, // lowers audio latency
        .stream_cb = stream_callback,
        .logger = .{ .func = sokol.log.func },
    });
    state.num_channels = @intCast(saudio.channels()); // may be different than requested
}

fn stream_callback(buffer: [*c]f32, num_frames: i32, num_chan: i32) callconv(.c) void {
    const num_samples: usize = @intCast(num_frames * num_chan);

    const dst = buffer[0..num_samples];

    // Clear out sample buffer
    for (dst) |*s| s.* = 0.0;

    for (&state.playing) |*p| {
        if (p.clip == null) continue;
        const clip = clips.get(p.clip.?);
        const count = writeSamples(clip, p.frame, @as(usize, @intCast(num_frames)), dst, p.volume());
        p.frame += count;

        if (p.frame >= clip.frameCount()) {
            if (p.loop) {
                // TODO I don't think this is a perfect loop
                p.frame = 0;
            } else {
                p.clip = null;
                p.frame = 0;
            }
        }
    }
}

pub fn deinit() void {
    saudio.shutdown();
}

pub inline fn update(time: f64) void {
    state.update(time);
}

pub const PlayDesc = struct {
    clip: AudioClip,
    loop: bool = false,
    vol: f32 = 1.0,
    category: AudioCategory = .sfx,
};
pub inline fn play(v: PlayDesc) void {
    state.play(v);
}

const AudioTrack = struct {
    clip: ?AudioClip = null,
    frame: usize = 0,
    loop: bool = false,
    vol: f32 = 1.0,

    fn volume(track: AudioTrack) f32 {
        return track.vol * settings.vol_sfx;
    }
};

pub const AudioState = struct {
    const Self = @This();

    num_channels: usize = 2,
    time: f64 = 0,
    samples: [sample_buf_length]f32 = undefined,
    playing: [32]AudioTrack = .{AudioTrack{}} ** 32,

    fn play(self: *Self, v: PlayDesc) void {
        // Check if we've played this clip recently - if we have, ignore it
        for (&self.playing) |p| {
            if (p.clip == v.clip and p.frame < 1000) return;
        }
        for (&self.playing) |*p| {
            if (p.clip != null) continue;
            p.clip = v.clip;
            p.frame = 0;
            p.loop = v.loop;
            p.vol = v.vol;
            break;
        }
    }
};

fn writeSamples(
    clip: WavData,
    frame_offset: usize,
    frame_count: usize,
    output: []f32,
    volume: f32,
) usize {
    const clip_samples = clip.samples();
    const sample_offset = frame_offset * clip.format.nbrChannels;
    const frames_left = @divExact(clip_samples.len, clip.format.nbrChannels) - frame_offset;
    const frames_to_write = @min(sample_buf_length, @min(frame_count, frames_left));

    const src = clip_samples[sample_offset .. sample_offset + frames_to_write * clip.format.nbrChannels];
    const dst = output[0 .. frames_to_write * state.num_channels];

    for (src, 0..) |s, i| {
        const fs: f32 = @floatFromInt(s);
        const div: usize = if (fs < 0) @abs(std.math.minInt(i16)) else std.math.maxInt(i16);
        const result = (fs / @as(f32, @floatFromInt(div)));
        std.debug.assert(-1 <= result and result <= 1);
        if (clip.format.nbrChannels == 1) {
            dst[i * state.num_channels + 0] += result * volume;
            dst[i * state.num_channels + 1] += result * volume;
        } else if (clip.format.nbrChannels == 2) {
            dst[i] += result * volume;
        } else unreachable;
    }

    return frames_to_write;
}

// * Wav parsing

const riff_magic = std.mem.bytesToValue(u32, "RIFF");
const wav_magic = std.mem.bytesToValue(u32, "WAVE");
const fmt_magic = std.mem.bytesToValue(u32, "fmt ");
const data_magic = std.mem.bytesToValue(u32, "data");

const MasterRiffChunk = packed struct {
    // zig fmt: off
    fileTypeBlocID : u32, // Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
    fileSize       : u32, // Overall file size minus 8 bytes
    fileFormatID   : u32, // Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)
    // zig fmt: on

    const byte_size = @divExact(@bitSizeOf(@This()), 8);
};

const WavFormatChunk = packed struct {
    // zig fmt: off
    formatBlocID   : u32, // Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
    blocSize       : u32, // Chunk size minus 8 bytes  (0x10)
    audioFormat    : u16, // Audio format (1: PCM integer, 3: IEEE 754 float)
    nbrChannels    : u16, // Number of channels
    frequence      : u32, // Sample rate (in hertz)
    bytePerSec     : u32, // Number of bytes to read per second (Frequence * BytePerBloc).
    bytePerBloc    : u16, // Number of bytes per block (NbrChannels * BitsPerSample / 8).
    bitsPerSample  : u16, // Number of bits per sample
    // zig fmt: on

    const byte_size = @divExact(@bitSizeOf(@This()), 8);
};

pub const WavData = struct {
    file_size: u32,
    format: WavFormatChunk,
    data: []const u8,

    fn frameCount(self: WavData) usize {
        return @divExact(self.samples().len, self.format.nbrChannels);
    }

    fn samples(self: WavData) []align(1) const i16 {
        // TODO depends on header
        return std.mem.bytesAsSlice(i16, self.data);
    }
};

pub fn parse(data: []const u8) !WavData {
    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    const file_type_bloc_id = try reader.readInt(u32, .little);
    if (file_type_bloc_id != riff_magic) return error.InvalidWav;

    const file_size = try reader.readInt(u32, .little);

    const file_format_id = try reader.readInt(u32, .little);
    if (file_format_id != wav_magic) return error.InvalidWav;

    var chunk: WavFormatChunk = undefined;
    const bytes = try reader.readBytesNoEof(WavFormatChunk.byte_size);
    @memcpy(std.mem.asBytes(&chunk)[0..WavFormatChunk.byte_size], bytes[0..WavFormatChunk.byte_size]);

    if (chunk.formatBlocID != fmt_magic) return error.InvalidWav;
    if (chunk.blocSize < 16) return error.InvalidWav;
    if (chunk.bytePerSec != chunk.frequence * chunk.bytePerBloc) return error.InvalidWav;
    if (chunk.bytePerBloc != chunk.nbrChannels * chunk.bitsPerSample / 8) return error.InvalidWav;

    try reader.skipBytes(chunk.blocSize - (WavFormatChunk.byte_size - 8), .{});

    while (true) {
        const chunk_id = try reader.readInt(u32, .little);
        const chunk_size = try reader.readInt(u32, .little);
        if (chunk_id != data_magic) {
            // We ignore chunks that are not data chunks
            try reader.skipBytes(chunk_size, .{});
            continue;
        }
        const samples_start = fbs.pos;
        const samples = data[samples_start .. samples_start + chunk_size];
        return .{ .file_size = file_size, .format = chunk, .data = samples };
    }
}

pub fn embed(comptime path: []const u8) WavData {
    const data = @embedFile(path);
    return parse(data) catch @compileError("Invalid wav data: " ++ path);
}

test "parse wav" {
    const data = @embedFile("assets/bounce.wav");
    const result = try parse(data);
    const format = result.format;
    const samples = result.data;

    const expected_format = WavFormatChunk{
        .formatBlocID = fmt_magic,
        .blocSize = 16,
        .audioFormat = 1,
        .nbrChannels = 1,
        .frequence = 44100,
        .bytePerSec = 88200,
        .bytePerBloc = 2,
        .bitsPerSample = 16,
    };
    try std.testing.expectEqual(14938, result.file_size);
    try std.testing.expectEqual(expected_format, format);
    try std.testing.expectEqual(14902, samples.len);
}
