# Managed skills & extensions

> **Purpose:** Vendor skills and extensions from a pi package repository into the image at build time.
>
> Back to [README](../README.md) · [documentation index](README.md).


You can version-control custom **skills** and **extensions** in a separate git repository,
and have them automatically included in the Docker image at build time.

## How it works

1. Create (or fork) a git repo with the **pi-package** structure.
2. Add your custom skills to `skills/` and extensions to `extensions/`.
3. Pass the repo URL when building the image.

At **build time**, the `Makefile` clones the repo, installs npm dependencies,
and copies skills/extensions directly into `.pi-data/agent/skills/` and
`.pi-data/agent/extensions/` on the host. Since `.pi-data/` is bind-mounted
into the container at `/home/node/.pi/`, these are immediately available
to the agent at runtime — no entrypoint wrappers needed.

Your managed repo should follow the **pi-package** structure — a `package.json` with a `pi` manifest
pointing to `skills/` and `extensions/` directories.

```json
{
  "name": "my-pi-skills-extensions",
  "keywords": ["pi-package"],
  "pi": {
    "skills": ["./skills"],
    "extensions": ["./extensions"]
  }
}
```

See the [pi packages documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/packages.md) for details.

## Build with Managed Repo

Set the URL in your `.env` file (recommended):
```bash
# In .env
MANAGED_REPO_URL=https://github.com/your-org/pi-skills-extensions
MANAGED_REPO_REF=v1.0.0
```

Then just run:
```bash
make build
```

Or pass it directly on the command line:
```bash
make build MANAGED_REPO_URL=https://github.com/your-org/pi-skills-extensions
```

If `MANAGED_REPO_URL` is not set (neither in `.env` nor on the command line),
the build proceeds as before with no managed content.

**Note:** Skills/extensions are cloned fresh on every `make build`.
Local changes to `.pi-data/agent/skills/` or `.pi-data/agent/extensions/`
will be overwritten. For dynamic installs at runtime without a rebuild,
use `pi install git:github.com/your-org/pi-skills-extensions` inside the container.
