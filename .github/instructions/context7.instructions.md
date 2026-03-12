---
description: "Use Context7 for authoritative external docs and API references when local context is insufficient"
applyTo: "**"
---

# Context7-aware development

Use Context7 proactively when the task depends on **authoritative, version-specific external documentation** not present in the workspace.

## When to use

- Framework/library API details (signatures, config keys, behaviors)
- Version-sensitive guidance (breaking changes, deprecations, new defaults)
- Security-critical patterns (auth flows, crypto, deserialization)
- Non-trivial configuration (CLI flags, config files)
- Unfamiliar error messages from third-party tools

## When to skip

- Purely local refactors, formatting, naming, or logic derivable from the repo
- Language fundamentals with no external API involvement

## Efficiency limits

- Max **3** `resolve-library-id` calls per question
- Max **3** `get-library-docs` calls per question
- Pick the best match and proceed; ask only when the choice materially affects implementation

## Failure handling

1. State what you tried to verify
2. Proceed with a conservative, labeled assumption
3. Suggest a quick validation step (run a command, check a file)
