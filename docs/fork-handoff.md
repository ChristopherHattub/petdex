# Fork handoff (ChristopherHattub/petdex)

Read this first if you are a new agent picking up Chris's fork of crafter-station/petdex. Upstream rules are in `AGENTS.md`; this file covers only what the fork adds. Keep it current when you change those areas.

## Working with Chris
- Brief, technical answers. Default model is Sonnet.
- Do NOT ask to run commands on his Mac, and do not suggest permission rules or Remote Control for builds. He runs builds himself by double-clicking "Update Petdex" on his Desktop.
- Everything ships as a PR into the fork's `main` (not upstream). Chris merges. After merge he runs the updater.
- Never put secrets, tokens, topics or hostnames from `~/.petdex-ntfy/env` in the repo.

## What the fork adds (all in `packages/petdex-desktop-native/src/`)
Changes are kept in new files so rebases onto upstream stay small; `main.zig` only gains call sites and Model/Msg fields.

| File | Purpose |
|---|---|
| `agent_rail.zig` | Translucent click-through companion window ("agent-rail") right of the pet. One row per agent type, fixed order Claude Code, Gemini/Antigravity, Codex, then others, always visible (grey idle ring). Ring = most urgent session status (yellow needs_input > red running > green done/failed > grey idle). 2+ sessions extend the tab right with a ring per session (mirrors left near the screen edge). Done entries linger 10 min. Also draws Agent-Pets (a separate pet per agent row; two agents cannot share one pet) and the idle-only clock. macOS/Windows only; off on Linux. Uses one of the SDK's 4 secondary windows (bubble, rail, flock, settings). |
| `ntfy.zig` | Opt-in push from the app to a self-hosted ntfy server on the same edges as the rail (agent waiting, or working agent finished). Config is read once from `~/.petdex-ntfy/env`: must be chmod 600, needs `NTFY_FROM_APP=1`, https URL (http only to loopback), write-only token. Text only, max 20 sends/min, token never logged. If the old bash hook is still installed Chris gets duplicates. |
| `xp.zig` | Pet XP, saved to `~/.petdex/pet-xp.json`. Level gap is `60 + 20*(L-1)` XP. Awards: +10 per red-then-green cycle, +15 per finished thread, +30 per resolved/ended thread, +1 per working minute. Pure arithmetic, unit tested. The award rules live in `main.zig`. |
| `levelup.zig` | Level-up flourish: hop, gold flash, ring of 8 sparkles over 1.8 s. Pure function of elapsed time. |
| `evolution.zig` | See below. |
| `settings_view.zig` | Pokedex-style Settings (red top and bottom shell, holographic blue middle, party screen with levels). Sections: pet, agent_pets, agents, appearance, messages, general, updates. Upstream file, heavily edited. |

Installer pieces: `scripts/install-fork-macos.sh` (build + ad-hoc sign + install `/Applications/Petdex.app`, retires every other Petdex, copies `scripts/fork-pets/*` into `~/.petdex/pets`), `scripts/update-fork-macos.command` (Terminal wrapper), `scripts/patch-native-sdk.sh` plus `patches/native-sdk-*.patch`.

### Evolution
- Pets outside any line use the default tree: same sprite, purple tint at Lv 5, gold at Lv 12 (`applyTint`, in place).
- Traditional lines are the `traditional` table in `evolution.zig`: `{from, to, level}`. Reaching `level` on the earlier pet's own XP unlocks `to` as a new collection entry; the earlier pet is kept. Later species are hidden until unlocked, and `main.zig` rescans the catalog on unlock.
- Current lines: squirtle -> wartortle (Lv 5), wartortle -> blastoise (Lv 8).
- Chris wants ALL evolutions to work this way eventually (tint stages as separate entries). Not done; he was offered it.

## Adding a pet
1. Atlas: 1536x1872 WebP, 8 columns of 192x208, 9 state rows in this order: idle, running-right, running-left, waving, jumping, failed, waiting, running, review. Frame counts per row are in `sprite.zig` (idle 6, waving 4, jumping 5, failed 8, waiting 6, running 6, review 6, runs 8). Unused cells transparent.
2. `pet.json`: `{ "id": "<slug>", "displayName": "...", "description": "...", "spritesheetPath": "spritesheet.webp" }`.
3. Drop both into `scripts/fork-pets/<slug>/`. The installer copies them to `~/.petdex/pets/<slug>/`. Update `scripts/fork-pets/README.md` if needed.
4. From a Gemini-generated sprite grid: key the checkerboard background to alpha, slice by row bounds, then remap rows to the 9 states above. Check the result visually before committing.
5. For an evolution line add a Step to `traditional` in `evolution.zig` and extend its tests.
- Active pet and per-agent pets are in `~/.petdex/desktop-native-settings.json`. Chris's custom Ghost pet (`ghost-ai`) is not in the repo; its files are in the project folder `ghost-pet/`.
- Bundled now: bmo, squirtle, wartortle, blastoise.

## Build and test
Desktop app is `packages/petdex-desktop-native`: Zig 0.16.0 plus Railly/native SDK, branch `feat/floating-window-0.5.3`, pinned to commit `c0b10d027efa490fc99a3bc7f1cf88b015999d45`, patched by `scripts/patch-native-sdk.sh` (idempotent, fails if the pin drifts).

Cloud container (Linux):
- ziglang.org is blocked. Install Zig from PyPI: `pip install ziglang==0.16.0` and put its dir on PATH.
- Clone the SDK at the pinned ref, `export NATIVE_SDK_PATH=<clone>`, run `scripts/patch-native-sdk.sh`, then `zig build cli` in the SDK to get `native`.
- `native test .` in the package runs the unit tests. The Linux link step fails only because gtk4 is not installed; test results before that point are valid. You cannot run the GUI here.
- You cannot build or run the macOS app in the cloud. Chris verifies on his Mac, so say plainly in the PR what is untested visually.

Mac (Chris, via the updater): `native build -Dcpu=baseline -Dtrace=off`, then `native package --target macos --signing adhoc`. Toolchain lives in `~/src/toolchains` (Zig venv) and `~/src/native-sdk`; the repo clone is `~/src/petdex`. The updater pulls `main` first, switching off stale merged branches, and re-execs itself if the pull changed anything.

Root web app commands (Bun, `bun run check`, etc.) are in `AGENTS.md`; fork work rarely touches them.

## ntfy (phone and watch)
Self-hosted ntfy in Docker Desktop on Chris's Mac, bound to 127.0.0.1 and exposed only through `tailscale serve` on his tailnet. Auth is deny-all: phone user is read-only, the publisher uses a write-only token, topic is random. Secrets live only in `~/.petdex-ntfy/env` (chmod 600). Setup scripts and README are in the project folder `petdex-ntfy/` (setup-server.sh, server.yml, install-hook.sh, petdex-ntfy-hook.sh). The bash hook in `~/.claude/settings.json` is the older path; in-app ntfy (`ntfy.zig`) replaces it when `NTFY_FROM_APP=1`. The cloud cannot reach the server, so Chris must test sends.

## Agent integrations
Hooks come from upstream `agent_hooks.zig`/`hook_server.zig` (mailbox of per-session bubbles, max 8, with reconciled `SessionStatus`). Antigravity hooks live in `~/.gemini/config/hooks.json`; the "antigravity" agent resolves to the gemini row and uses `antigravity.png` as its icon. An empty conversation key matches any agent in `BubbleIdentity.matches`.

## Known open issues
- "Can't change pet while a thread is active" is unconfirmed; mitigated by making the rail clock idle-only.
- Linux has no rail (no popup anchor).
- Tint evolution stages are not yet separate collection entries (see Evolution).
- Updater has hit stale-branch builds before; keep the switch-to-main logic.
- Ghost pet and ntfy scripts are only in the project folder, not in the repo.
