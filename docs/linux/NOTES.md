# Running the VIctory-based runtime on Linux through Proton

State on 2026-11-24. The runtime is at upstream `48ba23a` (fx-harvest `38e8e7c`), built for Windows and run under Proton. Everything here is on branch `linux-proton`; `main` is an exact mirror of upstream.

**Result:** boots, menus at 30 fps, loads (about 7 minutes), and reaches gameplay (the movement tutorial shows) at about 4 fps. The world picture is black, with the causes below.

| Section | Contents |
|---|---|
| [Setup](#setup) | build, run, unattended tests |
| [Findings](#findings) | each problem, the evidence, and how sure it is |
| [Tried without success](#tried-without-success) | so it is not tried again blindly |
| [Open questions](#open-questions) | next steps |

## Setup

Machine: Intel i5-13400F, AMD RX 9070 XT 16 GB, 64 GB RAM, Ubuntu 26.04.1, kernel 7.0.0-43, Mesa/RADV 26.0.8-1ubuntu0.3. Steam is the snap. GE-Proton11-12, Proton Experimental (11.0-20261112), SteamLinuxRuntime_4.

### Build

Needs `rustup`, `clang`, `lld`, `llvm` (apt) and `cargo install --locked cargo-xwin`. It downloads Microsoft's CRT and SDK, whose licence you must accept. From `runtime/victory`:

```bash
XWIN_ACCEPT_LICENSE=1 cargo xwin build --release -p victory --bin victory --features diagnostics --locked --target x86_64-pc-windows-msvc
```

No source changes were needed. The Agility SDK DLLs are not: vkd3d-proton replaces them.

### Run

```bash
scripts/play-victory.sh -v <folder with d3d12.dll and d3d12core.dll> <dump folder>
```

- Use GE-Proton with **Proton Experimental's vkd3d-proton** (`<Proton - Experimental>/files/lib/wine/vkd3d-proton/x86_64-windows`, 3.2.0, build `2576c0b4adfae4a`). GE-Proton11-12's own crashes (finding 1).
- Stock Proton started outside Steam shows an `lsteamclient` assertion (its `steam.exe` helper). `PROTON_VERB=runinprefix` avoids it once the prefix exists.
- Pass the program as a Windows path (`Z:\...`): with a host path GE-Proton's helper drops console output.
- State (prefix, cache, saves) is in `~/.local/share/scarlettport`.
- `RUST_MIN_STACK` is set to 64 MB by the script. It takes effect but does not cure finding 2.

### Unattended tests

`scripts/test-victory.sh [-t s] [-i s] [-w s] [-n name] [-H] -v <folder> <dump folder>` presses through menus (fast boot), uses save slot `autotest` copied from `default`, takes window pictures and writes `summary.txt` and `stats.txt` (seconds, mappings, CPU seconds of wineserver and of the title) to `screenshots/`. `-H` hides it in a headless gamescope. Sound goes to a null sink; not checked by ear.

- The "in world" detection is not reliable: it did not trigger in runs that reached the same screens. Compare `stats.txt` and the pictures.
- `VICTORY_CAPTURE` saves only the first present plane, so menus look black. Photograph the window.

## Findings

### 1. GE-Proton's vkd3d-proton crashes RADV (worked around)

- dxil-spirv turns pixel shader `14ddb11a47b353c5` into invalid SPIR-V. `spirv-val`: "block exits the loop, but not via a structured exit".
- Mesa's `spirv_to_nir` returns NULL and RADV writes through it (`radv_shader.c:525`, from `radv_CreateGraphicsPipelines`), found with Ubuntu's debug symbols. `MESA_SPIRV_FAIL_DUMP_PATH` gives the rejected SPIR-V.
- Experimental's vkd3d-proton translates that shader. Certain.

### 2. Six compute shaders overflow the pipeline threads' stacks

- `e8c962358d862e3f afeea48bbb9913ad a1b20bc47e3c9597 32ed072b9f845048 17829ac71aab4e8d 559d9f0184e15fe3`. Of about 1,500 shaders dumped, exactly these never finished, and six of eight `victory-pipelines` threads die. Reproduced offline.
- A hung thread's 64 MB stack holds one return address repeated (`d3d12core.dll+0x288515`, 128 bytes a frame). Certain.
- Reading the disassembly next to dxil-spirv's source (`061225d`, not built) it matches `CFGNode::find_common_dominator` and `recompute_immediate_dominator` (`node.cpp`) calling each other. Likely, not proven with symbols.
- `VICTORY_SHADER_OPT=2` lets three of them build (`32ed…`, `afee…`, `1782…`; "pipeline created" seen for `32ed…`, exit 0 for the other two). `e8c9…`, `a1b2…`, `559d…` fail with unset, `2`, `3`, `10` and `on`. Offline only: never run on the card. Upstream warns that `on` can lose walls.

### 3. The world is black

In gameplay, per frame:

- the six passes above are dropped ("being made");
- about 4,570 indirect draws are dropped, "not bounded (no clamp, or arguments not 4-byte aligned)". The argument clamp (`indirect.rs`) is built with `D3DCompile`, and Wine's compiler refuses it: `E5005: Method 'InterlockedMax' is not defined on type 'RWByteAddressBuffer'`;
- ray-tracing shading is left out on every platform, so shadowed areas would be dark anyway.

Wine's compiler also refuses the shader of "host copies in the card's memory" ("Invalid shader"); that only turns an optimisation off.

### 4. Microsoft's d3dcompiler_47 removes the drops, and the GPU hung

With a native `d3dcompiler_47.dll` beside the program there were 0 "not bounded" lines and host copies were on. After 141 s the card hung: kernel `ring gfx_0.0.0 timeout`, "Ring gfx_0.0.0 reset succeeded"; RADV "GPUVM fault detected at address 0x00000000". The desktop survived. One run; cause not known (the indirect draws, host copies, or something else). It was on the main display: save work first.

### 5. Loading is slow because of wineserver

- It sits at 100% of one core while the title waits. `perf` for 10 s during loading: 59.6% `is_valid_view_addr`, 33.9% `req_unmap_view`.
- The title changes mappings 300 to 1,800 times a frame, at 0.6 to 0.8 ms each, with 20,000 to 57,000 mappings in the process. Wine's functions appear to walk all views; the source was not read.
- wineserver's CPU time stops growing much once loaded (444 s at 497 s, 485 s at 663 s).

## Tried without success

| What | Outcome |
|---|---|
| Larger thread stacks (64 MB) | same overflow |
| `map_alias` mapping page runs as one view (`xmem.rs`) | mappings -7%, wineserver CPU unchanged (82 against 83 s at 117 s); reverted |
| Proton Experimental's Wine | same wineserver load (89 s at 117 s) |
| Clamp shader rewritten for Wine's compiler ([indirect-clamp-wip.patch](indirect-clamp-wip.patch)) | gets past missing atomic methods and `allow_uav_condition`, then fails 0x80004005 with no message. Unfinished; its own test fails. Never run on the card |

## Open questions

1. Fix or update dxil-spirv for the three shaders left. Building it from source has not been done.
2. Why the card hung with Microsoft's compiler: try it with host copies off.
3. Whether a Wine with a faster view lookup fixes loading.
4. On Windows none of findings 1, 2, 3 (clamp) or 5 should apply, as no vkd3d-proton or Wine is involved. Not tested.
