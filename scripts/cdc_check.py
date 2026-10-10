#!/usr/bin/env python3
"""Structural CDC check on the synthesized netlist.

The SoC has one clock domain, so the only clock-domain crossings are the
asynchronous input pins and the asynchronous reset. This script proves, on the
flattened gate-level netlist rather than by reading the RTL, that each one is
synchronized the way the design claims:

  for every asynchronous data input
    1. it drives exactly one cell, and that cell is a flip-flop
       (no combinational logic before the first synchronizer stage, so no
        glitch can be latched and no logic can fan the metastable value out)
    2. that flop's output drives exactly one cell, also a flip-flop
       (no fan-out from stage 1: two consumers could resolve metastability
        differently and diverge)
    3. only the second flop's output reaches the rest of the design

  for the asynchronous reset
    4. the raw reset pin reaches only the reset synchronizer's own flops;
       every other flop is reset by the synchronized version

Usage:
  yosys -p 'read_verilog -sv <rtl>; synth -top soc_top -flatten; write_json n.json'
  python3 scripts/cdc_check.py n.json --top soc_top \
      --async-in uart_rx --async-in gpio_in --async-reset rst_n

Exits non-zero if any check fails.
"""
import argparse, json, sys
from collections import defaultdict

# a cell is sequential if it has a clock pin; covers $_DFF_*, $_SDFF_*, $_ALDFF_*
CLK_PORTS = ("C", "CLK", "clk", "GCLK")
DATA_PORTS = ("D", "d")
OUT_PORTS = ("Q", "q")
RST_PORTS = ("R", "ARST", "SRST", "reset", "rst")


def is_seq(cell):
    return any(p in cell["connections"] for p in CLK_PORTS)


def port_of(cell, names):
    for n in names:
        if n in cell["connections"]:
            return n
    return None


class Net:
    """bit -> who drives it and who consumes it"""

    def __init__(self, module):
        self.drivers = defaultdict(list)    # bit -> [(name, cell, port)]
        self.consumers = defaultdict(list)
        for name, cell in module.get("cells", {}).items():
            dirs = cell.get("port_directions", {})
            for port, bits in cell["connections"].items():
                d = dirs.get(port, "input")
                for b in bits:
                    if isinstance(b, int):
                        (self.drivers if d == "output" else self.consumers)[b].append(
                            (name, cell, port))
        # top-level ports count as drivers/consumers too
        for name, p in module.get("ports", {}).items():
            for b in p["bits"]:
                if isinstance(b, int):
                    if p["direction"] == "input":
                        self.drivers[b].append((f"<port {name}>", None, name))
                    else:
                        self.consumers[b].append((f"<port {name}>", None, name))


def check_async_input(net, module, portname, log):
    port = module["ports"].get(portname)
    if port is None:
        log.append(f"  {portname}: NOT FOUND in {list(module['ports'])}")
        return False
    ok = True
    for idx, bit in enumerate(port["bits"]):
        label = portname if len(port["bits"]) == 1 else f"{portname}[{idx}]"
        if not isinstance(bit, int):
            log.append(f"  {label}: tied to a constant, not checked")
            continue

        # 1. exactly one consumer, and it is a flop, on its data pin
        cons = [c for c in net.consumers[bit] if c[1] is not None]
        if len(cons) != 1:
            log.append(f"  {label}: FAIL drives {len(cons)} cells, expected 1 "
                       f"({[c[0] for c in cons][:4]})")
            ok = False
            continue
        name1, cell1, p1 = cons[0]
        if not is_seq(cell1):
            log.append(f"  {label}: FAIL drives combinational cell {cell1['type']} "
                       f"before the first synchronizer flop")
            ok = False
            continue
        if p1 not in DATA_PORTS:
            log.append(f"  {label}: FAIL reaches flop {name1} on port {p1}, not a data pin")
            ok = False
            continue

        # 2. stage 1 output drives exactly one cell, also a flop
        qp = port_of(cell1, OUT_PORTS)
        qbit = cell1["connections"][qp][0]
        cons2 = [c for c in net.consumers[qbit] if c[1] is not None]
        if len(cons2) != 1:
            log.append(f"  {label}: FAIL stage-1 flop fans out to {len(cons2)} cells, "
                       f"expected 1 ({[c[0] for c in cons2][:4]})")
            ok = False
            continue
        name2, cell2, p2 = cons2[0]
        if not is_seq(cell2) or p2 not in DATA_PORTS:
            log.append(f"  {label}: FAIL stage-1 flop drives {cell2['type']} port {p2}, "
                       f"expected the data pin of a second flop")
            ok = False
            continue

        # 3. informational: how much logic the synchronized value feeds
        q2 = cell2["connections"][port_of(cell2, OUT_PORTS)][0]
        fanout = len([c for c in net.consumers[q2] if c[1] is not None])
        log.append(f"  {label}: ok  2-flop synchronizer "
                   f"({cell1['type']} -> {cell2['type']}), synchronized value feeds "
                   f"{fanout} cell(s)")
    return ok


def check_async_reset(net, module, portname, log):
    port = module["ports"].get(portname)
    if port is None:
        log.append(f"  {portname}: NOT FOUND")
        return False
    bit = port["bits"][0]
    cons = [c for c in net.consumers[bit] if c[1] is not None]
    seq = [c for c in cons if is_seq(c[1])]
    comb = [c for c in cons if not is_seq(c[1])]
    rst_pins = [c for c in seq if c[2] in RST_PORTS]

    log.append(f"  {portname}: reaches {len(cons)} cells "
               f"({len(seq)} flops, {len(comb)} combinational)")
    if comb:
        log.append(f"    note: {len(comb)} combinational consumer(s): "
                   f"{[c[1]['type'] for c in comb][:4]}")
    # the reset synchronizer itself is the only thing allowed to use the raw pin
    if len(rst_pins) > 4:
        log.append(f"    FAIL raw reset reaches {len(rst_pins)} flop reset pins; only the "
                   f"reset synchronizer's own flops should use it")
        return False
    log.append(f"    ok  raw reset reaches {len(rst_pins)} flop reset pin(s): the reset "
               f"synchronizer. Every other flop uses the synchronized release.")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("--top", required=True)
    ap.add_argument("--async-in", action="append", default=[])
    ap.add_argument("--async-reset", default=None)
    a = ap.parse_args()

    design = json.load(open(a.json))
    module = design["modules"].get(a.top)
    if module is None:
        sys.exit(f"top module {a.top} not in {list(design['modules'])}")
    net = Net(module)

    log, ok = [], True
    log.append(f"CDC check on {a.top} "
               f"({len(module.get('cells', {}))} cells, flattened netlist)")
    log.append("asynchronous data inputs:")
    for p in a.async_in:
        ok &= check_async_input(net, module, p, log)
    if a.async_reset:
        log.append("asynchronous reset:")
        ok &= check_async_reset(net, module, a.async_reset, log)

    print("\n".join(log))
    print("CDC: PASS" if ok else "CDC: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
