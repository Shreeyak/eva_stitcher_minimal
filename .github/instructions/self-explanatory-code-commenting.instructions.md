---
description: "Guidelines for writing self-explanatory code with minimal comments. Comment only to explain WHY, not WHAT."
applyTo: "**"
---

# Code Commenting

- **Default**: Write self-explanatory code. No comments needed most of the time.
- **Comment only WHY**, never WHAT — if a comment restates the code, delete it.
- Before commenting, ask: would a better name eliminate the need? If yes, rename instead.
- **Do comment**: complex business logic, non-obvious algorithm choices, regex patterns, API constraints/gotchas, external workarounds (HACK/FIXME tags).
- **Do document**: public API signatures (purpose, params, returns).
- **Never**: comment out dead code, add changelog comments in source, or use decorative dividers.
