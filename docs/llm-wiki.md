# LLM Wiki (opt-in, shared KB)

> **Purpose:** Use the optional shared knowledge base, including a standalone wiki session and Obsidian sync.
>
> Back to [README](../README.md) · [documentation index](README.md).


An optional, **shared** knowledge base built with
[`@zosmaai/pi-llm-wiki`](https://pi.dev/packages/@zosmaai/pi-llm-wiki) — the
Karpathy "LLM wiki" pattern: immutable source capture, automated ingestion,
search, linting, and an Obsidian-compatible vault.

It is **off by default**. Plain `pictl` / `make run` are unchanged. Enable it
for a single session with `pictl -w` (or `make run WIKI=true ...`). The package
is loaded for that run only via `pi -e`, so nothing is written to
`settings.json` and seeding/syncing other instances is unaffected.

## One-time setup (host, needs network)

```bash
make wiki-setup
```

This vendors the pinned package into `vendor/pi-llm-wiki` and creates the shared
vault root. Re-running is a no-op; bump `LLM_WIKI_VERSION` in `.env` to upgrade.
The step also applies a small, idempotent patch to one upstream prompt file
(`prompts/wiki-run.md`) whose frontmatter is invalid YAML — without it,
`/wiki-run` fails to load. You may see a `Patched prompts/wiki-run.md` line.

## Use

```bash
pictl -w ~/code/project-a      # this session has the wiki
pictl ~/code/project-b         # no wiki (unchanged)

# equivalent:
make run WIKI=true WORK_DIR=~/code/project-a
```

Inside the session: `/wiki-init "AI Engineering"`, then capture/ingest/query.
Project A, project B, etc. all use the **same** vault, so knowledge accumulates
across workspaces.

## Use without a project

The vault does not belong to any workspace, so the KB can be used on its own —
no checkout mounted, no project data dir touched:

```bash
pictl wiki                     # the wiki, no project attached
pictl wiki -b                  # ... in the background (pictl attach wiki)
make run WIKI_ONLY=true        # the same from the Makefile

# spelled out:
pictl -w --no-workspace
```

The container still needs something at `/workspace`, so this pins it to a
dedicated **empty scratch dir**, `LLM_WIKI_SESSION_DIR` (default `~/pi-wiki`).
It is not a project: nothing from it reaches the vault, and every `pictl wiki`
run shares one instance (`.pi-data-pi-agent-wiki`, override with
`PROJECT_NAME=`), so `/resume` carries the same history from session to session.
Everything worth keeping lives in the shared vault.

A path contradicts "no project", so both of these are refused rather than
silently ignored:

```bash
pictl wiki ~/code/x            # error: use `pictl -w ~/code/x` instead
make run WIKI_ONLY=true WORK_DIR=~/code/x   # error
```

| Setting | Default | Meaning |
|---|---|---|
| `LLM_WIKI_DIR` | `$HOME/pi-llm-wiki` | Host dir; the vault is `<dir>/.llm-wiki/` |
| `LLM_WIKI_SESSION_DIR` | `$HOME/pi-wiki` | Empty dir mounted at `/workspace` for `pictl wiki` |
| `LLM_WIKI_VERSION` | `0.12.2` | Pinned package version (keep in step with the image's `pi`) |
| `WIKI_ONLY` | off | `pictl wiki` / `make run WIKI_ONLY=true`: wiki, no project |

- Vault on the host: `~/pi-llm-wiki/.llm-wiki/`
- Vault in the container: `/home/node/llm-wiki/.llm-wiki/`
- If a workspace already contains its own `.llm-wiki/`, that **project vault
  wins** over the shared one. To keep one common KB, don't `/wiki-init` inside a
  workspace.

  > **Symptom: Obsidian shows an empty vault, or the agent seems to ignore the
  > shared KB.** A stray `<workspace>/.llm-wiki/` is shadowing the shared vault:
  > the agent's knowledge is landing in the project vault, which Syncthing does
  > not share. Fix: stop the session, delete the stray `<workspace>/.llm-wiki/`,
  > and restart with `pictl -w`. The shared vault at `~/pi-llm-wiki/.llm-wiki/`
  > is the only one that reaches the Mac. `.llm-wiki/` is gitignored so a
  > project vault can never be committed.

## Sync to a Mac and open in Obsidian

The host vault is plain markdown plus source artifacts, so any file sync works.
[Syncthing](https://syncthing.net) is the recommended LAN option (continuous,
peer-to-peer, no cloud):

1. **Host:** install Syncthing and share the vault folder itself,
   `~/pi-llm-wiki/.llm-wiki` (its contents are the whole vault).
2. **Mac:** install Syncthing, accept the share, and set the local folder path
   to a plain **local** folder such as `~/vaults/llm-wiki`. Keep it out of any
   cloud-synced area:
   - Obsidian's iCloud container:
     `~/Library/Mobile Documents/iCloud~md~obsidian/`.
   - `~/Documents` and `~/Desktop` when **iCloud → iCloud Drive → Desktop &
     Documents Folders** is on (they become iCloud-backed). Enable the folder
     only when Off:
     `ls -ld ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents 2>/dev/null`
     — if that path exists, Desktop & Documents is on, so do **not** use
     `~/Documents`.

   Never run Syncthing, Obsidian Sync, and iCloud on the same vault — they will
   fight.
3. **Mac (Syncthing UI):** add ignore patterns `.obsidian/` and `.DS_Store` so
   Obsidian's local config does not appear as un-synced local changes in the
   Receive Only folder.
4. **Obsidian (Mac):** *Open another vault → Open folder as vault*. The macOS
   folder picker is sandboxed and may not browse into every home folder, and
   Finder/Spotlight may not list a folder a sync daemon created. Press
   **Cmd+Shift+G** in the picker, paste the absolute path
   (`/Users/<you>/vaults/llm-wiki`), then Open. Obsidian remembers it after.

> Prefer a plain folder like `~/vaults/llm-wiki` over one named `~/Obsidian`,
> which is easy to confuse with Obsidian's app/iCloud folders. Finder *browsing*
> works once the vault is open; Finder *search* relies on Spotlight, which may
> not index a synced folder.

Optional `.stignore` in the shared folder (host side) to skip regenerable/heavy
indexes while keeping pages and sources:

```
meta/qmd/
```

Alternatives to Syncthing:

- **rsync (pull-only, run on the Mac):**
  `rsync -av --delete host:~/pi-llm-wiki/.llm-wiki/ ~/vaults/llm-wiki/`
- **git:** `git init` inside `.llm-wiki/`, push to a private remote, and use the
  Obsidian Git plugin on the Mac.

> The container host is the writer and the Mac is a reader. Edit on the Mac only
> while no container is running, or two-way sync can conflict.

The vault is created automatically the first time you run `pictl -w` or
`pictl wiki`. Do **not** run `/wiki-init` in a workspace — that creates a
project vault which shadows the shared one. To set the topic, edit
`~/pi-llm-wiki/.llm-wiki/config.json` or use `/wiki-settings`.

`make wiki-setup` installs the package with `npm --ignore-scripts` to avoid a C
toolchain, so the optional native `@tobilu/qmd` indexing (semantic/embedding
features) is not built. Capture, ingest, keyword search, recall, and linting all
work without it.
