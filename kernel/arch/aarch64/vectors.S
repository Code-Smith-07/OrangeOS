// Orange OS — Arm64 exception vectors.
//
// The processor jumps to one of sixteen slots (four kinds of event from each
// of four origins). Every slot saves the interrupted registers on the stack
// and calls exceptionEntry(frame, slot) in exceptions.zig; when that
// returns, the registers are restored and the interrupted code continues.

#define FRAME_SIZE 272                    // x0-x30, return address, saved state

.macro  slot number
    .balign 0x80
    sub     sp, sp, #FRAME_SIZE
    stp     x0, x1, [sp, #0]
    mov     x1, #\number
    b       save_and_call
.endm

    .section .text.vectors, "ax"
    .balign 0x800
    .global exception_vectors
exception_vectors:
    slot 0      // this level, early stack: synchronous
    slot 1      //                          interrupt
    slot 2      //                          fast interrupt
    slot 3      //                          system error
    slot 4      // this level, own stack:   synchronous
    slot 5      //                          interrupt
    slot 6      //                          fast interrupt
    slot 7      //                          system error
    slot 8      // user level, 64-bit:      synchronous (system calls, faults)
    slot 9      //                          interrupt
    slot 10     //                          fast interrupt
    slot 11     //                          system error
    slot 12     // user level, 32-bit:      not supported
    slot 13
    slot 14
    slot 15

save_and_call:
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    mrs     x2, elr_el1
    mrs     x3, spsr_el1
    stp     x30, x2, [sp, #240]
    str     x3, [sp, #256]
    mov     x0, sp
    bl      exceptionEntry
    ldr     x3, [sp, #256]
    ldp     x30, x2, [sp, #240]
    msr     spsr_el1, x3
    msr     elr_el1, x2
    ldp     x28, x29, [sp, #224]
    ldp     x26, x27, [sp, #208]
    ldp     x24, x25, [sp, #192]
    ldp     x22, x23, [sp, #176]
    ldp     x20, x21, [sp, #160]
    ldp     x18, x19, [sp, #144]
    ldp     x16, x17, [sp, #128]
    ldp     x14, x15, [sp, #112]
    ldp     x12, x13, [sp, #96]
    ldp     x10, x11, [sp, #80]
    ldp     x8, x9, [sp, #64]
    ldp     x6, x7, [sp, #48]
    ldp     x4, x5, [sp, #32]
    ldp     x2, x3, [sp, #16]
    ldp     x0, x1, [sp, #0]
    add     sp, sp, #FRAME_SIZE
    eret
