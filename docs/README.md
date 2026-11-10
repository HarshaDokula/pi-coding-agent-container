# Documentation

Start with [USAGE](../USAGE.md) for the hands-on walkthrough. The root
[README](../README.md) is the feature reference for the core workflow, and
[SECURITY](../SECURITY.md) is the threat model and remediation tracker.

| Document | Purpose |
|---|---|
| [USAGE](../USAGE.md) | install, run, network modes, credentials, troubleshooting |
| [README](../README.md) | core feature reference: launcher, workspaces, instances, keys, maintenance |
| [Security model](security-model.md) | enforced guards, advisory speed bumps, and residuals |
| [SECURITY](../SECURITY.md) | security findings and outstanding remediation work |
| [Offline mode](offline-mode.md) | local llama.cpp/Ollama-style model server, no cloud provider |
| [Managed skills & extensions](managed-skills.md) | vendor a pi package repo into the image at build time |
| [LLM Wiki](llm-wiki.md) | opt-in shared knowledge base, standalone session, Obsidian sync |
| [Per-project toolchains](toolchains.md) | mise-managed Node/Python/etc. versions |
| [Subagents](subagents.md) | delegate work to child pi processes |

The Dockerfile and Compose files stay at the repository root: that is what
`docker compose` discovers by default, and moving them would break direct
`docker compose` use and most existing paths. Local-only notes (`plans/`,
`TESTING.md`) are intentionally not part of this published index.
