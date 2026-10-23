\---

name: claude-skill-verilog

description: Verilog/SystemVerilog coding style and Verilator workflow guidance

\---



\# Verilog/SystemVerilog Guidance



Apply when working with `.v`, `.sv`, `.vh`, `.svh` files or running Verilator.



\## Documentation



All modules, wires, and registers require comments:



```systemverilog

// Module: counter

// Purpose: Simple up-counter with synchronous reset

module counter #(

&#x20;   parameter WIDTH = 8  // Counter bit width

) (

&#x20;   input  logic             clk,      // System clock

&#x20;   input  logic             rst\_n,    // Active-low reset

&#x20;   output logic \[WIDTH-1:0] count     // Current count value

);

```



\## Fixed-Point Notation



Document all fixed-point values using TI-style Q notation:



\* `Qm.n` — signed: m integer bits (including sign bit), n fractional bits, total width = m + n bits.

\* `UQm.n` — unsigned: m integer bits, n fractional bits, total width = m + n bits.



Use Q notation in signal comments, localparam descriptions, and module-level documentation.



```systemverilog

logic signed \[15:0] scale\_factor;  // Scaling multiplier, Q4.12

logic        \[15:0] timer\_count;   // Free-running tick counter, UQ16.0

logic signed \[15:0] delta;         // Sample-to-sample difference, Q4.12

```



\## Naming Conventions



\* Active-low signals: use `\_n` suffix (e.g., `rst\_n`, `chip\_select\_n`)

\* Clocks: `clk` or `clk\_<domain>`

\* Use descriptive names over abbreviations



\## always\_ff: Simple Assignments Only



`always\_ff` blocks must contain ONLY simple non-blocking assignments. No logic, no expressions — this ensures Verilator simulation matches synthesized behavior. (Exceptions: memory inference and async reset synchronizers require conditional logic — see those sections.)



```systemverilog

// CORRECT - simple assignment

always\_ff @(posedge clk) begin

&#x20;   count <= count\_next;

&#x20;   state <= state\_next;

end



// WRONG - logic in always\_ff

always\_ff @(posedge clk) begin

&#x20;   count <= count + 1;                // Move to always\_comb

&#x20;   state <= enable ? RUNNING : IDLE;  // Move to always\_comb

end

```



\## always\_comb: All Logic Here



All combinational logic belongs in `always\_comb` blocks:



```systemverilog

always\_comb begin

&#x20;   count\_next = count + 8'd1;

&#x20;   state\_next = enable ? RUNNING : IDLE;

end

```



\## Formatting



\* One statement per line — never chain multiple statements or assignments on a single line

\* One declaration per line

\* Explicit bit widths on all literals

\* Start files with `` `default\_nettype none ``

\* Always use `begin`/`end` blocks for `if`, `else`, `case` items (prevents bugs when adding code later)

\* Prefer to keep modules under \~500 lines; if a module grows significantly larger, consider refactoring into smaller sub-modules



```systemverilog

`default\_nettype none



module example (

&#x20;   input  logic        clk,

&#x20;   input  logic        rst\_n,

&#x20;   input  logic \[7:0]  data\_in,

&#x20;   output logic \[7:0]  data\_out

);



&#x20;   logic \[7:0] data\_reg;    // Registered data

&#x20;   logic \[7:0] data\_next;   // Next state value

&#x20;   logic       valid;       // Data valid flag



&#x20;   localparam logic \[7:0] INIT\_VAL = 8'd0;



endmodule



`default\_nettype wire

```



\## Yosys Synthesis Compatibility



Synthesizable RTL should work with both \*\*Verilator\*\* (lint/simulation) and \*\*Yosys\*\* (synthesis for open-source FPGA flows).

Yosys supports a subset of SystemVerilog via `read\_verilog -sv`.

Code that passes Verilator may still fail Yosys synthesis.



\*\*Constructs to avoid in synthesizable RTL:\*\*



| Avoid | Use instead |

| --- | --- |

| `return <expr>;` in functions | `function\_name = <expr>;` (Verilog-2005 style) |

| `interface` / `modport` | Explicit port lists |

| `unique case` / `priority case` | Plain `case` with `default` |

| Multi-dimensional packed arrays in ports | Flatten to single vectors |



```systemverilog

// CORRECT - Yosys-compatible function

function automatic logic \[7:0] add\_saturate(input logic \[7:0] a, input logic \[7:0] b);

&#x20;   logic \[8:0] sum;

&#x20;   sum = {1'b0, a} + {1'b0, b};

&#x20;   add\_saturate = sum\[8] ? 8'hFF : sum\[7:0];

endfunction



// WRONG - return statement (Yosys rejects this)

function automatic logic \[7:0] add\_saturate(input logic \[7:0] a, input logic \[7:0] b);

&#x20;   logic \[8:0] sum;

&#x20;   sum = {1'b0, a} + {1'b0, b};

&#x20;   return sum\[8] ? 8'hFF : sum\[7:0];

endfunction

```



Always verify with the actual synthesis flow (e.g. `yosys -p "synth\_ecp5 ..."`, `yosys -p "synth\_ice40 ..."`, or the project's build target), not only `verilator --lint-only`, when using SystemVerilog features. Lint-clean does not imply synthesizable.



\## Testing with Verilator



Every module requires a testbench. Build and run with Verilator:



```sh

\# Build testbench

verilator --binary -Wall module\_tb.sv module.sv



\# Run simulation

./obj\_dir/Vmodule\_tb

```



Testbench structure:



```systemverilog

module counter\_tb;

&#x20;   logic       clk = 1'b0;  // System clock

&#x20;   logic       rst\_n;       // Active-low reset

&#x20;   logic \[7:0] count;       // DUT output



&#x20;   counter dut (

&#x20;       .clk(clk),

&#x20;       .rst\_n(rst\_n),

&#x20;       .count(count)

&#x20;   );



&#x20;   always begin

&#x20;       #5 clk = \~clk;

&#x20;   end



&#x20;   initial begin

&#x20;       rst\_n = 1'b0;

&#x20;       #20 rst\_n = 1'b1;

&#x20;       #100;

&#x20;       $display("Test complete, count=%d", count);

&#x20;       $finish;

&#x20;   end

endmodule

```



\## Verilator Linting



Run linting on all files and fix all warnings:



```sh

verilator --lint-only -Wall module.sv

```



\* Fix all warnings — do not suppress with pragmas

\* Key warnings: WIDTH (bit-width mismatch), UNUSED, UNDRIVEN



\## Verilator Simulation Flags



Recommended flags for simulation builds:



```sh

verilator --binary \\

&#x20;   -Wall \\

&#x20;   -Wno-fatal \\

&#x20;   -j 0 \\

&#x20;   --assert \\

&#x20;   --timing \\

&#x20;   --trace-fst \\

&#x20;   --trace-structs \\

&#x20;   --main-top-name "-" \\

&#x20;   --x-assign unique \\

&#x20;   --x-initial unique \\

&#x20;   module\_tb.sv module.sv

```



| Flag | Purpose |

| --- | --- |

| `-Wall` | Enable all warnings |

| `-Wno-fatal` | Don't exit on warnings (allows full report) |

| `-j 0` | Fully parallelized compilation |

| `--assert` | Enable SystemVerilog assertions |

| `--timing` | Enable timing constructs |

| `--trace-fst` | Dump waveforms as FST (compressed) |

| `--trace-structs` | Human-readable struct dumps |

| `--main-top-name "-"` | Remove extra TOP module wrapper |

| `--x-assign unique` | Replace X with random constant per-build |

| `--x-initial unique` | Randomly initialize uninitialized variables |



\## Module Instantiation



\* One module per file, filename matches module name

\* Always use named port connections (never positional)



```systemverilog

// CORRECT - named connections

counter #(

&#x20;   .WIDTH(16)

) u\_counter (

&#x20;   .clk    (clk),

&#x20;   .rst\_n  (rst\_n),

&#x20;   .count  (count\_value)

);



// WRONG - positional connections

counter u\_counter (clk, rst\_n, count\_value);

```



\## Avoiding Latches



Latches are inferred when signals aren't assigned in all paths. Prevent with:



\* Default assignments at start of `always\_comb`

\* Cover all cases including `default`



```systemverilog

always\_comb begin

&#x20;   // Default assignments first

&#x20;   data\_next = data\_reg;

&#x20;   valid\_next = 1'b0;



&#x20;   case (state)

&#x20;       IDLE: begin

&#x20;           data\_next = 8'd0;

&#x20;       end

&#x20;       LOAD: begin

&#x20;           data\_next = data\_in;

&#x20;       end

&#x20;       default: begin

&#x20;           data\_next = data\_reg;

&#x20;       end

&#x20;   endcase

end

```



\## Reset Handling



Use synchronous resets when possible. For external async resets, synchronize first.



\*\*Note:\*\* Async reset synchronizers require conditional logic in `always\_ff` for the reset condition — this is a necessary exception similar to memory inference.



```systemverilog

// Synchronous reset (preferred)

logic \[7:0] count;       // Counter register

logic \[7:0] count\_next;  // Next counter value



always\_comb begin

&#x20;   count\_next = rst\_n ? (count + 8'd1) : 8'd0;

end



always\_ff @(posedge clk) begin

&#x20;   count <= count\_next;

end



// Reset synchronizer for external async reset

logic \[1:0] rst\_sync;       // Synchronizer flip-flops

logic \[1:0] rst\_sync\_next;  // Next synchronizer value



always\_comb begin

&#x20;   rst\_sync\_next = {rst\_sync\[0], 1'b1};

end



always\_ff @(posedge clk or negedge rst\_async\_n) begin

&#x20;   if (!rst\_async\_n) begin

&#x20;       rst\_sync <= 2'b00;

&#x20;   end else begin

&#x20;       rst\_sync <= rst\_sync\_next;

&#x20;   end

end

assign rst\_n = rst\_sync\[1];

```



\## FSM Patterns



Separate state register from next-state logic. Use enums for state encoding.



```systemverilog

typedef enum logic \[1:0] {

&#x20;   IDLE,

&#x20;   RUN,

&#x20;   DONE

} state\_t;



state\_t state;       // Current state register

state\_t state\_next;  // Next state value



// Next-state logic (combinational)

always\_comb begin

&#x20;   state\_next = state;

&#x20;   case (state)

&#x20;       IDLE: begin

&#x20;           if (start) begin

&#x20;               state\_next = RUN;

&#x20;           end

&#x20;       end

&#x20;       RUN: begin

&#x20;           if (finish) begin

&#x20;               state\_next = DONE;

&#x20;           end

&#x20;       end

&#x20;       DONE: begin

&#x20;           state\_next = IDLE;

&#x20;       end

&#x20;       default: begin

&#x20;           state\_next = IDLE;

&#x20;       end

&#x20;   endcase

end



// State register (sequential)

always\_ff @(posedge clk) begin

&#x20;   state <= state\_next;

end

```



\## Clock Domain Crossing (CDC)



Single-bit signals: use 2-FF synchronizer. Multi-bit: use gray coding or handshake.



```systemverilog

// 2-FF synchronizer for single-bit CDC

logic \[1:0] sync\_reg;       // Synchronizer flip-flops

logic \[1:0] sync\_reg\_next;  // Next synchronizer value

logic       signal\_sync;    // Synchronized output



always\_comb begin

&#x20;   sync\_reg\_next = {sync\_reg\[0], signal\_src};

end



always\_ff @(posedge clk\_dst) begin

&#x20;   sync\_reg <= sync\_reg\_next;

end

assign signal\_sync = sync\_reg\[1];



// Gray code for multi-bit counters crossing domains

function automatic logic \[WIDTH-1:0] bin2gray(input logic \[WIDTH-1:0] bin);

&#x20;   bin2gray = bin ^ (bin >> 1);

endfunction

```



\## Memory Inference



Use standard patterns for RAM/ROM inference by synthesis tools.



\*\*Note:\*\* Memory patterns are an exception to the "simple assignments only" rule for `always\_ff`. Synthesis tools require these specific patterns to correctly infer RAM/ROM primitives.



```systemverilog

// Single-port RAM

logic \[DATA\_WIDTH-1:0] mem \[0:DEPTH-1];  // Memory array



always\_ff @(posedge clk) begin

&#x20;   if (we) begin

&#x20;       mem\[addr] <= wdata;

&#x20;   end

&#x20;   rdata <= mem\[addr];

end



// ROM (initialized memory)

logic \[7:0] rom \[0:255];  // ROM array

initial $readmemh("rom\_data.hex", rom);



always\_ff @(posedge clk) begin

&#x20;   rdata <= rom\[addr];

end

```



\## Assertions (SVA)



Use assertions for verification. They're enabled with `--assert` in Verilator.



```systemverilog

// Immediate assertion

always\_comb begin

&#x20;   assert (count < MAX\_COUNT) else $error("Count overflow");

end



// Concurrent assertions

property p\_valid\_handshake;

&#x20;   @(posedge clk) disable iff (!rst\_n)

&#x20;   valid |-> ##\[1:3] ready;

endproperty



assert property (p\_valid\_handshake)

&#x20;   else $error("Handshake timeout");



// Cover property (for functional coverage)

cover property (@(posedge clk) state == DONE);

```

