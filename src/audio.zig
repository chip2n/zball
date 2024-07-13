const std = @import("std");
const root = @import("root");

const sokol = @import("sokol");
const saudio = sokol.audio;

const g_volume = 0.3;
const num_channels = 2;
const sample_buf_length = 81920; // TODO
const sample_rate = 44100; // TODO
// const samples_buf_length = 1000;

const AudioHandle = usize;

pub const audio_data = .{
    .bounce = embed("assets/bounce.wav"),
    .shoot = embed("assets/shoot.wav"),
    .music = embed("assets/music.wav"),
};

const AudioClip = std.meta.FieldEnum(@TypeOf(audio_data));

const clips = std.enums.EnumArray(AudioClip, WavData).init(audio_data);

pub const AudioSystem = struct {
    time: f64 = 0,
    samples: [sample_buf_length]f32 = undefined,
    playing: [16]AudioTrack = .{.{}} ** 16,

    const AudioTrack = struct {
        clip: ?AudioClip = null,
        frame: usize = 0,
        loop: bool = false,
        volume: f32 = 1.0,
    };

    const PlayOptions = struct {
        clip: AudioClip,
        loop: bool = false,
        volume: f32 = 1.0,
    };
    pub fn play(sys: *AudioSystem, v: PlayOptions) void {
        for (&sys.playing) |*p| {
            if (p.clip != null) continue;
            p.clip = v.clip;
            p.frame = 0;
            p.loop = v.loop;
            p.volume = v.volume;
            break;
        } else {
            std.log.warn("Cannot play clip - too many audio clips is playing at the same time.", .{});
            return;
        }
    }

    pub fn update(sys: *AudioSystem, time: f64) void {
        const num_frames: i32 = @intFromFloat(@ceil(sample_rate * (time - sys.time)));
        // const num_samples: i32 = num_frames * num_channels;

        sys.time = time;

        const Sorter = struct {
            fn lessThanFn(_: void, lhs: AudioTrack, rhs: AudioTrack) bool {
                if (lhs.clip == null) return false;
                if (rhs.clip == null) return true;
                const ca = clips.get(lhs.clip.?);
                const cb = clips.get(rhs.clip.?);
                const samples_a = ca.samples();
                const samples_b = cb.samples();
                return samples_a.len - lhs.frame < samples_b.len - rhs.frame;
            }
        };
        std.mem.sort(AudioTrack, &sys.playing, {}, Sorter.lessThanFn);

        // Calculate how many clips are currently playing
        var num_concurrent_clips: usize = 0;
        for (sys.playing) |p| {
            if (p.clip == null) continue;
            num_concurrent_clips += 1;
        }

        // TODO: Sanity check - have we sorted clips correctly?
        for (0..num_concurrent_clips) |i| {
            const p = sys.playing[i];
            std.debug.assert(p.clip != null);
        }

        // Clear out sample buffer
        for (&sys.samples) |*s| s.* = 0.0;

        var num_written: i32 = 0;
        var dst: []f32 = &sys.samples;
        for (0..num_concurrent_clips) |i| {
            var num_written_temp: usize = 0;
            for (i..num_concurrent_clips) |j| {
                var p = &sys.playing[j];
                if (p.clip == null) continue;
                std.debug.assert(p.clip != null);

                const clip = clips.get(p.clip.?);
                const volume = 1 / @as(f32, @floatFromInt(num_concurrent_clips - i));
                const count = writeSamples(clip, p.frame, @as(usize, @intCast(num_frames - num_written)), dst, volume * p.volume);

                // std.log.warn("clip {}: frame: {}, count: {}, vol: {}", .{ j, p.frame, count, volume });

                p.frame += count;

                if (p.frame >= clip.frameCount()) {
                    if (p.loop) {
                        // TODO I don't think this is a perfect loop - we end with just a few samples and not fill all the frames
                        std.log.warn("looping clip", .{});
                        p.frame = 0;
                    } else {
                        std.log.warn("done", .{});
                        p.clip = null;
                        p.frame = 0;
                    }
                }
                num_written_temp = @max(num_written_temp, count);
            }
            num_written += @intCast(num_written_temp);
            dst = sys.samples[@intCast(num_written_temp)..];
        }
        // if (num_written > 0) {
        //     std.log.warn("num: {}", .{num_written});
        //     std.log.warn("----", .{});
        // }

        if (num_frames > 0) {
            _ = saudio.push(&(sys.samples[0]), num_frames);
        }
    }

    fn writeSamples(
        clip: WavData,
        frame_offset: usize,
        frame_count: usize,
        output: []f32,
        volume: f32,
    ) usize {
        const clip_samples = clip.samples();
        // std.debug.assert(std.math.mod(usize, clip_samples.len, clip.header.nbrChannels) catch unreachable == 0);

        const sample_offset = frame_offset * clip.header.nbrChannels;

        const frames_left = @divExact(clip_samples.len, clip.header.nbrChannels) - frame_offset; // TODO this doesn't support 2 channels
        const frames_to_write = @min(sample_buf_length, @min(frame_count, frames_left)); // TODO rename sample_buf_length?

        //std.log.warn("frame_offset: {}, samples_to_write: {}, frame_count: {}", .{ frame_offset, samples_to_write, frame_count });

        const src = clip_samples[sample_offset .. sample_offset + frames_to_write * clip.header.nbrChannels];
        const dst = output[0 .. frames_to_write * num_channels];
        // const dst = output[0..];

        // TODO 2 channels - right now we're reading src as 1 channel
        for (src, 0..) |s, i| {
            const fs: f32 = @floatFromInt(s);
            const div: usize = if (fs < 0) @abs(std.math.minInt(i16)) else std.math.maxInt(i16);
            const result = (fs / @as(f32, @floatFromInt(div)));
            // const result = (fs / @as(f32, @floatFromInt(std.math.maxInt(i16))));
            std.debug.assert(-1 <= result and result <= 1);
            if (clip.header.nbrChannels == 1) {
                dst[i * num_channels + 0] += result * volume * g_volume;
                dst[i * num_channels + 1] += result * volume * g_volume;
            } else if (clip.header.nbrChannels == 2) {
                dst[i] += result * volume * g_volume;
            } else unreachable;
        }

        return frames_to_write;
    }
};

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
    const samples = result.samples;

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
