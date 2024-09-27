const std = @import("std");
const root = @import("root");

const sokol = @import("sokol");
const saudio = sokol.audio;

const num_channels = 2;
const sample_buf_length = 4096; // TODO
const sample_rate = 44100; // TODO

const AudioHandle = usize;

pub const audio_data = .{
    .bounce = embed("assets/bounce.wav"),
    .explode = embed("assets/explode.wav"),
    .powerup = embed("assets/powerup.wav"),
    .death = embed("assets/death.wav"),
    .music = embed("assets/music.wav"),
};

const AudioCategory = enum { sfx, bg };

const AudioClip = std.meta.FieldEnum(@TypeOf(audio_data));

const clips = std.enums.EnumArray(AudioClip, WavData).init(audio_data);

var state = AudioState{};

pub fn init() void {
    saudio.setup(.{
        // TODO: The sample_rate and num_channels parameters are only hints for
        // the audio backend, it isn't guaranteed that those are the values used
        // for actual playback.
        .num_channels = 2,
        .buffer_frames = 512, // lowers audio latency (TODO shitty on web though)
        .stream_cb = stream_callback,
        .logger = .{ .func = sokol.log.func },
    });
}

fn stream_callback(buffer: [*c]f32, num_frames: i32, num_chan: i32) callconv(.C) void {
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

pub var vol_bg: f32 = 0.5;
pub var vol_sfx: f32 = 0.5;

const AudioTrack = struct {
    clip: ?AudioClip = null,
    frame: usize = 0,
    loop: bool = false,
    vol: f32 = 1.0,
    category: AudioCategory = .sfx,

    fn volume(track: AudioTrack) f32 {
        const cat_vol = switch (track.category) {
            .bg => vol_bg,
            .sfx => vol_sfx,
        };
        return track.vol * cat_vol;
    }
};

pub const AudioState = struct {
    const Self = @This();

    time: f64 = 0,
    samples: [sample_buf_length]f32 = undefined,
    playing: [16]AudioTrack = .{.{}} ** 16,

    fn play(self: *Self, v: PlayDesc) void {
        // Check if we've played this clip recently - if we have, ignore it
        for (&self.playing) |p| {
            if (p.clip == v.clip and p.frame == 0) return;
        }
        for (&self.playing) |*p| {
            if (p.clip != null) continue;
            p.clip = v.clip;
            p.frame = 0;
            p.loop = v.loop;
            p.vol = v.vol;
            p.category = v.category;
            break;
        } else {
            return;
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
    const sample_offset = frame_offset * clip.header.nbrChannels;
    const frames_left = @divExact(clip_samples.len, clip.header.nbrChannels) - frame_offset;
    const frames_to_write = @min(sample_buf_length, @min(frame_count, frames_left)); // TODO rename sample_buf_length?

    const src = clip_samples[sample_offset .. sample_offset + frames_to_write * clip.header.nbrChannels];
    const dst = output[0 .. frames_to_write * num_channels];

    for (src, 0..) |s, i| {
        const fs: f32 = @floatFromInt(s);
        const div: usize = if (fs < 0) @abs(std.math.minInt(i16)) else std.math.maxInt(i16);
        const result = (fs / @as(f32, @floatFromInt(div)));
        std.debug.assert(-1 <= result and result <= 1);
        if (clip.header.nbrChannels == 1) {
            dst[i * num_channels + 0] += result * volume;
            dst[i * num_channels + 1] += result * volume;
        } else if (clip.header.nbrChannels == 2) {
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

const WavHeader = packed struct {
    // zig fmt: off

    // [Master RIFF chunk]
    fileTypeBlocID : u32, // Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
    fileSize       : u32, // Overall file size minus 8 bytes
    fileFormatID   : u32, // Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)

    // [Chunk describing the data format]
    formatBlocID   : u32, // Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
    blocSize       : u32, // Chunk size minus 8 bytes  (0x10)
    audioFormat    : u16, // Audio format (1: PCM integer, 3: IEEE 754 float)
    nbrChannels    : u16, // Number of channels
    frequence      : u32, // Sample rate (in hertz)
    bytePerSec     : u32, // Number of bytes to read per second (Frequence * BytePerBloc).
    bytePerBloc    : u16, // Number of bytes per block (NbrChannels * BitsPerSample / 8).
    bitsPerSample  : u16, // Number of bits per sample

   // [Chunk containing the sampled data]
    dataBlocID     : u32, // Identifier « data »  (0x64, 0x61, 0x74, 0x61)
    dataSize       : u32, // SampledData size

    // zig fmt: on

    const byte_size = @bitSizeOf(WavHeader) / @bitSizeOf(u8);

    comptime {
        std.debug.assert(byte_size == 44);
    }
};

pub const WavData = struct {
    header: WavHeader,
    data: []const u8,

    fn frameCount(self: WavData) usize {
        return @divExact(self.samples().len, self.header.nbrChannels);
    }

    fn samples(self: WavData) []align(1) const i16 {
        // TODO depends on header
        return std.mem.bytesAsSlice(i16, self.data);
    }
};

pub fn parse(data: []const u8) error{InvalidWav}!WavData {
    if (data.len < WavHeader.byte_size) return error.InvalidWav;
    const header = std.mem.bytesToValue(WavHeader, data.ptr);
    if (header.fileTypeBlocID != riff_magic) return error.InvalidWav;
    if (header.fileFormatID != wav_magic) return error.InvalidWav;
    if (header.formatBlocID != fmt_magic) return error.InvalidWav;
    if (header.blocSize != 16) return error.InvalidWav; // TODO
    if (header.dataBlocID != data_magic) return error.InvalidWav;
    if (header.bytePerSec != header.frequence * header.bytePerBloc) return error.InvalidWav;
    if (header.bytePerBloc != header.nbrChannels * header.bitsPerSample / 8) return error.InvalidWav;

    const samples = data[WavHeader.byte_size .. WavHeader.byte_size + header.dataSize];
    return .{ .header = header, .data = samples };
}

pub fn embed(comptime path: []const u8) WavData {
    const data = @embedFile(path);
    return parse(data) catch @compileError("Invalid wav data: " ++ path);
}

test "parse wav" {
    const data = @embedFile("assets/bounce.wav");
    const result = try parse(data);
    const header = result.header;
    const samples = result.data;

    const expected = WavHeader{
        .fileTypeBlocID = riff_magic,
        .fileSize = 15940,
        .fileFormatID = wav_magic,
        .formatBlocID = fmt_magic,
        .blocSize = 16,
        .audioFormat = 1,
        .nbrChannels = 1,
        .frequence = 44100,
        .bytePerSec = 88200,
        .bytePerBloc = 2,
        .bitsPerSample = 16,
        .dataBlocID = data_magic,
        .dataSize = 15904,
    };
    try std.testing.expectEqual(expected, header);
    try std.testing.expectEqual(15904, samples.len);
}
