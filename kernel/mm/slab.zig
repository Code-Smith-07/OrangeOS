//! Slab object caches.
//!
//! Each cache serves one fixed object size. Objects come from pages obtained
//! from the buddy allocator and carved up; free objects hold their own
//! freelist pointer, so tracking costs nothing beyond the object itself.
//!
//! Allocation and free are both O(1), and same-sized objects stay packed
//! together, which keeps fragmentation near zero for the kernel's many
//! fixed-size structures.

const std = @import("std");
const pmm = @import("pmm.zig");

/// Objects must be 16-byte aligned: the SysV ABI requires it for anything
/// holding a wide type, and heap.zig hands callers `object + 16`, so the
/// object itself has to start aligned for the payload to be aligned too.
const OBJECT_ALIGN = 16;

pub const Error = error{OutOfMemory};

/// Header at the start of every slab page group.
const SlabHeader = struct {
    next: ?*SlabHeader,
    phys: u64,
    order: usize,
    free_count: usize,
    total_count: usize,
};

/// Written into the first 8 bytes of a free object.
const FreeObject = struct {
    next: ?*FreeObject,
};

/// Slab header size, rounded up so the first object starts aligned.
inline fn headerBytes() usize {
    return std.mem.alignForward(usize, @sizeOf(SlabHeader), OBJECT_ALIGN);
}

pub const Cache = struct {
    name: []const u8,
    object_size: usize,
    /// Pages per slab, as a buddy order. Larger objects need larger slabs.
    slab_order: usize,
    free_list: ?*FreeObject = null,
    slabs: ?*SlabHeader = null,
    allocated: usize = 0,
    total_objects: usize = 0,

    pub fn init(name: []const u8, object_size: usize) Cache {
        // Round the object size up to the alignment so consecutive objects
        // stay aligned once the first one is.
        const size = std.mem.alignForward(
            usize,
            @max(object_size, @sizeOf(FreeObject)),
            OBJECT_ALIGN,
        );

        // Aim for at least 8 objects per slab so header overhead stays small.
        var order: usize = 0;
        while (order < pmm.MAX_ORDER) : (order += 1) {
            const usable = (pmm.PAGE_SIZE << @intCast(order)) - headerBytes();
            if (usable / size >= 8) break;
        }
        return .{
            .name = name,
            .object_size = size,
            .slab_order = order,
        };
    }

    /// Get a fresh slab from the buddy allocator and thread its objects onto
    /// the free list.
    fn grow(self: *Cache) Error!void {
        const phys = pmm.allocOrder(self.slab_order) catch return Error.OutOfMemory;
        const virt = pmm.physToVirt(phys);

        const header: *SlabHeader = @ptrFromInt(virt);
        const slab_bytes = pmm.PAGE_SIZE << @intCast(self.slab_order);
        const usable = slab_bytes - headerBytes();
        const count = usable / self.object_size;

        header.* = .{
            .next = self.slabs,
            .phys = phys,
            .order = self.slab_order,
            .free_count = count,
            .total_count = count,
        };
        self.slabs = header;

        var i: usize = 0;
        const first = virt + headerBytes();
        while (i < count) : (i += 1) {
            const obj: *FreeObject = @ptrFromInt(first + i * self.object_size);
            obj.next = self.free_list;
            self.free_list = obj;
        }

        self.total_objects += count;
    }

    pub fn alloc(self: *Cache) Error![*]u8 {
        if (self.free_list == null) try self.grow();
        const obj = self.free_list.?;
        self.free_list = obj.next;
        self.allocated += 1;
        return @ptrCast(obj);
    }

    pub fn free(self: *Cache, ptr: [*]u8) void {
        const obj: *FreeObject = @ptrCast(@alignCast(ptr));
        obj.next = self.free_list;
        self.free_list = obj;
        self.allocated -= 1;
    }

    pub fn objectSize(self: *const Cache) usize {
        return self.object_size;
    }
};
