.macro CHK reg, val, id
    li   x29, \val
    li   x30, \id
    bne  \reg, x29, fail
.endm
.globl _start
_start:
    # --- ALU / the ADDI-negative bug (old design turned this into SUB) ---
    addi x1, x0, -1
    CHK  x1, -1, 1
    addi x2, x0, 5
    addi x3, x2, -3            # back-to-back RAW (EX/MEM fwd)
    CHK  x3, 2, 2
    add  x4, x3, x2            # fwd
    sub  x5, x4, x3
    CHK  x5, 5, 3
    xori x6, x2, 0x0F
    ori  x7, x2, 0x30
    andi x8, x7, 0x35
    CHK  x6, 10, 4
    CHK  x7, 0x35, 5
    CHK  x8, 0x35, 6
    slli x9, x2, 4
    srli x10, x9, 2
    li   x11, 0x80000000
    srai x12, x11, 4
    srli x13, x11, 4
    CHK  x10, 20, 7
    CHK  x12, 0xF8000000, 8
    CHK  x13, 0x08000000, 9
    slt  x14, x11, x2          # signed: neg < 5
    sltu x15, x11, x2          # unsigned: big > 5
    slti x16, x1, 0
    sltiu x17, x1, 0
    CHK  x14, 1, 10
    CHK  x15, 0, 11
    CHK  x16, 1, 12
    CHK  x17, 0, 13
    # --- RF bypass: producer 3 instructions earlier ---
    addi x18, x0, 77
    nop
    nop
    add  x19, x18, x0
    CHK  x19, 77, 14
    # --- LUI / AUIPC ---
    lui  x20, 0x12345
    CHK  x20, 0x12345000, 15
    auipc x21, 0
    la   x22, .
    # --- memory: word/half/byte, sign ext, load-use ---
    li   x23, 0x100
    li   x24, 0x8081F2F3
    sw   x24, 0(x23)
    lw   x25, 0(x23)
    CHK  x25, 0x8081F2F3, 16
    lb   x26, 0(x23)           # 0xF3 -> -13
    CHK  x26, -13, 17
    lbu  x26, 1(x23)           # 0xF2
    CHK  x26, 0xF2, 18
    lh   x26, 2(x23)           # 0x8081
    CHK  x26, 0xFFFF8081, 19
    lhu  x26, 2(x23)
    CHK  x26, 0x8081, 20
    lw   x27, 0(x23)
    addi x27, x27, 1           # load-use stall
    CHK  x27, 0x8081F2F4, 21
    li   x28, 0xAA
    sb   x28, 2(x23)
    lw   x25, 0(x23)
    CHK  x25, 0x80AAF2F3, 22
    li   x28, 0x1234
    sh   x28, 0(x23)
    lw   x25, 0(x23)
    CHK  x25, 0x80AA1234, 23
    lw   x27, 0(x23)
    sw   x27, 4(x23)           # load -> store data (stall + fwd)
    lw   x25, 4(x23)
    CHK  x25, 0x80AA1234, 24
    # --- branches, all six, taken and not taken ---
    li   x1, -2
    li   x2, 3
    li   x3, 0
    beq  x2, x2, b1
    j    fail_b
b1: bne  x2, x1, b2
    j    fail_b
b2: blt  x1, x2, b3            # -2 < 3 signed
    j    fail_b
b3: bge  x2, x1, b4
    j    fail_b
b4: bltu x2, x1, b5            # 3 < 0xFFFFFFFE unsigned
    j    fail_b
b5: bgeu x1, x2, b6
    j    fail_b
b6: beq  x1, x2, fail_b        # not taken
    bne  x2, x2, fail_b
    blt  x2, x1, fail_b
    bge  x1, x2, fail_b
    bltu x1, x2, fail_b
    bgeu x2, x1, fail_b
    # wrong-path instruction must not commit:
    li   x5, 1
    beq  x0, x0, skip
    li   x5, 99
skip:
    CHK  x5, 1, 25
    # --- JAL / JALR link ---
    jal  x6, sub1
ret1:
    CHK  x7, 42, 26
    la   x8, ret1
    li   x30, 27
    bne  x6, x8, fail
    # JALR with odd low bit & fwd from preceding addi
    la   x9, tgt
    addi x9, x9, 1
    jalr x10, 0(x9)
    li   x7, 0                 # skipped
tgt:
    CHK  x7, 42, 28
    # --- loop: sum 1..10 ---
    li   x1, 0
    li   x2, 10
loop:
    add  x1, x1, x2
    addi x2, x2, -1
    bnez x2, loop
    CHK  x1, 55, 29
    li   x31, 0xC0DE
done: j done
fail_b:
    li   x30, 99
fail:
    li   x31, 0xBAD
    j fail
sub1:
    li   x7, 42
    jalr x0, 0(x6)