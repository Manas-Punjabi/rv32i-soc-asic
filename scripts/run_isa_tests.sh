#!/usr/bin/env bash
# run_isa_tests.sh — build and run the riscv-tests ISA suites on rv32i_core.
#
#   scripts/run_isa_tests.sh [rv32ui] [rv32mi] [asm] [socasm] [--stall] [--soc]
#
# Needs RISCV_TESTS (default ~/src/riscv-tests, a clone with the env submodule)
# and riscv64-unknown-elf-gcc. Each riscv-tests program is linked with the
# suite's own p environment (bare metal, machine mode); `asm` is this repo's
# directed core tests in tb/asm, `socasm` the SoC-level ones in tb/asm_soc (both
# built with tb/asm/test.h and link.ld). Programs run on tb_core, or on the whole
# soc_top with --soc (which also enables socasm and drops asm/irq: it pokes a
# testbench-only interrupt register). Prints one line per test and a summary;
# exits non-zero on any FAIL.
#
# Excluded, with the reason:
#   rv32ui/ma_data     needs hardware misaligned load/store; this core traps instead,
#                      which the spec permits. rv32mi/ma_addr checks that behaviour.
#   rv32mi/breakpoint  needs the Sdtrig trigger CSRs (tselect/tdata*), not implemented.
#   rv32mi/pmpaddr     needs PMP, not implemented (M-mode only, no protection).
set -u
cd "$(dirname "$0")/.."
RISCV_TESTS=${RISCV_TESTS:-$HOME/src/riscv-tests}
XLEN_FLAGS="-march=rv32i_zicsr_zifencei -mabi=ilp32"
BASEFLAGS="$XLEN_FLAGS -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles"
ISAFLAGS="-I $RISCV_TESTS/env/p -I $RISCV_TESTS/isa/macros/scalar -T $RISCV_TESTS/env/p/link.ld"
ASMFLAGS="-I tb/asm -T tb/asm/link.ld"
EXCLUDE="ma_data breakpoint pmpaddr"

suites=(); extra=(); soc=0
for a in "$@"; do case $a in --stall) extra+=(+stall);; --soc) soc=1;; *) suites+=("$a");; esac; done
if [[ $soc == 1 ]]; then
  [[ ${#suites[@]} -eq 0 ]] && suites=(rv32ui rv32mi asm socasm)
  EXCLUDE="$EXCLUDE irq"
  tb=tb_soc; rtl="rtl/core/*.sv rtl/accel/*.sv rtl/bus/*.sv rtl/periph/*.sv rtl/mem/*.sv rtl/soc_top.sv"
else
  [[ ${#suites[@]} -eq 0 ]] && suites=(rv32ui rv32mi asm)
  # tb_core instantiates the real soc_mem, so the core is never tested against a
  # more forgiving memory model than the SoC has
  tb=tb_core; rtl="rtl/core/*.sv rtl/mem/soc_mem.sv"
fi

mkdir -p build/isa
# -DRVFI: the trace is checked on every program (order, x0, pc continuity)
iverilog -g2012 -DRVFI -I tb -s $tb -o build/$tb $rtl tb/$tb.sv 2>build/$tb.iv.log || { grep -v "constant selects" build/$tb.iv.log; exit 1; }

pass=0; fail=0; skipped=0
for suite in "${suites[@]}"; do
  case $suite in
    asm)    dir=tb/asm;     flags=$ASMFLAGS;;
    socasm) dir=tb/asm_soc; flags=$ASMFLAGS;;
    *)      dir=$RISCV_TESTS/isa/$suite; flags=$ISAFLAGS;;
  esac
  for src in "$dir"/*.S; do
    t=$(basename "$src" .S)
    if [[ " $EXCLUDE " == *" $t "* ]]; then skipped=$((skipped+1)); continue; fi
    elf=build/isa/$suite-$t.elf; hex=build/isa/$suite-$t.hex
    if ! riscv64-unknown-elf-gcc $BASEFLAGS $flags "$src" -o "$elf" 2>build/isa/$suite-$t.gcc.log; then
      printf "  %-22s BUILD FAIL\n" "$suite/$t"; fail=$((fail+1)); continue
    fi
    python3 scripts/elf2hex.py "$elf" "$hex" || { fail=$((fail+1)); continue; }
    tohost=$(riscv64-unknown-elf-nm "$elf" | awk '$3=="tohost"{print $1}')
    # a .expect file next to a socasm test holds the UART text it must print
    uexp=(); [[ -f "$dir/$t.expect" ]] && uexp=(+uart_expect="$(cat "$dir/$t.expect")")
    r=$(vvp -n build/$tb +hex="$hex" +tohost="$tohost" "${extra[@]}" "${uexp[@]}" | grep -E "^(PASS|FAIL)")
    printf "  %-22s %s\n" "$suite/$t" "$r"
    [[ $r == PASS* ]] && pass=$((pass+1)) || fail=$((fail+1))
  done
done
echo "isa tests: $pass passed, $fail failed, $skipped excluded${extra[*]:+ (${extra[*]})}"
[[ $fail -eq 0 ]]
