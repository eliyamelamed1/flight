# Air-gap sync kit

This folder is a **kit**: copy it onto a machine and run **one** command from it.

- On the **internet** machine → run **`takeoff`**.
- On the **air-gapped** machine → run **`landing`**.

Everything else the commands need lives right here beside them:

```
kit\
├─ takeoff.cmd                   run this on the EXTERNAL (internet) machine
├─ landing.cmd                   run this on the INTERNAL (air-gapped) machine
├─ repos.sample.json             template for your repo URLs — copy to repos.json
├─ dictionary.sample.json        template for your find/replace pairs (internal only)
├─ repo\                         the git repo (the commands create it — don't make it yourself)
├─ transfer\app.bundle           the file you carry across the air gap
└─ engine\                       all the PowerShell (including takeoff.ps1/landing.ps1) — you never run these directly
```

> **Tip:** double-click the **`.cmd`** launcher (`takeoff.cmd` / `landing.cmd`). On a
> locked-down host that blocks PowerShell scripts, the `.cmd` is the way in — it already runs
> with `-ExecutionPolicy Bypass`, so you don't have to change any policy yourself.
> (`git` must be installed and on `PATH`; the command tells you if it isn't.)

## On the EXTERNAL (internet) machine

1. Double-click `takeoff.cmd` (or run `.\engine\takeoff.ps1` from a PowerShell window).
2. It reads the **GitHub repo URL** from `repos.json` (see below) — or asks for it if
   you haven't set that up.
3. It writes `transfer\app.bundle`. Copy that one file to the internal machine, into the
   internal kit's `transfer\` folder.

## On the INTERNAL (air-gapped) machine

1. Double-click `landing.cmd` (or run `.\engine\landing.ps1` from a PowerShell window).
2. **First time only:** if you haven't set up your dictionary yet, landing creates
   `dictionary.json` for you from the sample, then stops and asks you to fill in your real
   pairs (see below). Edit it, then run landing again.
3. It reads your **internal git server URL** from `repos.json` — or asks for it if you
   haven't set that up.
4. Done. The first real run sets everything up and pushes `pre-dev/develop/staging/main`;
   every later run just brings in the latest code and pushes `pre-dev`.

Then promote `pre-dev → develop → staging → main` with your normal PR/CI process.

## The repos file (skip the URL prompt)

Copy `repos.sample.json` → `repos.json` (same folder) and fill in **only your side's key**:

```json
{
  "external": "https://github.com/org/app.git",
  "internal": ""
}
```

- Takeoff uses `"external"`, landing uses `"internal"`. An empty or missing key just means
  that command asks you for the URL, like before. `-RepoUrl <url>` on the command line
  always wins.
- `repos.json` is yours and is never committed. **Don't fill the internal URL on the
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
  landing copies `dictionary.sample.json` → `dictionary.json` and stops so you can put your real
  pairs in. (The sample is never used directly, and a later kit update can't overwrite your
  values.)
- **To change internal content:** edit `dictionary.json`, run landing. That's it.
- **Backups are automatic:** every landing saves your dictionary to the `airgap-config` branch
  on your internal server. If the kit (or just the file) is ever lost, landing restores the
  last saved copy by itself.
- Keep the find-keys precise: `eliya` also matches inside `eliyahu`.

## If something goes wrong

The commands fail with a message that says what to do. The most common ones:

- **"git was not found on PATH"** — install Git for Windows, reopen the terminal, re-run.
- **"No bundle"** — copy `app.bundle` from the takeoff kit into `transfer\` first.
- **"Stale bundle"** — you carried an old bundle; run takeoff again for a fresh one.
- **"Server already has pre-dev"** — this is a fresh kit but your server was already set up;
  the message shows the two commands to reconnect instead of starting over.

> **Updating an existing kit copy:** older kits had `takeoff.ps1` / `landing.ps1` at the top
> level. If you refresh a deployed kit by copying this folder over it, **delete those two
> old top-level files** — they still run but are outdated (the current ones live in
> `engine\`). Your `dictionary.json`, `repos.json`, `repo\` and `transfer\` are untouched
> by a copy-over.

Full operating guide (steady-state, hotfix, reconcile): `docs/RUNBOOK.md` in the toolkit repo.
