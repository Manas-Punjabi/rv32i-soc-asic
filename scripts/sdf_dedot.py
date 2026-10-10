#!/usr/bin/env python3
r"""Work around Icarus Verilog splitting SDF instance names on '.', even when escaped.

Rewrites a netlist + SDF pair so that every '.' inside a Verilog escaped identifier
(e.g. \g_pe[0].u_pe.a_q[99]$_DFF_P_ ) becomes '_' in both files. The netlist is
functionally unchanged; only instance/net names differ.

Usage: sdf_dedot.py in.v in.sdf out.v out.sdf
"""
import re, sys

vin, sin, vout, sout = sys.argv[1:5]
esc = re.compile(r"\\(\S+)")            # escaped identifier: backslash up to whitespace
v = open(vin).read()
v = esc.sub(lambda m: "\\" + m.group(1).replace(".", "_"), v)
open(vout, "w").write(v)
s = open(sin).read()
s = s.replace("\\.", "_")               # SDF writes an escaped dot as '\.'
open(sout, "w").write(s)
print("wrote", vout, sout)
