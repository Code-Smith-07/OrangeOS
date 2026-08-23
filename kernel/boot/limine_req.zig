//! Limine boot protocol — request structures and responses.
//!
//! Struct layouts mirror `third_party/limine/limine.h` exactly. Every request
//! is an `export var` in the `.limine_requests` section so the bootloader can
//! find it by scanning for the magic in `id`, and so the linker's KEEP()
//! directive stops it being garbage-collected.
//!
//! Base revision 3 is what Limine v11 speaks.

const COMMON_MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
const COMMON_MAGIC_1: u64 = 0x0a82e883a194f07b;

// ── Markers ──────────────────────────────────────────────────────────────────

export var requests_start_marker linksection(".limine_requests_start") = [_]u64{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
    0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

export var requests_end_marker linksection(".limine_requests_end") = [_]u64{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};

/// The bootloader zeroes [2] if it supports the revision we asked for.
export var base_revision linksection(".limine_requests") = [_]u64{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3,
};

pub fn baseRevisionSupported() bool {
    return base_revision[2] == 0;
}

// ── Bootloader info ──────────────────────────────────────────────────────────

pub const BootloaderInfoResponse = extern struct {
    revision: u64,
    name: [*:0]const u8,
    version: [*:0]const u8,
};

export var bootloader_info_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*BootloaderInfoResponse,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0xf55038d8e2a1202f, 0x279426fcf5f59740 },
    .revision = 0,
    .response = null,
};

// ── Framebuffer ──────────────────────────────────────────────────────────────

pub const MEMORY_MODEL_RGB: u8 = 1;

pub const Framebuffer = extern struct {
    address: [*]volatile u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
    // Response revision 1 and above:
    mode_count: u64,
    modes: ?[*]*anyopaque,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

export var framebuffer_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*FramebufferResponse,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    .revision = 0,
    .response = null,
};

// ── Memory map ───────────────────────────────────────────────────────────────

pub const MemmapType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    reserved_mapped = 8,
    _,

    pub fn name(self: MemmapType) []const u8 {
        return switch (self) {
            .usable => "usable",
            .reserved => "reserved",
            .acpi_reclaimable => "ACPI reclaimable",
            .acpi_nvs => "ACPI NVS",
            .bad_memory => "bad memory",
            .bootloader_reclaimable => "bootloader reclaimable",
            .executable_and_modules => "kernel and modules",
            .framebuffer => "framebuffer",
            .reserved_mapped => "reserved (mapped)",
            _ => "unknown",
        };
    }
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemmapType,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry,
};

export var memmap_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*MemmapResponse,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

// ── HHDM (Higher-Half Direct Map) ────────────────────────────────────────────

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

export var hhdm_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*HhdmResponse,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
    .response = null,
};

// ── Executable address ───────────────────────────────────────────────────────
// Needed to build our own page tables: we know the kernel's virtual addresses
// from the linker script, but not where Limine actually loaded it in RAM.

pub const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

export var executable_address_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*ExecutableAddressResponse,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    .revision = 0,
    .response = null,
};

// ── Paging mode ──────────────────────────────────────────────────────────────
// Pin 4-level paging. 5-level would change the address layout documented in
// ARCHITECTURE.md and is not worth supporting yet.

pub const PAGING_MODE_X86_64_4LVL: u64 = 0;

export var paging_mode_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*anyopaque,
    mode: u64,
    max_mode: u64,
    min_mode: u64,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a },
    .revision = 1,
    .response = null,
    .mode = PAGING_MODE_X86_64_4LVL,
    .max_mode = PAGING_MODE_X86_64_4LVL,
    .min_mode = PAGING_MODE_X86_64_4LVL,
};

// ── RSDP (ACPI root pointer) ─────────────────────────────────────────────────

pub const RsdpResponse = extern struct {
    revision: u64,
    address: u64,
};

export var rsdp_request linksection(".limine_requests") = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*RsdpResponse,
}{
    .id = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    .revision = 0,
    .response = null,
};

// ── Accessors ────────────────────────────────────────────────────────────────

pub fn bootloaderInfo() ?*BootloaderInfoResponse {
    return bootloader_info_request.response;
}

pub fn framebuffers() ?*FramebufferResponse {
    return framebuffer_request.response;
}

pub fn memmap() ?*MemmapResponse {
    return memmap_request.response;
}

pub fn executableAddress() ?*ExecutableAddressResponse {
    return executable_address_request.response;
}

pub fn rsdp() ?u64 {
    const r = rsdp_request.response orelse return null;
    return r.address;
}

pub fn hhdmOffset() ?u64 {
    const r = hhdm_request.response orelse return null;
    return r.offset;
}
