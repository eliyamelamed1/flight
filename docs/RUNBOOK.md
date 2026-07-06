# Runbook — Air-Gapped Git Sync (Dictionary Transform + Promotion Pipeline)

Operational guide. Rationale in [docs/adr/DECISIONS.md](adr/DECISIONS.md) (current governing
decisions: **ADR-0012** transform, **ADR-0013** sync scope); terms in
[docs/GLOSSARY.md](GLOSSARY.md).

## Model in one line

The sync brings **external `master` → internal `pre-dev`** (with the dictionary transform
applied), forward-advancing one commit per sync. Your normal promotion pipeline carries it up:

```
external master --(bundle + sync + dictionary)--> pre-dev --> develop --> staging --> master
                                                   ^^^^^^^^^^   \______ your promotion process ______/
                                                   sync stops here
```

## Branches (inside the INTERNAL repo)

| Branch | Updated by | Notes |
|--------|-----------|-------|
| `pre-dev` | **the sync** | External master + dictionary transform; forward-advancing; never rewritten |
| `develop`, `staging`, `master` | **your promotion process** | The sync never touches these. Protect with branch protection. |
| `hotfix/*` | you | Short-lived urgent fix, deployed directly, never merged |

External refs are mirrored read-only under `refs/upstream/heads/*` and `refs/upstream/tags/*`.

## Tooling lives OUTSIDE the repo (e.g. `C:\tools\airgap\`)

`dictionary.tsv`, `export-bundle.ps1`, `sync-from-bundle.ps1`, `render-config.ps1`.

---

## One-time bootstrap (internal repo)

```powershell
# External: first full bundle
C:\tools\airgap\export-bundle.ps1 -RepoPath C:\src\app -Out D:\transfer\app.bundle -Refresh

# Carry app.bundle across the gap, then on internal (one command does clone + first sync +
# create develop/staging/master from pre-dev):
C:\tools\airgap\bootstrap-internal.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.tsv
```
Then enable **branch protection** on `develop`/`staging`/`master` on your internal server.

---

## Steady-state sync (each update)

```powershell
# 1. EXTERNAL — fresh full bundle
C:\tools\airgap\export-bundle.ps1 -RepoPath C:\src\app -Out D:\transfer\app.bundle -Refresh

# 2. Carry app.bundle across the air gap

# 3. INTERNAL — advance pre-dev only
C:\tools\airgap\sync-from-bundle.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.tsv

# 4. Promote pre-dev up your pipeline (PR/CI): pre-dev -> develop -> staging -> master
```

The sync (ADR-0013) verifies the bundle → mirrors all refs into `refs/upstream/*` → adds one
forward commit to `pre-dev` (external master + transform). It prints per-key match counts and
warns on any zero-match key (`-Strict` to fail instead).

## Changing internal content

Edit **`dictionary.tsv`** (outside the repo). Takes effect on the next sync.
```
# dictionary.tsv     (keep keys PRECISE - "eliya" also matches "eliyahu")
eliya	dori
```

## Hotfix — preferred: out-of-band (ADR-0004)

Branch off `master`, deploy from that branch, **never merge**, re-author the fix in external,
delete the branch after deploy.

> ⚠️ Re-author upstream, or the fix is lost when the real change flows through the pipeline.

## Hotfix committed directly to internal `master`, then re-sync (ADR-0014)

If the fix went straight onto `master` (diverging it from the pipeline):

```powershell
# 1. Fix + deploy on master (already done — it's live).

# 2. MANDATORY: re-author an EQUIVALENT fix in EXTERNAL master and commit it there.
#    Need NOT be byte-identical - "similar" is fine (reconcile takes external's version
#    wholesale via reset, so a stray space / different wording won't conflict).
#    (Skip this entirely and the next round-trip reverts your fix.)

# 3. Normal sync + promote so the external fix reaches staging:
C:\tools\airgap\sync-from-bundle.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.tsv
#    then promote pre-dev -> develop -> staging (your normal process)

# 4. Reconcile master once staging has the fix. Dry-run first (shows what will drop):
C:\tools\airgap\reconcile-master.ps1 -RepoPath C:\src\app-internal
#    confirm the fix is in staging, then:
C:\tools\airgap\reconcile-master.ps1 -RepoPath C:\src\app-internal -Force
git -C C:\src\app-internal push --force origin master      # if you have a shared remote

# 5. Verify:
git -C C:\src\app-internal diff staging master             # expect empty
```

What happens under the hood: after step 1, `master` has a commit `staging` doesn't → the
`staging → master` promotion would be **non-fast-forward**. Step 4 realigns `master` to
`staging` (external's authoritative fix, now transformed), backing up the old master to a
`backup/master-before-reconcile-*` tag first. The temporary hotfix commit is dropped because
the real fix now lives in the pipeline.

> ⚠️ Don't run reconcile before the fix is actually in `staging` — you'd drop the hotfix
> without its replacement. The dry run shows you exactly what would be dropped.

---

## Conflicts & accidents — what actually happens

- **Accidental commit to `pre-dev`** → content is overwritten by the next sync (external is
  re-applied on top). **No conflict**, self-heals in content.
- **Accidental commit to `develop`/`staging`/`master`** → the sync does NOT fix it. The next
  promotion becomes non-fast-forward and can conflict. **Guard with branch protection** on the
  internal server so direct pushes are rejected. To recover manually: `git reset --hard` the
  branch back to the branch below, or revert the stray commit.
- **Promotions themselves** are conflict-free as long as the promotion branches carry no
  independent commits (all internal delta is the dictionary, applied on `pre-dev`).

## Guardrails / gotchas

- **Never hand-edit `pre-dev`.** App changes go upstream (external); internal content diffs go
  in `dictionary.tsv`.
- **Branch-protect `develop`/`staging`/`master`.** That's the real guard for the pipeline.
- **Keep dictionary + scripts outside the repo.**
- **Watch over-matching** in the dictionary; **investigate zero-match warnings** (upstream
  renamed/removed a token).
- **Bad bundle?** `git bundle verify` fails → discard and re-export; bundles are full snapshots.
