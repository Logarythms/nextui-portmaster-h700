-- gt-h700-solarus-nojit (F28) — executed before every solarus quest's
-- main.lua via the engine's -s option (injected by the pak's run_port for
-- solarus ports on h700). The solarus runtime bundles LuaJIT 2.1.0-beta3,
-- whose aarch64 JIT miscompiles under quest load on this device: gdb caught
-- SIGSEGV jumps into unmapped trace memory from libluajit during Tunics!
-- map transitions (2026-08-23). The interpreter is stable and fast enough —
-- solarus does its heavy lifting in C++.
if jit then jit.off() end
