# Glossary — Air-Gapped Git Sync Pipeline

- **Air gap** — Physical/network isolation; the two repos can never talk directly. All
  transfer happens via files (git bundles) carried across.
- **Kit** — A copy of `scripts/` on one side of the gap. Only the launchers and config
  sit at the top (ADR-0019/0022): `1 - takeoff.cmd` / `2 - landing.cmd`, `repos.json`
  (created by the operator), and on the internal side `dictionary.json` (starter written
  by the first landing, ADR-0016/0017/0022). Runtime assets sit beside them by convention
  (`repo\external` / `repo\internal` = each command's git repo, ADR-0021; `toUpload\` /
  `doneUpload\` = the bundle handoff, ADR-0020); all the PowerShell lives in `engine\`.
  One kit can run both commands — each side has its own repo folder.
- **`airgap-config`** — Orphan branch on the internal server where landing automatically
  versions `dictionary.json` each run; the restore source when a kit loses its dictionary
  (ADR-0017).
- **Takeoff** — The external-side everyday command (`1 - takeoff.cmd` → `engine\takeoff.ps1`):
  reads the GitHub repo URL from `repos.json` (prompting if unset), refreshes the kit's
  `repo\external` (a bare relay clone), and writes the bundle into a per-run folder
  `toUpload\<repo>-<timestamp>\app.bundle` for carrying across the gap.
- **Landing** — The internal-side everyday command (`2 - landing.cmd` → `engine\landing.ps1`):
  reads the internal server URL from `repos.json` (prompting if unset), consumes the one
  pending bundle folder in `toUpload\` (first run bootstraps, later runs advance
  `pre-dev`), pushes the result to that URL, and then moves the folder to `doneUpload\`.
- **`repos.json`** — Per-kit remote URLs (`"externalRepoUrl"` for takeoff,
  `"internalRepoUrl"` for landing); created once by the operator (the prompt shows the
  shape) and gitignored. An empty or missing key falls back to a prompt; `-RepoUrl`
  overrides both (ADR-0019/0020/0022).
- **`toUpload\` / `doneUpload\`** — The bundle handoff (ADR-0020): takeoff writes each
  bundle into a fresh `toUpload\<repo>-<timestamp>\` folder; the operator carries that
  folder into the internal kit's `toUpload\`; landing processes exactly one pending folder
  per run and moves it to `doneUpload\` only after a successful push — pending vs landed
  is visible at a glance.
- **External repo** — The internet-side repository. Absolute source of truth for
  application code.
- **Internal repo** — The air-gapped repository. Holds application code plus internal-only
  additions (CI/CD, configs).
- **Dictionary transform** — A `from`->`to` find/replace applied to text files on every sync
  to produce internal-specific content (e.g. `eliya`->`dori`). The current internal delta
  mechanism (ADR-0012); replaces overlay injection. Stored outside the synced branches.
- **`internal-overlay`** — (Superseded, ADR-0012) Branch that used to hold internal-only files
  in the overlay model.
- **`pre-dev`** — Internal branch forward-advanced every sync = external `main` with the
  dictionary transform applied. (ADR-0011 structure; ADR-0012/0013 content.)
- **`main`** — Internal production/deploy branch — the top of the promotion pipeline
  (`pre-dev → develop → staging → main`; renamed from `master`, ADR-0015). Reached by promotion,
  not by the sync (ADR-0013).
- **`upstream-base` / `pre-main`** — Older branch names from the superseded 2-branch model
  (ADR-0003). See `pre-dev`/`main` above for the current model.
- **git bundle** — A single file packaging git objects/refs, used to move commits across
  the air gap without a network remote.
- **Additive-only** — Policy that the internal repo only *adds* files that don't exist
  upstream, and never modifies application files.
- **Internal-only path** — A file/glob owned by the internal side, protected from being
  overwritten by upstream syncs.
- **Application file** — Any tracked path not on the internal-only list; force-matched to
  upstream every sync.
- **Auto-reset** — Post-merge step that forces the application tree on `main` to exactly
  match `pre-main` (modified/deleted/stray files reconciled), preserving manifest paths.
- **Hotfix branch** — Short-lived branch off `main` for an urgent internal app fix;
  deployed directly, never merged; the fix is re-authored upstream.
