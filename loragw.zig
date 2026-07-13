const std = @import("std");

const c = @cImport({
    @cInclude("loragw_hal.h");
});

const log = std.log.scoped(.loragw);
const posix = std.posix;

pub const Gps = struct {
    pub const Config = struct {
        path: [:0]const u8,
        baud: posix.speed_t = .B9600,
    };

    file: std.Io.File,
    restore: posix.termios,

    pub fn init(io: std.Io, config: Config) !Gps {
        const file = try std.Io.Dir.openFileAbsolute(io, config.path, .{ .mode = .read_write });
        errdefer file.close(io);

        const restore = try posix.tcgetattr(file.handle);

        var tio = restore;

        tio.ispeed = config.baud;
        tio.ospeed = config.baud;

        tio.cflag.CLOCAL = true;
        tio.cflag.CREAD = true;
        tio.cflag.CSIZE = .CS8;
        tio.cflag.PARENB = false;
        tio.cflag.CSTOPB = false;

        tio.cflag.CLOCAL = true; // possibly ignore modem control lines
        tio.cflag.HUPCL = false; // did you just hang up on me?

        tio.iflag.IGNPAR = true;
        tio.iflag.ICRNL = false;
        tio.iflag.IGNCR = false;
        tio.iflag.IXON = false;
        tio.iflag.IXOFF = false;

        tio.oflag = .{};

        tio.lflag.ICANON = false;
        tio.lflag.ISIG = false;
        tio.lflag.IEXTEN = false;
        tio.lflag.ECHO = false;
        tio.lflag.ECHOE = false;
        tio.lflag.ECHOK = false;

        // We let the io interface decide.
        tio.cc[@intFromEnum(posix.V.MIN)] = 1;
        tio.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(file.handle, .FLUSH, tio);
        errdefer posix.tcsetattr(file.handle, .NOW, restore) catch |e| {
            log.warn("failed to restore tty config: {t}", .{e});
        };

        const timegps: []const u8 = &.{ 0x01, 0x20, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00 };
        var buf: [timegps.len + 8]u8 = undefined;

        try file.writeStreamingAll(io, Ubx.message(0x06, 0x01, timegps, &buf).?);

        return .{ .file = file, .restore = restore };
    }

    pub fn deinit(gps: *const Gps, io: std.Io) void {
        posix.tcsetattr(gps.file.handle, .NOW, gps.restore) catch |e| {
            log.warn("failed to restore tty config: {t}", .{e});
        };

        gps.file.close(io);
    }

    const Ubx = struct {
        fn message(class: u8, id: u8, payload: []const u8, buffer: []u8) ?[]const u8 {
            if (buffer.len < payload.len + 8) return null;

            buffer[0] = 0xB5;
            buffer[1] = 0x62;
            buffer[2] = class;
            buffer[3] = id;

            std.mem.writeInt(u16, buffer[4..6], @intCast(payload.len), .little);
            @memcpy(buffer[6..][0..payload.len], payload);

            var ck_a: u8 = 0;
            var ck_b: u8 = 0;

            for (buffer[2 .. 6 + payload.len]) |byte| {
                ck_a +%= byte;
                ck_b +%= ck_a;
            }

            buffer[6 + payload.len] = ck_a;
            buffer[7 + payload.len] = ck_b;

            return buffer[0 .. payload.len + 8];
        }
    };

    pub const Longitude = struct {
        x: f64,

        pub fn dms(deg: i16, min: u8, sec: f64) !Longitude {
            if (min >= 60) return error.OutOfRange;
            if (sec < 0.0 or sec >= 60.0) return error.OutOfRange;
            if (@abs(deg) > 180) return error.OutOfRange;
            if (@abs(deg) == 180 and (min != 0 or sec != 0.0)) return error.OutOfRange;

            const sign: f64 = if (deg < 0.0) -1.0 else 1.0;
            const fdeg: f64 = @abs(@as(f64, @floatFromInt(deg)));
            const fmin: f64 = @floatFromInt(min);

            return .{ .x = sign * (fdeg + (fmin / 60.0) + (sec / 3600.0)) };
        }

        pub fn parseNmea(slice: []const u8) !Longitude {
            if (slice.len < 9) return error.Overflow;

            const deg: f64 = @floatFromInt(try std.fmt.parseInt(u16, slice[0..3], 10));
            const min: f64 = try std.fmt.parseFloat(f64, slice[3..]);

            if (deg > 180.0) return error.OutOfRange;
            if (min >= 60.0) return error.OutOfRange;

            return .{ .x = deg + (min / 60.0) };
        }

        pub fn format(lon: Longitude, writer: *std.Io.Writer) !void {
            const dir: u8 = if (lon.x >= 0.0) 'E' else 'W';
            const abs = @abs(lon.x);

            const deg = @trunc(abs);
            const tot = (abs - deg) * 60.0;
            const min = @trunc(tot);
            const sec = (tot - min) * 60.0;

            return writer.print("{d}° {d}' {d:.02}'' {c}", .{ deg, min, sec, dir });
        }
    };

    pub const Latitude = struct {
        y: f64,

        pub fn dms(deg: i16, min: u8, sec: f64) !Latitude {
            if (min >= 60) return error.OutOfRange;
            if (sec < 0.0 or sec >= 60.0) return error.OutOfRange;
            if (@abs(deg) > 90) return error.OutOfRange;
            if (@abs(deg) == 90 and (min != 0 or sec != 0.0)) return error.OutOfRange;

            const sign: f64 = if (deg < 0.0) -1.0 else 1.0;
            const fdeg: f64 = @abs(@as(f64, @floatFromInt(deg)));
            const fmin: f64 = @floatFromInt(min);

            return .{ .y = sign * (fdeg + (fmin / 60.0) + (sec / 3600.0)) };
        }

        pub fn parseNmea(slice: []const u8) !Longitude {
            if (slice.len < 8) return error.Overflow;

            const deg: f64 = @floatFromInt(try std.fmt.parseInt(u16, slice[0..2], 10));
            const min: f64 = try std.fmt.parseFloat(f64, slice[2..]);

            if (deg > 90.0) return error.OutOfRange;
            if (min >= 60.0) return error.OutOfRange;

            return .{ .x = deg + (min / 60.0) };
        }

        pub fn format(lat: Latitude, writer: *std.Io.Writer) !void {
            const dir: u8 = if (lat.y >= 0.0) 'N' else 'S';
            const abs = @abs(lat.y);

            const deg = @trunc(abs);
            const tot = (abs - deg) * 60.0;
            const min = @trunc(tot);
            const sec = (tot - min) * 60.0;

            return writer.print("{d}° {d}' {d:.02}'' {c}", .{ deg, min, sec, dir });
        }
    };
};

pub const Radio = struct {
    // NOTE: Semtech for some reason decided to store the radio configuration in global static state.
    // https://github.com/Lora-net/sx1302_hal/blob/4b42025d1751e04632c0b04160e0d29dbbb222a5/libloragw/src/loragw_hal.c#L116-L200
    var claimed: std.atomic.Value(bool) = .init(false);

    pub const Config = struct {
        pub const Com = union(Tag) {
            pub const Tag = enum(c_uint) {
                spi = c.LGW_COM_SPI,
                usb = c.LGW_COM_USB,
            };

            spi: [:0]const u8,
            usb: [:0]const u8,

            pub const serial: Com = .{ .usb = "/dev/ttyACM0" };
        };

        pub const Board = struct {
            com: Com,
            full_duplex: bool = false,
            lorawan_public: bool = false,
        };

        pub const Chip = struct {
            pub const Kind = enum(c_uint) {
                sx1250 = c.LGW_RADIO_TYPE_SX1250,

                pub fn rssi(kind: Kind) f32 {
                    return switch (kind) {
                        .sx1250 => -215.4,
                    };
                }

                pub fn tcomp(kind: Kind) c.lgw_rssi_tcomp_s {
                    return switch (kind) {
                        .sx1250 => .{
                            .coeff_a = 0,
                            .coeff_b = 0,
                            .coeff_c = 20.41,
                            .coeff_d = 2162.56,
                            .coeff_e = 0,
                        },
                    };
                }
            };

            kind: Kind,
            freq: Freq,
            transmitter: bool = false,
            single_input_mode: bool = false,
        };

        pub const Chain = struct {
            chip: u8,
            offset: Freq,
            bandwidth: Bandwidth = .undefined,
            datarate: Datarate = .undefined,
            coderate: Coderate = .undefined,
            sync_size: u8 = 0,
            sync_word: u64 = 0,
        };

        pub const Demod = struct {
            mask: u8,

            pub const all: Demod = .{ .mask = 0xFF };
        };

        board: Board,
        chips: []const Chip = &.{},
        chain: []const Chain = &.{},
        demod: Demod = .all,
    };

    pub fn init(config: Config) !Radio {
        if (claimed.cmpxchgStrong(false, true, .acquire, .monotonic)) |_| {
            return error.Claimed;
        }

        errdefer claimed.store(false, .release);

        var board: c.lgw_conf_board_s = .{
            .lorawan_public = config.board.lorawan_public,
            .full_duplex = config.board.full_duplex,
            .com_type = @intFromEnum(config.board.com),
        };

        const path = switch (config.board.com) {
            inline else => |path| path,
        };

        @memcpy(board.com_path[0..path.len], path);

        if (c.lgw_board_setconf(&board) != c.LGW_HAL_SUCCESS) {
            return error.BoardConfigFailed;
        }

        for (config.chips, 0..) |chip, i| {
            var rxrf: c.lgw_conf_rxrf_s = .{
                .enable = true,
                .freq_hz = @intCast(chip.freq.hertz),
                .rssi_offset = chip.kind.rssi(),
                .rssi_tcomp = chip.kind.tcomp(),
                .type = @intFromEnum(chip.kind),
                .tx_enable = chip.transmitter,
                .single_input_mode = chip.single_input_mode,
            };

            if (c.lgw_rxrf_setconf(@intCast(i), &rxrf) != c.LGW_HAL_SUCCESS) {
                return error.ChainConfigFailed;
            }
        }

        var demod: c.lgw_conf_demod_s = .{ .multisf_datarate = config.demod.mask };

        if (c.lgw_demod_setconf(&demod) != c.LGW_HAL_SUCCESS) {
            return error.DemodConfigFailed;
        }

        for (config.chain, 0..) |chain, i| {
            var rxif: c.lgw_conf_rxif_s = .{
                .enable = true,
                .rf_chain = chain.chip,
                .freq_hz = @intCast(chain.offset.hertz),
                .bandwidth = @intFromEnum(chain.bandwidth),
                .datarate = @intFromEnum(chain.datarate),
                .sync_word = chain.sync_word,
                .sync_word_size = chain.sync_size,
                // TODO: moar fields
            };

            if (c.lgw_rxif_setconf(@intCast(i), &rxif) != c.LGW_HAL_SUCCESS) {
                return error.MultiSFConfigFailed;
            }
        }

        if (c.lgw_start() != c.LGW_HAL_SUCCESS) return error.StartFailed;

        return .{};
    }

    pub fn recv(_: Radio, buffer: []RxPacket) ![]RxPacket {
        const len = c.lgw_receive(@intCast(buffer.len), buffer.ptr);
        return if (len < 0) return error.RecvFailed else buffer[0..@intCast(len)];
    }

    pub fn deinit(_: Radio) void {
        _ = c.lgw_stop();
        claimed.store(false, .release);
    }

    pub const Freq = struct {
        hertz: i64,

        pub const zero: Freq = .{ .hertz = 0 };

        pub const ghz_per_hz = 1_000_000_000;
        pub const mhz_per_hz = 1_000_000;
        pub const khz_per_hz = 1_000;

        pub fn hz(hertz: i64) Freq {
            return .{ .hertz = hertz };
        }

        pub fn khz(khertz: i32) Freq {
            return .{ .hertz = @as(i64, khertz) * khz_per_hz };
        }

        pub fn mhz(mhertz: i32) Freq {
            return .{ .hertz = @as(i64, mhertz) * mhz_per_hz };
        }

        pub fn ghz(ghertz: i32) Freq {
            return .{ .hertz = @as(i64, ghertz) * ghz_per_hz };
        }

        pub fn toKHz(freq: Freq) i32 {
            return @intCast(@divTrunc(freq.hertz, khz_per_hz));
        }

        pub fn toMHz(freq: Freq) i32 {
            return @intCast(@divTrunc(freq.hertz, mhz_per_hz));
        }

        pub fn toGHz(freq: Freq) i32 {
            return @intCast(@divTrunc(freq.hertz, ghz_per_hz));
        }

        pub fn format(freq: Freq, writer: *std.Io.Writer) !void {
            inline for (.{
                .{ .hertz = ghz_per_hz, .suffix = "ghz" },
                .{ .hertz = mhz_per_hz, .suffix = "mhz" },
                .{ .hertz = khz_per_hz, .suffix = "khz" },
                .{ .hertz = 0.0, .suffix = "hz" },
            }) |unit| if (@abs(freq.hertz) >= unit.hertz) {
                const fhertz: f64 = @floatFromInt(freq.hertz);
                try writer.printFloat(fhertz / unit.hertz, .{});
                try writer.writeAll(unit.suffix);

                break;
            };
        }
    };

    pub const Bandwidth = enum(u8) {
        pub const @"undefined": Bandwidth = @enumFromInt(c.BW_UNDEFINED);

        @"125khz" = c.BW_125KHZ,
        @"250khz" = c.BW_250KHZ,
        @"500khz" = c.BW_500KHZ,
        _,
    };

    pub const Coderate = enum(u8) {
        pub const @"undefined": Coderate = @enumFromInt(c.CR_UNDEFINED);

        @"45" = c.CR_LORA_4_5,
        @"46" = c.CR_LORA_4_6,
        @"47" = c.CR_LORA_4_7,
        @"48" = c.CR_LORA_4_8,
        _,
    };

    pub const Datarate = enum(u8) {
        pub const @"undefined": Datarate = @enumFromInt(c.DR_UNDEFINED);

        @"7" = c.DR_LORA_SF7,
        @"8" = c.DR_LORA_SF8,
        @"9" = c.DR_LORA_SF9,
        @"10" = c.DR_LORA_SF10,
        @"11" = c.DR_LORA_SF11,
        @"12" = c.DR_LORA_SF12,

        _,
    };

    pub const RxPacket = c.lgw_pkt_rx_s;
    pub const TxPacket = c.lgw_pkt_tx_s;
};

test "longitude dms - valid" {
    {
        const lon: Gps.Longitude = try .dms(93, 31, 2.35);
        try std.testing.expectApproxEqAbs(@as(f64, 93.5173), lon.x, 0.0001);
    }
    {
        const lon: Gps.Longitude = try .dms(-93, 31, 2.35);
        try std.testing.expectApproxEqAbs(@as(f64, -93.5173), lon.x, 0.0001);
    }
    {
        const lon: Gps.Longitude = try .dms(0, 0, 0.00);
        try std.testing.expectEqual(@as(f64, 0.0), lon.x);
    }
}

test "longitude dms - invalid" {
    try std.testing.expectError(error.OutOfRange, Gps.Longitude.dms(181, 0, 0.0));
    try std.testing.expectError(error.OutOfRange, Gps.Longitude.dms(-181, 0, 0.0));

    try std.testing.expectError(error.OutOfRange, Gps.Longitude.dms(90, 60, 0.0));

    try std.testing.expectError(error.OutOfRange, Gps.Longitude.dms(90, 0, 60.0));
    try std.testing.expectError(error.OutOfRange, Gps.Longitude.dms(90, 0, -0.1));
}

test "latitude dms - valid" {
    {
        const lat: Gps.Latitude = try .dms(44, 58, 10.0);
        try std.testing.expectApproxEqAbs(@as(f64, 44.9694), lat.y, 0.0001);
    }
    {
        const lat: Gps.Latitude = try .dms(-44, 58, 10.0);
        try std.testing.expectApproxEqAbs(@as(f64, -44.9694), lat.y, 0.0001);
    }
    {
        const lat: Gps.Latitude = try .dms(0, 0, 0.00);
        try std.testing.expectEqual(@as(f64, 0.0), lat.y);
    }
}

test "latitude dms - invalid" {
    try std.testing.expectError(error.OutOfRange, Gps.Latitude.dms(181, 0, 0.0));
    try std.testing.expectError(error.OutOfRange, Gps.Latitude.dms(-181, 0, 0.0));

    try std.testing.expectError(error.OutOfRange, Gps.Latitude.dms(90, 60, 0.0));

    try std.testing.expectError(error.OutOfRange, Gps.Latitude.dms(90, 0, 60.0));
    try std.testing.expectError(error.OutOfRange, Gps.Latitude.dms(90, 0, -0.1));
}
