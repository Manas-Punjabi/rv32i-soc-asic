// timescale.v — must be the FIRST file in any simulation that includes the
// PDK's OpenRAM macro model.
//
// That model carries no `timescale directive of its own, so it inherits the
// timescale of whatever was compiled before it. If that is a coarse default, the
// model's internal `#(T_HOLD)` suspends its input-registering always block for
// the entire run: csb/web/addr are latched once and never again, so the macro
// silently does nothing -- no writes, no reads, not even its own $display
// messages, because those sit after the delay. It looks like a wiring bug and is
// not one.
`timescale 1ns/1ps
