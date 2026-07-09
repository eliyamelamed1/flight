# Air-Gapped Git Sync Toolkit

Sync application code from an internet-side **external** git repo into an isolated,
air-gapped **internal** repo — with internal-specific content applied via a find/replace
dictionary — and feed it into an internal promotion pipeline.

```
external main --(git bundle across the air gap)--> internal
   |                                                    |
   |  export-bundle.ps1        sync-from-bundle.ps1     v
   +--------------------------> pre-dev --> develop --> staging --> main
                                (external + dictionary transform)   (your promotion pipeline)
```

## The everyday flow: two commands

Copy `scripts/` to each side — that folder is your **kit**. Everything the commands need
lives beside them by convention (`repo\external`/`repo\internal` = each command's git
repo, `toUpload\` = pending bundles, `doneUpload\` = landed bundles). Each command has
its own repo folder, so one kit can even run both sides (handy for local testing):

```powershell
.\'1 - takeoff.cmd'   # EXTERNAL: reads the GitHub URL from repos.json -> refreshes repo\external
                      #           -> writes toUpload\<repo>-<timestamp>\app.bundle
# ── carry that toUpload\<name> folder across the air gap into the internal kit's toUpload\ ──
.\'2 - landing.cmd'   # INTERNAL: reads your internal server URL from repos.json -> first run
                      #           bootstraps, later runs advance pre-dev -> pushes the branches
                      #           -> moves the landed folder toUpload\<name> -> doneUpload\<name>
```

No paths to remember. Each command takes its URL from `-RepoUrl`, else the kit's
`repos.json` (create once, fill your side's key: `externalRepoUrl` / `internalRepoUrl`),
else prompts for it. The launchers are double-clickable (numbered in run order); all the
PowerShell lives in `scripts/engine/`.

## How it works (the short version)

- **External is the source of truth** for application code. The internal repo never
  edits application files by hand.
- Each sync carries a **full `git bundle`** across the gap (self-contained; a lost or
  out-of-order bundle is harmless).
- The bundle is imported into an isolated `refs/upstream/*` namespace (mirrors all
  branches + tags; no collisions).
- `pre-dev` is **forward-advanced** one commit per sync: external `main` content with a
  **dictionary transform** applied (e.g. `eliya`→`dori`) to produce internal-specific text.
- You promote `pre-dev → develop → staging → main` with your normal PR/CI gates.

## Scripts (`scripts/`, run from OUTSIDE the synced repo)

The kit top level holds only what the operator touches (ADR-0019):

| File | Side | Purpose |
|--------|------|---------|
| `1 - takeoff.cmd` | external | Refresh `repo\external` from the configured URL, write `toUpload\<repo>-<timestamp>\app.bundle` |
| `2 - landing.cmd` | internal | Consume the pending `toUpload\` bundle: bootstrap-or-sync (auto-detected), push to the configured URL, then move the folder to `doneUpload\` |
| `repos.json` | both kits | Per-kit remote URLs (`externalRepoUrl`/`internalRepoUrl`) — created by the operator; gitignored (ADR-0019/0020/0022) |
| `dictionary.json` | internal kit | The find/replace pairs — starter written by the first landing; gitignored; auto-backed-up to the server's `airgap-config` branch every landing (ADR-0017/0022) |
| `README.md` | both kits | Plain-language operator guide that travels with the kit |

All the PowerShell lives in `scripts/engine/` — the launchers call `engine\takeoff.ps1` /
`engine\landing.ps1`, which drive the rest (run the engine scripts directly for explicit
paths / advanced use; you don't touch them in the everyday flow):

| Script | Side | Purpose |
|--------|------|---------|
| `engine\takeoff.ps1` | external | The takeoff logic (launched by `1 - takeoff.cmd`) |
| `engine\landing.ps1` | internal | The landing logic (launched by `2 - landing.cmd`) |
| `engine\export-bundle.ps1` | external | Create a full bundle of all refs |
| `engine\bootstrap-internal.ps1` | internal | One-time: clone + first sync + create pipeline branches |
| `engine\sync-from-bundle.ps1` | internal | Each update: forward-advance `pre-dev` (external + transform) |
| `engine\reconcile-main.ps1` | internal | After a hotfix on `main`: realign it to `staging` (defaults to the kit's `repo\internal`) |
| `engine\render-config.ps1` | build | Render `config.json` from template + values (never committed) |

## Docs

- [docs/RUNBOOK.md](docs/RUNBOOK.md) — bootstrap, steady-state sync, hotfix procedures, guardrails
- [docs/adr/DECISIONS.md](docs/adr/DECISIONS.md) — architecture decision records (the "why")
- [docs/GLOSSARY.md](docs/GLOSSARY.md) — terminology

## Key operating rules

- Never hand-edit `pre-dev`/`main`. App changes go **upstream**; internal content diffs go
  in **`dictionary.json`**.
- **Branch-protect** `develop`/`staging`/`main` on the internal server (the real guard
  against accidental direct pushes — not scriptable).
- Hotfixes: prefer a throwaway branch (never merged); if you must commit to `main`,
  re-author an equivalent fix upstream and run `engine\reconcile-main.ps1` (see RUNBOOK / ADR-0014).

## Platform

Windows / PowerShell 5.1. Requires `git` on `PATH`. Validated end-to-end against real git:
run `.\tests\test-kit.ps1` — a fully local suite (path remotes, no network) covering the
whole flow and every refusal/fallback path.
