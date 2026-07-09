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

Copy `scripts/` to each side; that folder is the kit. The launchers (`takeoff.cmd`,
`landing.cmd`) resolve everything by convention in the **kit root** (ADR-0019):

```
external kit\                                internal kit\
├─ takeoff.cmd           ← you run           ├─ landing.cmd          ← you run
├─ repos.json   ← yours (from sample)        ├─ repos.json   ← yours (from sample)
├─ repos.sample.json     template            ├─ repos.sample.json    template
├─ repo\        bare relay clone (auto)      ├─ repo\        internal repo (auto on 1st run)
├─ toUpload\<repo>-<ts>\app.bundle           ├─ toUpload\<name>\     drop the takeoff folder here
│               one folder per takeoff run   ├─ doneUpload\<name>\   moved here after a good push
└─ engine\      takeoff.ps1,                 ├─ dictionary.json      ← yours (from sample)
                export-bundle.ps1            ├─ dictionary.sample.json template
                                             └─ engine\      landing.ps1 + bootstrap/sync/
                                                             reconcile/render .ps1
```

Only the `.cmd` launchers and the sample/config files sit at the top of the kit — the
`engine\` subfolder holds ALL the PowerShell (including `takeoff.ps1`/`landing.ps1`),
which you never run directly in the everyday flow.

Each command resolves its one URL as: `-RepoUrl` parameter → `repos.json` (takeoff reads
`"externalRepoUrl"` = the GitHub repo it bundles from; landing reads `"internalRepoUrl"` =
the server it pushes to) → interactive prompt. Copy `repos.sample.json` → `repos.json` and
fill only your side's key; `repos.json` is gitignored, like the dictionary.

**Bundle handoff (ADR-0020):** each takeoff writes into a fresh
`toUpload\<repo>-<yyyy-MM-dd_HH-mm-ss>\` folder; you carry that folder into the internal
kit's `toUpload\`. Landing takes exactly ONE pending folder per run (it refuses if several
are pending — land them one at a time, oldest first) and moves it to `doneUpload\` only
after the push to the internal server succeeded, so `toUpload\` = still to land,
`doneUpload\` = landed history.
`repo\`, `toUpload\` and `doneUpload\` are runtime assets — gitignored, never committed to
this toolkit.

---

## The everyday flow (bootstrap AND steady-state — same two commands)

Run from the kit root:

```powershell
# 1. EXTERNAL kit
.\takeoff.cmd                 # URL from repos.json "externalRepoUrl" (prompts if unset)
                              # -> refreshes repo\ -> writes toUpload\<repo>-<timestamp>\app.bundle

# 2. Carry that toUpload\<name> folder across the air gap into the internal kit's toUpload\

# 3. INTERNAL kit
.\landing.cmd                 # URL from repos.json "internalRepoUrl" (prompts if unset)
                              # first run : bootstrap (clone + first sync + create branches),
                              #             pushes pre-dev/develop/staging/main
                              # later runs: advance pre-dev only, push pre-dev
                              # then moves toUpload\<name> -> doneUpload\<name>

# 4. Promote pre-dev up your pipeline (PR/CI): pre-dev -> develop -> staging -> main
```

After the FIRST landing: enable **branch protection** on `develop`/`staging`/`main` on your
internal server.

---

## Engine scripts (what the wrappers call — run directly for explicit paths)

```powershell
# External: first/every full bundle
C:\tools\airgap\engine\export-bundle.ps1 -RepoPath C:\src\app -Out D:\transfer\app.bundle -Refresh

# Internal one-time (clone + first sync + create develop/staging/main from pre-dev):
C:\tools\airgap\engine\bootstrap-internal.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.json

# Internal each update — advance pre-dev only
C:\tools\airgap\engine\sync-from-bundle.ps1 -RepoPath C:\src\app-internal `
    -Bundle D:\transfer\app.bundle -Dictionary C:\tools\airgap\dictionary.json
```

The sync (ADR-0013) verifies the bundle → mirrors all refs into `refs/upstream/*` → adds one
forward commit to `pre-dev` (external main + transform). It prints per-key match counts and
warns on any zero-match key (`-Strict` to fail instead).

## Changing internal content — the dictionary (ADR-0017)

Your real pairs live in the internal kit's **`dictionary.json`** — created ONCE by copying
`dictionary.sample.json` (only the sample is committed to the toolkit, so kit updates can
never clobber your values). It's a JSON object of `"find": "replace"` pairs; edit it and it
takes effect on the next landing. Keep keys PRECISE — `"eliya"` also matches inside `"eliyahu"`.
```json
{
  "eliya": "dori"
}
```

**Backup & restore:** every landing versions `dictionary.json` onto the internal server's
orphan **`airgap-config`** branch (only when it changed). A kit that lost the file restores
the last backed-up copy automatically on the next landing; to restore by hand:
```powershell
git -C .\repo fetch origin
git -C .\repo show origin/airgap-config:dictionary.json | Set-Content dictionary.json -Encoding Ascii
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
.\landing.cmd                              # from the internal kit root
#    then promote pre-dev -> develop -> staging (your normal process)

# 4. Reconcile main once staging has the fix. The kit's local staging/main are
#    bootstrap-time snapshots - refresh them from the server first (reconcile-main
#    refuses to run against stale copies):
git -C .\repo fetch origin
git -C .\repo branch -f staging origin/staging
git -C .\repo branch -f main    origin/main
.\engine\reconcile-main.ps1                # dry run - shows what will drop
#    confirm the fix is in staging, then:
.\engine\reconcile-main.ps1 -Force
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
  in `dictionary.json`.
- **Branch-protect `develop`/`staging`/`main`.** That's the real guard for the pipeline.
- **Keep dictionary + scripts outside the repo.**
- **Watch over-matching** in the dictionary; **investigate zero-match warnings** (upstream
  renamed/removed a token).
- **Bad bundle?** `git bundle verify` fails → discard and re-export; bundles are full snapshots.
- **Stale bundle?** (older than the last sync — e.g. carried over in the wrong order) → the
  sync refuses it with a clear error instead of regressing `pre-dev`; run takeoff for a
  fresh one.
