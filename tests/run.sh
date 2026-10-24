#!/bin/sh
# Run from the tests/ folder:  sh run.sh
set -e
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -Ttext=0 -o t.elf test.S
riscv64-unknown-elf-objcopy -O binary t.elf t.bin
python3 -c "
d=open('t.bin','rb').read(); d+=b'\0'*((-len(d))%4)
open('instr_mem.hex','w').write(''.join('%08x\n'%int.from_bytes(d[i:i+4],'little') for i in range(0,len(d),4)))"
iverilog -g2012 -o sim ../tb/tb.v ../rtl/cpu.v
vvp sim