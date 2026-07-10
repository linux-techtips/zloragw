const std = @import("std");

const c = @cImport({
    @cInclude("loragw_hal.h");
});

pub const Radio = struct {
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
            spreading_factor: SpreadingFactor = .undefined,
            coding_rate: CodingRate = .undefined,
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
                .datarate = @intFromEnum(chain.spreading_factor),
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
        std.debug.assert(c.lgw_stop() == c.LGW_HAL_SUCCESS);
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

    pub const CodingRate = enum(u8) {
        pub const @"undefined": CodingRate = @enumFromInt(c.CR_UNDEFINED);

        @"45" = c.CR_LORA_4_5,
        @"46" = c.CR_LORA_4_6,
        @"47" = c.CR_LORA_4_7,
        @"48" = c.CR_LORA_4_8,
        _,
    };

    pub const SpreadingFactor = enum(u8) {
        pub const @"undefined": SpreadingFactor = @enumFromInt(c.DR_UNDEFINED);

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

comptime {
    _ = std.testing.refAllDecls(@This());
}
