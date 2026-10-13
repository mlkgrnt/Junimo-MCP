# Junimo-MCP

[![CI](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml/badge.svg)](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml)

[简体中文](README.md) · [繁體中文](README.zh-Hant.md) · **English** · [Español](README.es-ES.md)

A **hand-written OCaml** MCP server — a pair of working hands for AI agents in *Stardew Valley*: **35 intent tools** covering everything from tilling and harvesting to item pickup, meals, socializing, and festivals, executed reliably end to end.

- **Protocol layer**: JSON-RPC 2.0 over stdio, implemented by hand (`initialize` / `tools/list` / `tools/call`), zero MCP framework dependencies
- **Control layer**: curl subprocess → [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix) over HTTP (default `http://localhost:7842`) → the in-game character
- **No fake success**: a tool reporting success means it really happened in-game; most failures have no side effects (a failed gift is returned, a failed meal consumes nothing), so retrying is safe
- **Minimal dependencies**: the only third-party OCaml library is yojson; at runtime it just needs the system curl

## Don't want to develop it? Let an agent deploy it

```bash
git clone https://github.com/mlkgrnt/Junimo-MCP.git
```

Hand the repo to your AI client (WorkBuddy / Claude Code / Cursor / any agent that can read files and run commands) and say:

> **"Read AGENTS.md and get Junimo-MCP deployed and working."**

The agent will follow the *Deployment* section of `AGENTS.md` and do everything automatically:
**install SMAPI → install the executor mod → deploy the server → register the MCP connector → verify it works.**

You only need two things: ① a Windows machine with *Stardew Valley* installed; ② one **Trust** click at the registration step, then restart your client.

> **Prebuilt binaries live in Releases**: grab `junimo-mcp.exe` from the [latest release](https://github.com/mlkgrnt/Junimo-MCP/releases/latest) (with a SHA-256 checksum file) — no dev environment required.
> Prefer doing it by hand? See *Manual install* below.

## What it looks like

```
┌────────────┐   stdio (JSON-RPC)   ┌──────────────────┐   HTTP localhost:7842   ┌──────────────────┐
│ MCP client │ ◄──────────────────► │ junimo-mcp.exe  │ ◄─────────────────────► │ NagiBridge-Remix │ ──► Stardew Valley
│  (your AI) │    35 intent tools   │    (OCaml 5.5)   │     curl subprocess     │    (SMAPI mod)   │
└────────────┘                       └──────────────────┘                         └──────────────────┘
```

Engineering highlights:

- **Three reliability disciplines**: server-side validation, per-cell tri-state scoring (success / idempotent skip / failure with reason), and precise read-back — "never fake success";
- **Four layers of tests**: unit tests + a **114-assertion mock smoke test** (no game needed) + live test suites + a soak test;
- **Plain-language replies**: tools return human-readable text that agents can pass to users verbatim (currently written in Chinese).

## Prerequisites

| Item | Version / Notes |
|---|---|
| Game | Stardew Valley **1.6.15** (tested on the Steam version) |
| SMAPI | **4.5.2** (or a compatible 4.x) |
| NagiBridge-Remix | **v0.9** (extract into `Mods/NagiBridge/`) |
| OCaml (development / building only) | **5.5.0** + dune 3.24 + yojson 3.0 (Windows: opam + a managed Cygwin, see below) |

> ⚠️ **Remix and the original NagiBridge cannot be installed together**: they have different UniqueIDs (`pendel001.NagiBridge` vs `Nagi.NagiBridge`) and would fight over port 7842. To migrate, move the old `Mods/NagiBridge/` folder out of the Mods directory before extracting the new version.
>
> Licensing note: Remix is an authorized fork (PolyForm Noncommercial 1.0.0; free for personal / non-commercial use). This project talks to it over HTTP and does not bundle its code.

Launch the game by running `StardewModdingAPI.exe` in the game folder (**don't launch via Steam**, or mods won't load; the trade-off is that Steam achievements stay disabled). Once you load a save, NagiBridge serves on port 7842 automatically.

## Manual install (4 steps)

> Mirrors the *Deployment* section of `AGENTS.md`, which has the detailed verification steps and troubleshooting.

| Step | What to do | Notes |
|---|---|---|
| 1 · SMAPI | Install the mod loader | Skip if `StardewModdingAPI.exe` already exists in the game folder |
| 2 · Executor mod | Install NagiBridge-Remix | Extract into `<GAME>\Mods\`; **move the original NagiBridge away first if present** |
| 3 · Server | Download `junimo-mcp.exe` from [Releases](https://github.com/mlkgrnt/Junimo-MCP/releases/latest) and place it somewhere stable | No build needed; avoid the C: drive and paths with spaces |
| 4 · Register | Write `~/.workbuddy/mcp.json` → Trust → restart | Format below |

`~/.workbuddy/mcp.json`:

```json
{
  "mcpServers": {
    "junimo": {
      "command": "D:/junimo-mcp/junimo-mcp.exe",
      "env": { "STARDEW_API_URL": "http://localhost:7842" }
    }
  }
}
```

It **does not take effect automatically**: in WorkBuddy open *Connector management → Custom connectors (top right)*, click **Trust** for `junimo`, then restart WorkBuddy.

**Using another client? Four popular ones ship with copy-paste configs** (details in `AGENTS.md`, *Step 5 · Register with an MCP client*):

| Client | Config location | Quick setup |
|---|---|---|
| WorkBuddy | `~/.workbuddy/mcp.json` | Click Trust in the GUI |
| Claude Code | `~/.claude.json` / project `.mcp.json` | `claude mcp add --transport stdio junimo -- "<EXE>"` |
| Codex | `~/.codex/config.toml` | `codex mcp add junimo -- "<EXE>"` |
| DeepSeek Harness | `$DSH_HOME/profiles/<name>/cordis.patch.yml` | A cordis patch entry (see AGENTS.md) |

## Smoke check

```bash
# Is the bridge alive? (the --noproxy '*' flag is required: it bypasses the system proxy)
curl -sS --noproxy '*' http://localhost:7842/status
# {"ok":true,"server":"NagiBridge",...,"worldReady":true,...}
```

> ⚠️ The address must be `http://localhost:7842` — **not `127.0.0.1`**: the mod's HttpListener only registers the localhost prefix, and 127.0.0.1 gets rejected with HTTP 400 (observed in real runs).

## Tool reference (35)

| Group | Tool | Description |
|---|---|---|
| Perception | `get_state` | Full state (player / position / time / **weather** / inventory / menu) + state strip |
| | `look` | Scan a radius: crops (stage / watered / harvestable), objects, trees & stones, NPCs |
| | `get_inventory` | Inventory listing (the watering can includes its remaining water) |
| Movement | `go_to` | Pathfinding movement (**long distances are automatically split into shuttles**; refuses the straight-through-walls fallback; ≤1 tile away counts as arrived — some destination tiles aren't standable in-game, so it stops adjacent and reports the real coordinates) |
| | `warp` | Cross-map teleport (async; reads back to confirm where you landed) |
| | `face` | Turn 0 up / 1 right / 2 down / 3 left |
| Interaction | `swing_tool` | Swing the tool once (goes through `/use`: server-side validation, reports the tile actually hit) |
| | `use_held` | Use the held item (plant / place) |
| | `interact` | Interact with the tile in front (= the confirm key); returns that tile's info |
| | `press_key` | Send key presses (confirm / cancel / numbers / directions…) |
| UI | `menu_read` | Read the current menu / dialogue / shop / buttons |
| | `menu_click` | Click a menu (option index / button name / coordinates) |
| Items | `select_item` | Select an inventory item as the held item |
| Farm work | `till` | Batch tilling (snake-pattern movement; idempotent: "already tilled" is a soft skip; stops below 15% stamina) |
| | `plant` | Batch planting (tiles must be tilled; "crop already here" is a soft skip) |
| | `water` | Scans for "planted but not watered" tiles and waters them one by one (refills the can automatically) |
| | `harvest` | Batch-harvest mature crops (instant in-game; goes straight into the inventory) |
| Chests | `chest_scan` | Scan every chest on the current map (position + contents + slot) |
| | `chest_take` | Take from one chest (`name` or `slot`; `count` defaults to all; if it doesn't fit it stays in the chest and says so) |
| | `chest_take_list` | Gather a list across chests (only chests within 4 tiles, i.e. reachable; distant ones are reported under tooFar with coordinates) |
| Eat | `eat` | Eat to restore stamina / HP / get buffs (pass a name to auto-select; reports before/after values; failure consumes nothing) |
| Social | `find_npc` | Find any NPC (fuzzy match on Chinese or English names; position / facing / sleeping / current line) |
| | `friendship` | Friendship info (points / hearts / gifts sent this week and today; Chinese names are resolved automatically) |
| | `gift` | Give an NPC a gift (the real flow; reports taste tier and friendship change; returns the gift if the limit is hit or it's refused) |
| Festivals | `festival` | Festival info (today / tomorrow / next + live status if one is running) |
| | `festival_interact` | Interact with NPCs on festival grounds (auto-positions and triggers; only during a live festival) |
| | `festival_answer` | Submit a festival answer / branch (`answer` index) |
| Livelihood | `sleep` | Sleep to advance the day (**the only way to save** — SDV only writes saves when sleeping / rolling over the day); returns the new day's state |
| | `buy` | Remote purchase (sale price ×2, straight to inventory; id 472 = parsnip seeds) |
| | `ship` | Sell via the shipping bin (pass `name` or `all=true`; tools / seeds / equipment are kept; must be on the farm) |
| | `chest_read` | Read a chest's contents (any distance on the same map, no need to open it) |
| | `chest_store` | Store inventory items into a chest (tools are kept by default) |
| | `map_info` | Buildings / warps / NPCs / animals (for route planning) |
| | `pause_time` | Freeze the game clock (prevents passing out on long tasks; remember to resume) |
| | `resume_time` | Resume the frozen game clock |

Farm-work discipline for the whole group: stand at `(tx, ty-1)` facing down → **teleport + precise read-back verification** → `/use` (confirm the returned tile == the expected tile) → settle 0.55s; every failure is listed with its reason — it never swings blindly.

## Building from source (developers)

With a standard opam setup (Linux / macOS / plain Windows), just use dune:

```bash
opam install yojson      # the only third-party dependency
dune build               # → _build/default/bin/main.exe
dune runtest             # unit tests
```

On the managed Cygwin toolchain (this project's dev environment on Windows), use the `build.sh` wrapper — it sets up the managed Cygwin bash + `pi-env.sh` + `OCAMLPATH` and always removes `_build/.lock` (a stale lock causes mysterious errors):

```bash
bash build.sh build          # dune build → _build/default/bin/main.exe
bash build.sh runtest        # unit tests
bash build.sh release        # build and copy to release/junimo-mcp.exe
bash build.sh exec -- ...    # pass through any dune subcommand
```

Toolchain war stories (setup, Cygwin argument rewriting, the lock pitfall, etc.) are documented in the companion skill "ocaml-windows-toolchain".

## Tests

| Suite | Command | Description |
|---|---|---|
| Unit tests | `bash build.sh runtest` | JSON-RPC codec, state parsing / rendering, snake-pattern tile math |
| Mock smoke | `python test/mock_smoke.py` (spins up the mock) | A fake NagiBridge (full state machine: map / movement / menus / validation / livelihood / pickups / social / festivals), **114 assertions** end to end, **no game needed** |
| Live end-to-end | `python test/live_e2e.py` | Needs the game running: till → plant → water + independent HTTP cross-checks |
| Live full farm day | `python test/live_m4.py` | Needs the game running: auto-load save → buy seeds → 3×3 till / plant / water → ripen & harvest → long-distance shuttle navigation |
| Live v2 livelihood | `python test/live_v2.py` | Needs the game running: map / chest read-write / clock control / **sleep to roll the day (advances a day and saves)** |
| Live v3 life | `python test/live_v3.py` | Needs the game running: weather / chest scan & take / eat / find NPC & gift / festivals (minimal, reversible changes) |
| Live spot-check | `python test/live_swing.py` | Positive / negative cases for a single tool swing |
| Soak test | `python test/live_soak.py [minutes]` | Continuous read-write + movement; reports error rate and curl subprocess reclamation |

The mock and live modes share the same code path (only `STARDEW_API_URL` changes), and the mock's `/use` validation semantics match the real mod word for word.

CI (GitHub Actions, ubuntu) runs on every push / PR: build + unit tests + mock smoke.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `STARDEW_API_URL` | `http://localhost:7842` | NagiBridge address (must be localhost) |
| `STARDEW_CURL` | auto-detected | Override the curl.exe path |
| `STARDEW_TIMEOUT` | `30` | Per-call HTTP timeout (seconds) |
| `STARDEW_NO_STRIP` | unset | `=1` disables the trailing state strip |
| `STARDEW_LOG` | `warn` | stderr log level (debug / info / warn) |

## Known limitations

- **Screenshots / video are unavailable**: GDI can't capture the OpenGL frame on this machine — verification relies on in-game API readings (which are more precise anyway).
- **Long-distance movement**: the mod's BFS has a 500-step cap; `go_to` works around it with built-in shuttling (≤10 tiles per leg). Use `warp` to cross maps.
- **Menus don't auto-advance**: any action that opens a menu (dialogue / shop) aborts with a report; the agent handles it explicitly via `menu_read` / `menu_click`.
- **Long idle sessions**: call `pause_time` first to freeze the clock (about 12 real minutes takes the in-game day to 2:00 AM, passing out and — measured — costing 10% of your gold); call `resume_time` when done.
- **Remote buying**: the mod's `/buy` endpoint charges ×2 the sale price (a convenience/debug endpoint without a shop UI).
- **No "tomorrow's weather"**: only today's weather is available (the weather line in `get_state`); "is today / tomorrow a festival" is computed by a built-in calendar.
- **Getting to a festival is on you**: the `festival` tools cover intel and on-site interaction; walk to the venue through the game's normal entrance — don't `warp` onto a festival map (the scene won't trigger).
- Before harvesting / picking things up, check free inventory space with `get_inventory` (a full inventory drops items on the ground).
- **Progress is saved only via `sleep`**: closing the game without sleeping discards the day's actions — have the agent `sleep` at the end of each session.

## Documentation

| Doc | Audience | Content |
|---|---|---|
| `AGENTS.md` *(Simplified Chinese)* | **AI agents** | Deployment + ten iron rules + 35-tool cheat sheet + development discipline |
| `README.md` / `README.zh-Hant.md` / `README.en-US.md` / `README.es-ES.md` | Humans | Simplified Chinese (zh-Hans, default) / Traditional Chinese / English (this file) / Spanish |
| `test/` | Developers | Four-layer test suite |

## License & credits

This project's own code is open source under the **MIT** license — see [LICENSE](./LICENSE).

- Executor mod: [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix) by pendel001 (PolyForm Noncommercial 1.0.0; free for personal / non-commercial use). This project talks to it over HTTP and does not bundle its code.
- Original upstream: [NagiBridge](https://github.com/anqinou-art/NagiBridge) (MIT)
- Control-layer philosophy and endpoint semantics: the original NagiBridge author (`farm_row.py` / `water_crops.py` stance and timing discipline)
- The state strip design references NagiBridge-Remix
