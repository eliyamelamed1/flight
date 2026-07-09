# Air-gap sync kit

This folder is a **kit**: copy it onto a machine and run **one** command from it.

- On the **internet** machine → run **`takeoff`**.
- On the **air-gapped** machine → run **`landing`**.

Everything else the commands need lives right here beside them:

```
kit\
├─ 1 - takeoff.cmd               run this on the EXTERNAL (internet) machine
├─ 2 - landing.cmd               run this on the INTERNAL (air-gapped) machine
├─ repos.json                    your repo URLs (create once — see below)
├─ dictionary.json               your find/replace pairs (internal only — see below)
├─ repo\external\                takeoff's relay clone   (auto-created — don't make these yourself)
├─ repo\internal\                landing's internal repo (each command has its own, so one
│                                kit can even run BOTH commands, e.g. when testing locally)
├─ toUpload\<name>\app.bundle    one folder per takeoff run — the thing you carry across
├─ doneUpload\<name>\            where landing moves a folder once it landed successfully
└─ engine\                       all the PowerShell (including takeoff.ps1/landing.ps1) — you never run these directly
```

> **Tip:** double-click the **`.cmd`** launcher (`1 - takeoff.cmd` / `2 - landing.cmd`;
> the numbers are the run order). On a locked-down host that blocks PowerShell scripts,
> the `.cmd` is the way in — it already runs with `-ExecutionPolicy Bypass`, so you don't
> have to change any policy yourself.
> (`git` must be installed and on `PATH`; the command tells you if it isn't.)

## On the EXTERNAL (internet) machine

1. Double-click `1 - takeoff.cmd` (or run `.\engine\takeoff.ps1` from a PowerShell window).
2. It reads the **GitHub repo URL** from `repos.json` (see below) — or asks for it if
   you haven't set that up.
3. It writes the bundle into a new folder named after the repo and the moment it ran:
   `toUpload\<repo>-<date>_<time>\app.bundle` (e.g. `toUpload\app-2026-07-09_14-30-05\`).
   Copy that **whole folder** to the internal machine, into the internal kit's `toUpload\`.

## On the INTERNAL (air-gapped) machine

1. Double-click `2 - landing.cmd` (or run `.\engine\landing.ps1` from a PowerShell window).
2. **First time only:** if you haven't set up your dictionary yet, landing writes a starter
   `dictionary.json`, then stops and asks you to fill in your real pairs (see below).
   Edit it, then run landing again.
3. It reads your **internal git server URL** from `repos.json` — or asks for it if you
   haven't set that up.
4. Done. The first real run sets everything up and pushes `pre-dev/develop/staging/main`;
   every later run just brings in the latest code and pushes `pre-dev`. After a
   successful push, the bundle folder moves from `toUpload\` to `doneUpload\` — so
   `toUpload\` is always "still to land" and `doneUpload\` is your history of what landed.
   (Landing takes exactly one pending folder per run; if several piled up it stops and
   asks you to keep just the one to land.)

Then promote `pre-dev → develop → staging → main` with your normal PR/CI process.

## The repos file (skip the URL prompt)

Create `repos.json` next to the launchers, with **only your side's key**:

```json
{
  "externalRepoUrl": "https://github.com/org/app.git"
}
```

- Takeoff uses `"externalRepoUrl"`, landing uses `"internalRepoUrl"`. An empty or missing
  key just means that command asks you for the URL (and shows you exactly what to put in
  the file). `-RepoUrl <url>` on the command line always wins.
- `repos.json` is yours and is never committed. **Don't put the internal URL on the
  external kit** — internal server names shouldn't travel to the internet side.

## The dictionary (internal kit only)

`dictionary.json` is where internal-specific text lives. It's a JSON object whose keys are
the text to find and whose values are the replacements, applied to every text file on every
landing:

```json
{
  "eliya": "dori"
}
```

- **First-time setup is guided:** on the first landing, if `dictionary.json` doesn't exist,
  landing writes a starter file with a placeholder pair and stops so you can put your real
  pairs in. (The placeholder matches nothing, so it can never inject wrong content, and a
  later kit update can't overwrite your values.)
- **To change internal content:** edit `dictionary.json`, run landing. That's it.
- **Backups are automatic:** every landing saves your dictionary to the `airgap-config` branch
  on your internal server. If the kit (or just the file) is ever lost, landing restores the
  last saved copy by itself.
- Keep the find-keys precise: `eliya` also matches inside `eliyahu`.

## If something goes wrong

The commands fail with a message that says what to do. The most common ones:

- **"git was not found on PATH"** — install Git for Windows, reopen the terminal, re-run.
- **"No bundle folder in toUpload"** — copy the `toUpload\<name>` folder produced by
  takeoff into this kit's `toUpload\` first.
- **"toUpload holds N bundle folders"** — landing takes exactly one per run; move the
  extras out of `toUpload\` (land them one at a time, oldest first).
- **"Stale bundle"** — you carried an old bundle; run takeoff again for a fresh one.
- **"Server already has pre-dev"** — this is a fresh kit but your server was already set up;
  the message shows the two commands to reconnect instead of starting over.

> **Updating an existing kit copy:** older kits had `takeoff.ps1` / `landing.ps1` at the top
> level (later `takeoff.cmd` / `landing.cmd` without the numbers) and used a `transfer\`
> folder for the bundle. If you refresh a deployed kit by copying this folder over it,
> **delete the old top-level launcher/script files** — they still run but are outdated —
> and retire `transfer\` (bundles now live in per-run `toUpload\` folders). Your
> `dictionary.json` and `repos.json` are untouched by a copy-over; an old `repo\` is
> migrated automatically into `repo\external` (by takeoff) or `repo\internal` (by
> landing) on the next run.

Full operating guide (steady-state, hotfix, reconcile): `docs/RUNBOOK.md` in the toolkit repo.
