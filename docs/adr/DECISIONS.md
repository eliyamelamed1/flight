# Architecture Decision Record — Air-Gapped Git Sync Pipeline

Running log of decisions. Newest at the bottom.

---

## ADR-0001 — Internal repo is additive-only; external is source of truth for application code

**Status:** "External = source of truth" RETAINED. "Additive-only" AMENDED by ADR-0012
(internal now applies a deterministic content transform to existing files).

**Context:** Two isolated networks separated by an air gap. External (internet) repo is
the absolute source of truth for application code. Internal (air-gapped) repo adds
internal-only files (e.g. CI/CD under `.github/workflows`). Policy is additive-only, but
humans may *accidentally* edit application files internally.

**Decision:**
- Internal repo is **additive-only by policy**.
- On every sync, application files are force-reset to exactly match upstream — accidental
  internal edits to application files are **discarded automatically**, no manual review.
- Intentional internal-only additions are **preserved**.

**Alternatives considered:**
- `-X theirs` / `git checkout --theirs` merge strategy — **rejected**. Only resolves
  conflicting hunks (both sides edited same lines). An accidental internal edit to a file
  upstream didn't touch produces no conflict and survives silently. Does not enforce
  "external is source of truth for all application files."

**Consequence / open dependency:** Enforcement requires a precise, machine-checkable
boundary between internal-only paths (protect) and application paths (force-match
upstream). See ADR-0002.

---

## ADR-0002 — Internal/application boundary is a committed manifest of globs

**Status:** SUPERSEDED by ADR-0012 (no internal-only files exist; nothing to protect by path).

**Context:** The internal-only set starts as one file (`ADDED.TEXT`) but will grow to
include internal `.github/workflows` and configs. Internal files can live inside
directories shared with upstream (`.github/workflows`), so directory convention alone is
insufficient.

**Decision:** Maintain a committed manifest (working name `.internal-paths`) listing globs
of internal-only paths. Everything not matched is an "application file" and is
force-matched to upstream on every sync. Initial contents: `ADDED.TEXT` (+ the manifest
itself). Recommended future convention: prefix internal workflows (`internal-*.yml`) so
they are unambiguous inside `.github/workflows`.

**Alternatives considered:**
- Directory/naming convention only — breaks for shared dirs like `.github/workflows`.
- Diff-against-upstream heuristic — can't distinguish an accidental edit from an
  intentional internal-only file; fragile.

**Consequence / open dependency:** Need to decide *where the pristine copy of internal
files lives* and *how `main` is reconstructed* each sync. See ADR-0003.

---

## ADR-0003 — Two-branch, merge-based sync model (`pre-main` -> `main`)

**Status:** SUPERSEDED by ADR-0011 (overlay model). Kept for history.

**Context:** User prefers a simple flow over a 3-branch overlay rebuild.

**Decision:** Internal repo uses two branches:
- `pre-main` — mirror of the external `main`, populated by importing the bundle. Never
  hand-edited.
- `main` — production branch; each sync merges `pre-main` into it.

Note: across the air gap there is no live remote — "push to `pre-main`" means "import the
carried bundle into `pre-main`."

**Alternatives considered:**
- 3-branch overlay rebuild (`pre-main` + `internal-overlay` + generated `main`) — stronger
  self-healing (accidents to app *and* internal files auto-heal) but rejected as too
  complex for current needs.

**Consequence / open dependency:** A plain merge does NOT enforce ADR-0001 — non-conflicting
accidental edits to application files survive silently. This gap must be closed explicitly.
See ADR-0005.

---

## ADR-0004 — Internal hotfixes are out-of-band on short-lived branches, never merged

**Status:** Accepted

**Context:** Internal side occasionally needs an urgent fix to application code that can't
wait for the external -> bundle -> internal round-trip.

**Decision:**
- Hotfixes live on a **short-lived branch off `main`**, deployed **directly** from that
  branch, and **never merged** into `main` or `pre-main`.
- The same fix is **manually re-authored in the external repo** (source of truth) so it
  returns through the normal sync later.
- The hotfix branch is discarded after deploy.

**Why this keeps things simple:** `main` remains strictly additive-only (ADR-0001 holds);
no patch-queue/rebase-onto-upstream machinery is needed; nothing to reconcile when upstream
catches up.

**Guardrails (process, not code):**
- Never merge a hotfix branch into the main flow.
- Always port the fix to external, or the next sync will silently revert the deployed fix
  (auto-reset resets app files to upstream — see ADR-0005).

**Alternatives considered:** Managed internal patch set re-applied on top of upstream each
sync — rejected as unnecessary complexity given the out-of-band deploy discipline.

---

## ADR-0005 — Post-merge auto-reset makes external the source of truth for app files

**Status:** Principle RETAINED (external is truth, accidents wiped); mechanism SUPERSEDED by
ADR-0011. Kept for history.

**Context:** A plain merge (ADR-0003) doesn't erase non-conflicting accidental edits. With
hotfixes out-of-band (ADR-0004), any app-file change on `main` is an accident.

**Decision:** After merging `pre-main` into `main`, run an auto-reset step that forces the
application tree to exactly match `pre-main`, then re-applies internal-only files.

**Scope — "exactly match" means all three of:**
1. Accidentally **modified** app files -> reset to upstream.
2. App files **deleted upstream** -> deleted internally too.
3. Stray app files **accidentally added** internally (not in `pre-main`, not in manifest)
   -> removed.
   (i.e. app tree becomes byte-identical to `pre-main`; only manifest paths are exempt.)

**Known limitation (accepted):** In the 2-branch model the only copy of internal-only files
lives on `main`, so if an *internal-only* file is accidentally edited, auto-reset preserves
the edited version (it has no pristine source to heal from). App files self-heal; internal
files rely on discipline/review. The 3-branch overlay model (rejected in ADR-0003) would
have healed both.

**Alternatives considered:** Warn-via-CI (no auto-fix) and do-nothing — rejected; user wants
the guarantee with zero manual attention.

---

## ADR-0006 — Sync all refs, but into an isolated `refs/upstream/*` namespace

**Status:** Accepted

**Context:** User wants to mirror everything (all branches + tags) but `main` passing
correctly is the non-negotiable core; other refs are best-effort.

**Decision:**
- Bundle all external refs (branches + tags).
- Import them internally into a dedicated namespace: `refs/upstream/heads/*` and
  `refs/upstream/tags/*` — NOT onto local branches/tags.
- `pre-main` == `refs/upstream/heads/main`; only `main` gets the merge + auto-reset
  treatment (ADR-0003/0005). Other upstream refs are mirrored for reference/consumption
  but are not overlaid with internal files.

**Why:** Namespacing removes tag collisions (upstream tags land under their own path),
makes upstream-deleted branches detectable via `--prune`, and guarantees the all-refs
mirror can never endanger `main` or internal branches.

**Consequence / open dependency:** Bundle size + full-vs-incremental strategy still open
(user raised "massive bundle" concern). See ADR-0007.

---

## ADR-0007 — Always ship a full bundle of all refs (no incremental base tracking)

**Status:** Accepted (with size escape hatch)

**Context:** User prefers to "always ship the last version of main" and not track an
incremental base across the gap.

**Decision:** Every sync produces a full `git bundle create <file> --all` of the external
mirror. No last-exported marker, no ack, no incremental ranges. Internal runs
`git bundle verify` then fetches into `refs/upstream/*` (ADR-0006). `pre-main` is **reset**
(not fast-forward-only) to `refs/upstream/heads/main` so it mirrors even if external history
was rebased/force-updated.

**Why:** Fully self-contained and order-independent — immune to lost/duplicated/out-of-order
bundles; zero cross-gap state. Simplest possible process.

**Cost / escape hatch:** Re-ships full history every sync. Acceptable for modest repos. If
history grows to gigabytes and transfers become painful, switch to incremental
(`<last>..--all`) with a confirmed checkpoint — revisit ADR-0007 then; do not retrofit
prematurely.

**Note:** A `git bundle` of a branch always carries its full reachable history, not just the
tip snapshot.

---

## ADR-0008 — Config injection: template in source, values in a manifest-protected file, rendered at build

**Status:** Accepted

**Context:** App reads an env-specific config file at runtime (e.g. `config.json`). Values
are non-sensitive only (URLs, flags, hostnames, timeouts) — no secrets. Developers must
never edit app source inside the air gap.

**Decision:**
- **Source** ships only a template/defaults (e.g. `config.template.json`) — an application
  file owned by external.
- **Internal values** live in a committed **internal-only** file (e.g.
  `deploy/internal.values.env`), listed in the manifest (ADR-0002) so it survives every
  sync and is never treated as an accidental app edit.
- **Build stage** renders the real `config.json` from template + values (e.g. `envsubst`
  or a small render step). The rendered file is a **build artifact, gitignored, never
  committed** — so auto-reset (ADR-0005) never touches it and source stays pristine.
- Developers change environment behavior by editing the values file, never the source.

**Alternatives considered:**
- Env vars — viable but app consumes a file; file-render fits better.
- Secret store / vault — unnecessary now (no secrets); revisit if secrets appear (then
  split: non-secret in the values file, secrets in CI store).

---

## ADR-0009 — Both sides run Windows; automation in PowerShell

**Status:** Accepted

**Decision:** Export (external) and sync (internal) both run on Windows. All automation is
PowerShell. `git bundle` behaves identically across platforms, so the bundle file itself is
portable if a side later moves to Linux.

---

## ADR-0010 — Edge-case handling summary + canonical sync sequence

**Status:** Edge-case handling RETAINED; the sync sequence is SUPERSEDED by ADR-0011.

**Edge cases (all resolved by earlier decisions):**
- **Tag collisions** — external tags land under `refs/upstream/tags/*`; never clobber
  internal tags (ADR-0006).
- **Deleted upstream branches** — `git fetch --prune` on `refs/upstream/heads/*` removes
  them from the mirror namespace without touching internal branches (ADR-0006).
- **Force-pushed / rebased upstream history** — `pre-main` is force-moved (reset) to
  `refs/upstream/heads/main`, and `main`'s content is enforced by auto-reset, so rewritten
  upstream history is absorbed cleanly (ADR-0007).
- **Massive bundles** — accepted for now; incremental escape hatch documented (ADR-0007).
- **Lost/duplicated/out-of-order bundles** — harmless; every bundle is a full self-contained
  snapshot (ADR-0007).

**Canonical internal sync sequence (per ADR-0003/0005/0006):**
1. `git bundle verify <bundle>`
2. `git fetch --prune <bundle> refs/heads/*:refs/upstream/heads/* +refs/tags/*:refs/upstream/tags/*`
3. `git branch -f pre-main refs/upstream/heads/main`
4. capture pristine internal snapshot = current `main` SHA
5. `git switch main`
6. `git merge -s ours --no-commit --no-ff pre-main` (lineage only; tolerate "already up to date")
7. `git read-tree -u --reset pre-main` (app tree becomes byte-identical to upstream)
8. restore each manifest path from the pristine snapshot (internal-only files preserved)
9. `git add -A` then commit (finalize merge, or plain commit if no merge was needed)

**Why `-s ours` + `read-tree` instead of a normal merge:** a normal merge can halt on
conflicts and leaves non-conflicting accidents in place. This sequence never conflicts and
makes the app tree deterministically equal to upstream every run.

---

## ADR-0011 — Overlay model: inject internal files onto `pre-dev`, reset `master` to it

**Status:** `pre-dev` branch RETAINED. The `master` = reset-to-pre-dev part is SUPERSEDED by
ADR-0013 (real promotion pipeline; sync stops at `pre-dev`). File-injection SUPERSEDED by
ADR-0012. Still supersedes ADR-0003/0005/0010 as noted below.

**Context:** User's actual flow injects internal files onto the incoming branch (`pre-dev`)
rather than keeping internal files on the production branch. This is the 3-branch overlay
model originally set aside in ADR-0003, and it is strictly better: it self-heals BOTH
application files and internal files from accidents (removing the ADR-0005 limitation).

**Branches (internal repo):**
- `internal-overlay` — the single pristine source of internal-only files (CI, config values,
  ADDED.TEXT, ...). Contains NO application code. Hand-edited when internal files change.
- `pre-dev` — rebuilt every sync = external `master` (from bundle) with `internal-overlay`
  files injected on top. (Replaces `pre-main`.)
- `master` — production/deploy; **reset** to `pre-dev` every sync. Holds no independent
  content of its own.

**Sync sequence:**
1. `git bundle verify <bundle>`
2. `git fetch --prune <bundle> refs/heads/*:refs/upstream/heads/* +refs/tags/*:refs/upstream/tags/*`
3. `git switch -C pre-dev refs/upstream/heads/master`  (pre-dev := pure external master)
4. collision guard — warn/fail if any `internal-overlay` path also exists in upstream master
   (would shadow an app file)
5. `git checkout internal-overlay -- .`  (inject internal files onto pre-dev)
6. `git commit -m "inject internal overlay"`  (skip if nothing to inject)
7. `git switch master; git reset --hard pre-dev`  (master := pre-dev; accidents wiped)

**Why reset, not merge, at step 7:** `master` has no independent content in this model, so a
content merge is meaningless and would still let non-conflicting accidental edits survive.
`reset --hard pre-dev` makes `master` byte-identical to the freshly built `pre-dev` — app
files AND internal files both come from pristine sources, so every accident self-heals.

**Trade-off:** `master`'s commit identity changes each sync (it is reset, not fast-forwarded).
Acceptable for an internal mirror/deploy branch. If continuous `master` history is ever
required, replace step 7 with `merge -s ours --no-commit pre-dev` + `read-tree -u --reset
pre-dev` + commit (keeps ancestry, same safety).

**Boundary definition:** In this model the internal/application boundary is simply "whatever
lives on `internal-overlay`." A separate `.internal-paths` manifest (ADR-0002) is no longer
required for enforcement; keep it only as optional documentation / the collision-guard list.

**Config injection (ADR-0008) unchanged**, except `deploy/internal.values.env` now lives on
`internal-overlay`.

---

## ADR-0012 — Internal delta is a deterministic dictionary transform (edits to existing files)

**Status:** Accepted. Amends ADR-0001 (not additive-only). Supersedes ADR-0002 (manifest) and
the file-injection part of ADR-0011. Retains: `pre-dev` build → `master` reset (ADR-0011),
`refs/upstream/*` mirror (ADR-0006), full bundle (ADR-0007), hotfix discipline (ADR-0004).

**Context:** All internal differences are content edits to files that already exist upstream
(e.g. external `file.txt` = "eliya" must read "dori" internally). There are NO net-new
internal files, so a find/replace dictionary fully expresses the delta. The overlay/injection
mechanism is unnecessary.

**Decision:**
- Keep a dictionary (`from` -> `to` pairs) stored **outside the synced branches** (on the
  internal build machine, alongside the scripts) so `reset --hard` cannot wipe it.
- Every sync: bring external master's content into `pre-dev`, then **apply the dictionary
  over all TEXT files**, and commit. The transform runs **every sync** — never a one-time
  manual edit. (Note: the `master := reset to pre-dev` step from ADR-0011 is removed by
  ADR-0013 — the sync now stops at `pre-dev` and promotion carries it up.)
- Transform **text files only**; skip binaries (NUL-byte detection); preserve UTF-8 (no BOM).
- **Safety:** report per-key replacement counts; warn (or fail with `-Strict`) if a key
  matches **zero** times — that signals upstream renamed/removed the token and internal would
  silently receive the un-transformed value.

**Why:** expresses "modify existing app files," which the overlay could not. Deterministic and
re-applied each sync ⇒ no merge conflicts and self-healing of accidental edits.

**Risks / guardrails:**
- **Over-matching** — literal `eliya` also hits `eliyahu`, URLs, identifiers. Use precise keys
  (and/or word boundaries) in the dictionary.
- **Silent no-op** on upstream rename — covered by the zero-match warning.
- **Dictionary + scripts must stay outside synced branches** — else `reset --hard` wipes them.

**Alternatives considered:** overlay injection (ADR-0011) — can't edit content of existing
files, only add new ones; wrong tool for this delta.

---

## ADR-0013 — Sync scope: forward-advance `pre-dev` only; promotion pipeline is separate

**Status:** Accepted. Supersedes the `master := reset to pre-dev` step of ADR-0011.

**Context:** Internal uses a real promotion pipeline: `pre-dev -> develop -> staging ->
master`. `master` is reached by promoting code up through gates, NOT by rebuilding it. The
earlier reset-to-`master` model is incompatible: it would rewrite `pre-dev` and fight the
promotion merges.

**Decision:**
- The sync touches **`pre-dev` only**. It never touches `develop`/`staging`/`master`.
- `pre-dev` is **forward-advancing**: each sync adds exactly one commit whose content =
  external master + dictionary transform (via `read-tree -u --reset <upstream master>` then
  transform then commit, keeping `pre-dev` HEAD so the commit's parent is the previous
  `pre-dev` tip). History is never rewritten, so `pre-dev -> develop` merges stay clean.
- Promotion `pre-dev -> develop -> staging -> master` is the team's existing process
  (PRs / CI gates), out of scope for this script.

**Conflict behavior (corrects the earlier "no conflicts ever" claim, which assumed a
reset-rebuilt `master`):**
- If the promotion branches carry no independent commits, promotions are fast-forwards →
  no conflicts.
- An accidental commit to **`pre-dev`** is content-overwritten on the next sync (external is
  re-applied on top) → no conflict, self-heals in content.
- An accidental commit to **`develop`/`staging`/`master`** is NOT healed by the sync. It makes
  the next promotion non-fast-forward and can conflict. **Guard these with branch protection**
  on the internal server (reject direct pushes), not with self-healing.

**Why forward-advance, not reset:** rewriting `pre-dev` each sync (the old `switch -C` /
`reset` approach) breaks merges into `develop` (non-fast-forward, duplicate commits, recurring
conflicts). A forward-only `pre-dev` promotes cleanly.

**Alternatives considered:** reset model (ADR-0011) — only valid without a promotion pipeline;
rejected because the team promotes through develop/staging/master.

---

## ADR-0014 — Emergency hotfix committed directly to internal `master`: procedure + reconcile

**Status:** Accepted. Complements ADR-0004 (which keeps hotfixes off the main flow). This
covers the case where an urgent fix IS committed straight to internal `master`, diverging it
from the pipeline, and external is then re-synced.

**Procedure:**
1. **Apply & deploy** the fix on `master` (directly, or a `hotfix/*` branch merged to
   `master`). It is now live.
2. **MANDATORY — re-author an EQUIVALENT fix in EXTERNAL master** (source of truth). It need
   NOT be byte-identical to the internal hotfix — "similar" is fine (differ by a space,
   comment, wording). If skipped entirely, the next round-trip reverts your deployed fix.
3. **Next sync** advances `pre-dev` with external (now containing the fix) + transform.
   Promote `pre-dev → develop → staging` as normal. `staging` now holds external's
   authoritative, transformed fix.
4. **Reconcile `master`** — once you've confirmed `staging` contains the fix, realign `master`
   to `staging` with `reconcile-master.ps1` (tags a backup, then `git reset --hard staging`),
   discarding the temporary hotfix commit. Force-push `master`.
5. **Verify:** `git diff staging master` is empty; the fix is present and behaves.

**Why reset, not merge:** the temporary hotfix was only a bridge until external caught up.
External is the source of truth, so once its version reaches `staging`, `master` should equal
the promoted pipeline content — no lingering divergence, no recurring non-fast-forward merges.
Crucially, `reset --hard` takes `staging` wholesale (no 3-way merge), so the external fix does
**not** need to be byte-identical to the internal hotfix — a near-identical but different
version (a stray space, different wording) reconciles cleanly with NO conflict, whereas a
`merge`-based reconcile would conflict on exactly those differences. `master` ends up with
external's exact text (source of truth); the internal quick-fix bytes are discarded.

**Guardrails:**
- Step 2 is non-negotiable — skipping it loses the fix on the next round-trip.
- Don't reconcile before the fix is actually in `staging`, or you drop the hotfix without its
  replacement. `reconcile-master.ps1` prints the `master↔staging` diff and requires `-Force`.
- Reconcile rewrites `master` → force-push required; do it as a controlled action, then
  everyone re-syncs their clones.
- Preferred to avoid all this: ADR-0004 (hotfix on a throwaway branch, never on `master`).

---

## ADR-0015 — Internal deploy branch renamed `master` -> `main`; external default is also `main`

**Status:** Accepted. Renames the deploy branch of ADR-0011/0013 (`master`) to `main`. Retains the
promotion model (ADR-0013): the sync forward-advances `pre-dev` only.

**Context:** Both the external source repo and the internal repo use `main` as their default/deploy
branch (GitHub's default). The scripts and docs previously named the internal deploy branch
`master`, which no longer matched reality and left a stray `master` branch on every bootstrap.

**Decision:**
- The internal promotion pipeline is now `pre-dev -> develop -> staging -> main`. `main` is the
  deploy branch (formerly `master`); `master` is removed.
- The sync still touches **`pre-dev` only** (ADR-0013 unchanged); promotion to `develop`/`staging`/
  `main` is the team's manual PR/CI process.
- `sync-from-bundle.ps1` `-UpstreamMainRef` now defaults to `refs/upstream/heads/main` (the external
  default is `main`, not `master`).
- `bootstrap-internal.ps1` creates `develop`/`staging` and forces `main` to the transformed
  `pre-dev` (the raw `main` left by `git clone <bundle>` is overwritten with transformed content).
- `reconcile-master.ps1` -> `reconcile-main.ps1`; it reconciles `main` (not `master`), backing up to
  a `backup/main-before-reconcile-*` tag.

**Operating rule:** on the internal remote, only `pre-dev` is pushed by the sync; `develop`/
`staging`/`main` move only via promotion and are protected by branch protection.

**Alternatives considered:** keep `master` as the internal deploy branch while the external is
`main` — rejected; the two-name split was a persistent source of confusion and left stray branches.

---

## ADR-0016 — Two zero-setup wrapper commands (`takeoff` / `landing`) with a folder convention and per-run URL prompt

**Status:** Accepted. Adds an operator layer on top of the engine scripts; sync semantics
(ADR-0012/0013) unchanged.

**Context:** Operating the toolkit meant retyping three long paths per command and choosing
the right script (bootstrap vs sync) by hand. The operator wants one command per side
("takeoff" = external export, "landing" = internal import), run independently on each side,
with each run asking for the one thing that varies: the repo URL.

**Decision:**
- **Kit convention:** the folder containing the wrapper is the kit. `repo\` (the git repo)
  and `transfer\app.bundle` (the asset) always live beside the script; the internal kit also
  holds `dictionary.tsv`. `repo/`, `transfer/`, `*.bundle` are gitignored runtime assets.
- **`takeoff.ps1`** (external): prompts every run for the GitHub repo URL (no stored default),
  points `origin` at it, refreshes, writes `transfer\app.bundle` via `export-bundle.ps1`.
  On first run it creates `repo\` as a **bare relay clone** with a `+refs/heads/*:refs/heads/*`
  fetch refspec, so branch tips mirror the server exactly on every refresh (a plain working
  clone's local tips can lag `origin` after fetch — the relay closes that gap).
- **`landing.ps1`** (internal): prompts every run for the internal server URL, **auto-detects**
  first run (no `repo\.git` → `bootstrap-internal.ps1`) vs steady state (→
  `sync-from-bundle.ps1`), then sets `origin` to the URL and pushes: all four pipeline
  branches on first run (seeding the server), `pre-dev` only afterwards (ADR-0013 — promotion
  moves the rest). A failed push warns loudly but does not undo the successful local sync.
- `takeoff.cmd` / `landing.cmd` are double-click launchers (`-ExecutionPolicy Bypass`).
- `export-bundle.ps1` now accepts bare repos; `reconcile-main.ps1` `-RepoPath` defaults to
  the kit's `repo\`.

**Alternatives considered:**
- Config file with saved paths/URLs — rejected: the operator explicitly prefers being asked
  each run over hidden stored state.
- Wrapper args with defaults — rejected: still paths to remember; the folder convention
  removes them entirely.
- Mirror clone (`--mirror`) for the relay — rejected: also drags `refs/pull/*` etc. from
  GitHub into every bundle; a bare clone with heads+tags refspecs bundles just branches+tags.

**Hardening (from the adversarial review of this change):**
- Landing's first-run detection is failure-safe: a bootstrap that throws deletes its partial
  clone (so the next run bootstraps again), a killed-mid-run leftover is caught by a
  half-bootstrap guard (no `develop` locally or on origin → fail loud), and a fresh kit
  pointed at an already-seeded server is told to reconnect via clone instead of bootstrapping
  unrelated history.
- Takeoff (re)writes the relay's heads+tags refspecs **every run**, so a first run that died
  between clone and config heals itself, and re-pointing at a different URL prunes the old
  remote's branches *and tags* from future bundles.
- `sync-from-bundle.ps1` now force-updates the `refs/upstream/*` mirror (`+refs/heads/*`,
  absorbing rebased external history per ADR-0007) and **refuses stale bundles** (bundle main
  strictly older than the last synced main) — keeping "out-of-order bundle is harmless" true
  as a clean refusal rather than a silent content regression on `pre-dev`.
- `reconcile-main.ps1` refuses to run against local `main`/`staging` that don't match
  `origin/*` (the kit's local copies are bootstrap-time snapshots; the ADR-0014 dry-run diff
  must reflect the server's promoted pipeline).
- Push failures in landing distinguish server rejection (diverged history — never blind
  force-push) from unreachability; the prompt loops fail cleanly on non-interactive hosts.

---

## ADR-0017 — The dictionary lives in the internal kit; only a sample is committed; landing auto-versions it to `airgap-config`

**Status:** Accepted. Refines where the ADR-0012 dictionary is stored and how it survives.

**Context:** The dictionary is the *entire* internal delta (ADR-0012), yet it was a single
unversioned file committed to the toolkit with demo content. Two failure modes: refreshing a
kit from the toolkit overwrites the operator's real pairs with the demo pair, and losing the
kit folder loses the internal configuration entirely. It also cannot live inside the synced
repo (every sync force-resets content to external main), and committing real values to the
toolkit would carry internal naming to the external network — the wrong side of the gap.

**Decision:**
- The toolkit commits only **`dictionary.sample.tsv`**; `dictionary.tsv` is gitignored.
  Operators create the real file once (`copy dictionary.sample.tsv dictionary.tsv`) in the
  internal kit and edit it there. Landing refuses to run without it — the sample is never
  read directly, so demo pairs can never silently apply to a real repo.
- Every landing **backs `dictionary.tsv` up** to an orphan **`airgap-config`** branch on
  the internal server (git plumbing: `hash-object`/`mktree`/`commit-tree`; commits only on
  content change; fast-forwards from `origin/airgap-config` first so multiple kits converge;
  pushed alongside the sync branches). Backup failures warn loudly but never undo a
  successful sync.
- A connected kit whose `dictionary.tsv` is **missing** restores the last backed-up copy
  from `origin/airgap-config` automatically before syncing.
- A plain-language `README.md` ships inside the kit covering setup, the dictionary, and
  recovery.

**Alternatives considered:**
- Real dictionary committed in the toolkit repo — rejected: leaks internal-specific naming
  to the external side and reintroduces update-clobbering.
- Dedicated config repo on the internal server — rejected: a second repo, a second URL and
  extra ceremony for a one-file concern.
- Storing it inside the synced repo — impossible: wiped by every sync (`read-tree --reset`).
