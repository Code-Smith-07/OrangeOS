// Orange OS — Arm64 context switch, floating point state, entry to user level.
//
// The kernel itself is built without floating point, so the instructions
// that touch those registers are enabled for this file only.
    .arch armv8-a+fp+simd

// Save or load all of q0-q31, FPSR and FPCR at x0 (see fpu.zig for the
// layout: 32 registers of 16 bytes, then the two status words).
.macro  fp_save base
    stp     q0, q1, [\base, #0]
    stp     q2, q3, [\base, #32]
    stp     q4, q5, [\base, #64]
    stp     q6, q7, [\base, #96]
    stp     q8, q9, [\base, #128]
    stp     q10, q11, [\base, #160]
    stp     q12, q13, [\base, #192]
    stp     q14, q15, [\base, #224]
    stp     q16, q17, [\base, #256]
    stp     q18, q19, [\base, #288]
    stp     q20, q21, [\base, #320]
    stp     q22, q23, [\base, #352]
    stp     q24, q25, [\base, #384]
    stp     q26, q27, [\base, #416]
    stp     q28, q29, [\base, #448]
    stp     q30, q31, [\base, #480]
    mrs     x9, fpsr
    mrs     x10, fpcr
    str     x9, [\base, #512]
    str     x10, [\base, #520]
.endm

.macro  fp_load base
    ldp     q0, q1, [\base, #0]
    ldp     q2, q3, [\base, #32]
    ldp     q4, q5, [\base, #64]
    ldp     q6, q7, [\base, #96]
    ldp     q8, q9, [\base, #128]
    ldp     q10, q11, [\base, #160]
    ldp     q12, q13, [\base, #192]
    ldp     q14, q15, [\base, #224]
    ldp     q16, q17, [\base, #256]
    ldp     q18, q19, [\base, #288]
    ldp     q20, q21, [\base, #320]
    ldp     q22, q23, [\base, #352]
    ldp     q24, q25, [\base, #384]
    ldp     q26, q27, [\base, #416]
    ldp     q28, q29, [\base, #448]
    ldp     q30, q31, [\base, #480]
    ldr     x9, [\base, #512]
    ldr     x10, [\base, #520]
    msr     fpsr, x9
    msr     fpcr, x10
.endm

    .section .text
    .global fpuSave
fpuSave:
    fp_save x0
    ret

    .global fpuLoad
fpuLoad:
    fp_load x0
    ret

// contextSwitch(old_sp: *u64, new_sp: u64, old_fpu: *State, new_fpu: *const State)
//
// The registers a function must preserve (x19-x28, the frame pointer and
// the return address) go on the old thread's stack; everything else is
// either scratch by the calling convention or already saved by the
// interrupt path. Each thread owns its kernel stack, so changing stacks
// changes threads: the final ret lands wherever the new stack says.
    .global contextSwitch
contextSwitch:
    fp_save x2
    stp     x29, x30, [sp, #-96]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]
    mov     x9, sp
    str     x9, [x0]
    mov     sp, x1
    fp_load x3
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

// contextStart(new_sp: u64, new_fpu: *const State) noreturn
// Resume a thread without saving the one being left (boot, or an exit).
    .global contextStart
contextStart:
    mov     sp, x0
    fp_load x1
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

// enterUserMode(entry: x0, user_sp: x1, arg: x2, kernel_stack_top: x3) noreturn
//
// First entry of a thread into its program. The kernel stack is reset to
// its top: when the program next traps, the processor continues from the
// kernel stack pointer it had here.
    .global enterUserMode
enterUserMode:
    msr     daifset, #0xf
    mov     sp, x3
    msr     elr_el1, x0
    msr     sp_el0, x1
    msr     spsr_el1, xzr                 // user level, interrupts on
    mov     x0, x2
    // Clear every other register: nothing of the kernel leaks out.
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    mov     x4, #0
    mov     x5, #0
    mov     x6, #0
    mov     x7, #0
    mov     x8, #0
    mov     x9, #0
    mov     x10, #0
    mov     x11, #0
    mov     x12, #0
    mov     x13, #0
    mov     x14, #0
    mov     x15, #0
    mov     x16, #0
    mov     x17, #0
    mov     x18, #0
    mov     x19, #0
    mov     x20, #0
    mov     x21, #0
    mov     x22, #0
    mov     x23, #0
    mov     x24, #0
    mov     x25, #0
    mov     x26, #0
    mov     x27, #0
    mov     x28, #0
    mov     x29, #0
    mov     x30, #0
    eret
