# Runbook — Air-Gapped Git Sync (Dictionary Transform + Promotion Pipeline)

Operational guide. Rationale in [docs/adr/DECISIONS.md](adr/DECISIONS.md) (current governing
decisions: **ADR-0012** transform, **ADR-0013** sync scope); terms in
[docs/GLOSSARY.md](GLOSSARY.md).

## Model in one line

The sync brings **external `main` → internal `pre-dev`** (with the dictionary transform
applied), forward-advancing one commit per sync. Your normal promotion pipeline carries it up:

```
external main --(bundle + sync + dictionary)--> pre-dev --> develop --> staging --> main
                                                   ^^^^^^^^^^   \______ your promotion process ______/
                                                   sync stops here
```

## Branches (inside the INTERNAL repo)

| Branch | Updated by | Notes |
|--------|-----------|-------|
| `pre-dev` | **the sync** | External main + dictionary transform; forward-advancing; never rewritten |
| `develop`, `staging`, `main` | **your promotion process** | The sync never touches these. Protect with branch protection. |
| `hotfix/*` | you | Short-lived urgent fix, deployed directly, never merged |

External refs are mirrored read-only under `refs/upstream/heads/*` and `refs/upstream/tags/*`.

## Tooling lives OUTSIDE the repo — the "kit"

Copy `scripts/` to each side; that folder is the kit. The everyday wrappers (`takeoff.ps1`,
`landing.ps1`) resolve everything by convention **beside the script**:

```
external kit\                                internal kit\
├─ takeoff.ps1 / .cmd    ← you run           ├─ landing.ps1 / .cmd   ← you run
├─ repo\        bare relay clone (auto)      ├─ repo\        internal repo (auto on 1st run)
├─ transfer\    app.bundle written here      ├─ transfer\    drop app.bundle here
└─ engine: export-bundle.ps1                 ├─ dictionary.tsv       ← yours (from sample)
                                             ├─ dictionary.sample.tsv  template
                                             └─ engine: bootstrap/sync/reconcile .ps1
```

Each run asks for its one URL (nothing stored): takeoff asks for the **GitHub repo URL**
it bundles from; landing asks for the **internal server URL** it pushes to.
`repo\` and `transfer\` are runtime assets — gitignored, never committed to this toolkit.

---

## The everyday flow (bootstrap AND steady-state — same two commands)

```powershell
# 1. EXTERNAL kit
.\takeoff.ps1                 # prompts: GitHub repo URL
                              # -> refreshes repo\ -> writes transfer\app.bundle

# 2. Carry transfer\app.bundle across the air gap into the internal kit's transfer\

# 3. INTERNAL kit
.\landing.ps1                 # prompts: internal repo URL
                              # first run : bootstrap (clone + first sync + create branches),
                              #             pushes pre-dev/develop/staging/main
                              # later runs: advance pre-dev only, push pre-dev

# 4. Promote pre-dev up your pipeline (PR/CI): pre-dev -> develop -> staging -> main
```

After the FIRST landing: enable **branch protection** on `develop`/`staging`/`main` on your
internal server.

---

## Engine scripts (what the wrappers call — run directly for explicit paths)

```powershell
# External: first/every full bundle
C:\tools\airgap\export-bundle.ps1 -RepoPath C:\src\app -Out D:\transfer\app.bundle -Refresh

# Internal one-time (clone + first sync + create develop/staging/main from pre-dev):
C:\tools\airgap\bootstrap-internal.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.tsv

# Internal each update — advance pre-dev only
C:\tools\airgap\sync-from-bundle.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.tsv
```

The sync (ADR-0013) verifies the bundle → mirrors all refs into `refs/upstream/*` → adds one
forward commit to `pre-dev` (external main + transform). It prints per-key match counts and
warns on any zero-match key (`-Strict` to fail instead).

## Changing internal content — the dictionary (ADR-0017)

Your real pairs live in the internal kit's **`dictionary.tsv`** — created ONCE by copying
`dictionary.sample.tsv` (only the sample is committed to the toolkit, so kit updates can
never clobber your values). Edit it; takes effect on the next landing.
```
# dictionary.tsv     (keep keys PRECISE - "eliya" also matches "eliyahu")
eliya	dori
```

**Backup & restore:** every landing versions `dictionary.tsv` onto the internal server's
orphan **`airgap-config`** branch (only when it changed). A kit that lost the file restores
the last backed-up copy automatically on the next landing; to restore by hand:
```powershell
git -C .\repo fetch origin
git -C .\repo show origin/airgap-config:dictionary.tsv | Set-Content dictionary.tsv -Encoding Ascii
```

## Hotfix — preferred: out-of-band (ADR-0004)

Branch off `main`, deploy from that branch, **never merge**, re-author the fix in external,
delete the branch after deploy.

> ⚠️ Re-author upstream, or the fix is lost when the real change flows through the pipeline.

## Hotfix committed directly to internal `main`, then re-sync (ADR-0014)

If the fix went straight onto `main` (diverging it from the pipeline):

```powershell
# 1. Fix + deploy on main (already done — it's live).

# 2. MANDATORY: re-author an EQUIVALENT fix in EXTERNAL main and commit it there.
#    Need NOT be byte-identical - "similar" is fine (reconcile takes external's version
#    wholesale via reset, so a stray space / different wording won't conflict).
#    (Skip this entirely and the next round-trip reverts your fix.)

# 3. Normal takeoff + landing so the external fix reaches pre-dev:
.\landing.ps1                              # from the internal kit
#    then promote pre-dev -> develop -> staging (your normal process)

# 4. Reconcile main once staging has the fix. The kit's local staging/main are
#    bootstrap-time snapshots - refresh them from the server first (reconcile-main
#    refuses to run against stale copies):
git -C .\repo fetch origin
git -C .\repo branch -f staging origin/staging
git -C .\repo branch -f main    origin/main
.\reconcile-main.ps1                       # dry run - shows what will drop
#    confirm the fix is in staging, then:
.\reconcile-main.ps1 -Force
git -C .\repo push --force origin main

# 5. Verify:
git -C .\repo diff staging main            # expect empty
```

(Engine-style with explicit paths: see the "Engine scripts" section — pass `-RepoPath` to
`reconcile-main.ps1` and run `sync-from-bundle.ps1` directly.)

What happens under the hood: after step 1, `main` has a commit `staging` doesn't → the
`staging → main` promotion would be **non-fast-forward**. Step 4 realigns `main` to
`staging` (external's authoritative fix, now transformed), backing up the old main to a
`backup/main-before-reconcile-*` tag first. The temporary hotfix commit is dropped because
the real fix now lives in the pipeline.

> ⚠️ Don't run reconcile before the fix is actually in `staging` — you'd drop the hotfix
> without its replacement. The dry run shows you exactly what would be dropped.

---

## Conflicts & accidents — what actually happens

- **Accidental commit to `pre-dev`** → content is overwritten by the next sync (external is
  re-applied on top). **No conflict**, self-heals in content.
- **Accidental commit to `develop`/`staging`/`main`** → the sync does NOT fix it. The next
  promotion becomes non-fast-forward and can conflict. **Guard with branch protection** on the
  internal server so direct pushes are rejected. To recover manually: `git reset --hard` the
  branch back to the branch below, or revert the stray commit.
- **Promotions themselves** are conflict-free as long as the promotion branches carry no
  independent commits (all internal delta is the dictionary, applied on `pre-dev`).

## Guardrails / gotchas

- **Never hand-edit `pre-dev`.** App changes go upstream (external); internal content diffs go
  in `dictionary.tsv`.
- **Branch-protect `develop`/`staging`/`main`.** That's the real guard for the pipeline.
- **Keep dictionary + scripts outside the repo.**
- **Watch over-matching** in the dictionary; **investigate zero-match warnings** (upstream
  renamed/removed a token).
- **Bad bundle?** `git bundle verify` fails → discard and re-export; bundles are full snapshots.
- **Stale bundle?** (older than the last sync — e.g. carried over in the wrong order) → the
  sync refuses it with a clear error instead of regressing `pre-dev`; run takeoff for a
  fresh one.
