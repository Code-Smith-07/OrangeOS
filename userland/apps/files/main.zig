export fn _start() callconv(.c) noreturn {
    @import("files_view").run(false);
}
