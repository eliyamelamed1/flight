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
lives beside them by convention (`repo\` = the git repo, `transfer\` = the bundle):

```powershell
.\takeoff.ps1     # EXTERNAL: asks for the GitHub URL -> refreshes repo\ -> transfer\app.bundle
# ── carry transfer\app.bundle across the air gap into the internal kit's transfer\ ──
.\landing.ps1     # INTERNAL: asks for your internal server URL -> first run bootstraps,
                  #           later runs advance pre-dev -> pushes the branches
```

No paths to remember, nothing stored between runs — each run asks for its one URL.
(`takeoff.cmd` / `landing.cmd` are double-click launchers for the same scripts.)

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

The everyday commands (each prompts for its repo URL every run):

| Script | Side | Purpose |
|--------|------|---------|
| `takeoff.ps1` (+`.cmd`) | external | Refresh `repo\` from the URL you give, write `transfer\app.bundle` |
| `landing.ps1` (+`.cmd`) | internal | Consume `transfer\app.bundle`: bootstrap-or-sync (auto-detected), push to the URL you give |
| `dictionary.sample.tsv` | internal kit | Template — copy to `dictionary.tsv` once, then edit the real one (gitignored; auto-backed-up to the server's `airgap-config` branch every landing, ADR-0017) |
| `README.md` | both kits | Plain-language operator guide that travels with the kit |

The engine underneath (called by the wrappers; run directly for explicit paths / advanced use):

| Script | Side | Purpose |
|--------|------|---------|
| `export-bundle.ps1` | external | Create a full bundle of all refs |
| `bootstrap-internal.ps1` | internal | One-time: clone + first sync + create pipeline branches |
| `sync-from-bundle.ps1` | internal | Each update: forward-advance `pre-dev` (external + transform) |
| `reconcile-main.ps1` | internal | After a hotfix on `main`: realign it to `staging` (defaults to the kit's `repo\`) |
| `render-config.ps1` | build | Render `config.json` from template + values (never committed) |

## Docs

- [docs/RUNBOOK.md](docs/RUNBOOK.md) — bootstrap, steady-state sync, hotfix procedures, guardrails
- [docs/adr/DECISIONS.md](docs/adr/DECISIONS.md) — architecture decision records (the "why")
- [docs/GLOSSARY.md](docs/GLOSSARY.md) — terminology

## Key operating rules

- Never hand-edit `pre-dev`/`main`. App changes go **upstream**; internal content diffs go
  in **`dictionary.tsv`**.
- **Branch-protect** `develop`/`staging`/`main` on the internal server (the real guard
  against accidental direct pushes — not scriptable).
- Hotfixes: prefer a throwaway branch (never merged); if you must commit to `main`,
  re-author an equivalent fix upstream and run `reconcile-main.ps1` (see RUNBOOK / ADR-0014).

## Platform

Windows / PowerShell 5.1. Requires `git` on `PATH`. Validated end-to-end against real git.
