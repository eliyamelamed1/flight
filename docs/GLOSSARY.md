# Glossary — Air-Gapped Git Sync Pipeline

- **Air gap** — Physical/network isolation; the two repos can never talk directly. All
  transfer happens via files (git bundles) carried across.
- **Kit** — The folder a wrapper script lives in (a copy of `scripts/`). Everything the
  wrappers need sits beside them by convention: `repo\` (the git repo), `transfer\`
  (the bundle), and on the internal side `dictionary.tsv` — created once from
  `dictionary.sample.tsv` (ADR-0016/0017).
- **`airgap-config`** — Orphan branch on the internal server where landing automatically
  versions `dictionary.tsv` each run; the restore source when a kit loses its dictionary
  (ADR-0017).
- **Takeoff** — The external-side everyday command (`takeoff.ps1`): prompts for the GitHub
  repo URL, refreshes the kit's `repo\` (a bare relay clone), and writes
  `transfer\app.bundle` for carrying across the gap.
- **Landing** — The internal-side everyday command (`landing.ps1`): prompts for the internal
  server URL, consumes `transfer\app.bundle` (first run bootstraps, later runs advance
  `pre-dev`), and pushes the result to that URL.
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
