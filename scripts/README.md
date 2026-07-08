# Air-gap sync kit

This folder is a **kit**: copy it onto a machine and run one script from it.
Everything the scripts need lives right here, next to them:

```
kit\
├─ takeoff.ps1 / takeoff.cmd     run this on the EXTERNAL (internet) machine
├─ landing.ps1 / landing.cmd     run this on the INTERNAL (air-gapped) machine
├─ repo\                         the git repo (the scripts create it - don't make it yourself)
├─ transfer\app.bundle           the file you carry across the air gap
├─ dictionary.sample.tsv         template - copy it to dictionary.tsv (internal kit only)
└─ dictionary.tsv                YOUR find/replace pairs (internal kit only, see below)
```

## Everyday use

**On the external machine:**
1. Double-click `takeoff.cmd` (or run `.\takeoff.ps1`).
2. It asks for the GitHub repo URL — paste it.
3. It writes `transfer\app.bundle`. Copy that file to the internal machine,
   into the internal kit's `transfer\` folder.

**On the internal machine:**
1. Double-click `landing.cmd` (or run `.\landing.ps1`).
2. It asks for your internal git server URL — paste it.
3. Done. The first run sets everything up; every later run just brings in the
   latest code and pushes `pre-dev` to your server.

Then promote `pre-dev → develop → staging → main` with your normal PR/CI process.

## The dictionary (internal kit only)

`dictionary.tsv` is where internal-specific text lives. Each line is
`what-to-find` TAB `what-to-replace-it-with`, applied to every text file on every landing:

```
eliya	dori
```

- **First-time setup:** copy `dictionary.sample.tsv` → `dictionary.tsv`, then put your
  real pairs in it. (landing refuses to run without it — the sample is never used
  directly, so a kit update can't overwrite your values.)
- **To change internal content:** edit `dictionary.tsv`, run landing. That's it.
- **Backups are automatic:** every landing saves your dictionary to the
  `airgap-config` branch on your internal server. If the kit (or just the file) is
  ever lost, landing restores the last saved copy by itself.
- Keep the find-keys precise: `eliya` also matches inside `eliyahu`.

## If something goes wrong

The scripts fail with a message that says what to do. The most common ones:

- **"No bundle"** — copy `app.bundle` from the takeoff kit into `transfer\` first.
- **"No dictionary"** — do the first-time dictionary setup above.
- **"Stale bundle"** — you carried an old bundle; run takeoff again for a fresh one.
- **"Server already has pre-dev"** — this is a fresh kit but your server was already
  set up; the message shows the two commands to reconnect instead of starting over.

Full operating guide: `docs/RUNBOOK.md` in the toolkit repo.
