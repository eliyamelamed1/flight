# Glossary — Air-Gapped Git Sync Pipeline

- **Air gap** — Physical/network isolation; the two repos can never talk directly. All
  transfer happens via files (git bundles) carried across.
- **External repo** — The internet-side repository. Absolute source of truth for
  application code.
- **Internal repo** — The air-gapped repository. Holds application code plus internal-only
  additions (CI/CD, configs).
- **Dictionary transform** — A `from`->`to` find/replace applied to text files on every sync
  to produce internal-specific content (e.g. `eliya`->`dori`). The current internal delta
  mechanism (ADR-0012); replaces overlay injection. Stored outside the synced branches.
- **`internal-overlay`** — (Superseded, ADR-0012) Branch that used to hold internal-only files
  in the overlay model.
- **`pre-dev`** — Internal branch rebuilt every sync = external `master` with the dictionary
  transform applied. (ADR-0011 structure; ADR-0012 content.)
- **`master`** — Internal production/deploy branch; reset to `pre-dev` every sync.
- **`upstream-base` / `pre-main` / `main`** — Older branch names from the superseded
  2-branch model (ADR-0003). See `pre-dev`/`master` above.
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
