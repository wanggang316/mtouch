# Documentation

This directory is the **system of record** for project knowledge. If it is not
here, it does not exist as far as an agent is concerned.

## Structure

| Directory / File | Purpose |
|---|---|
| [architecture.md](architecture.md) | System architecture, domains, and the seams that keep it testable |
| [agent-guide.md](agent-guide.md) | How to drive a computer with mtouch — the practical companion |
| [golden-rules.md](golden-rules.md) | Constrained principles and conventions |
| [platform-notes.md](platform-notes.md) | macOS behaviours learned the hard way, each with its measurement |
| [design-docs/](design-docs/) | Technical design docs (human-authored) |
| [user-test-patterns.md](user-test-patterns.md) | Project-wide testing conventions (personas, cost tiers, tooling) |
| [references/](references/) | External references, API docs, integration notes |
| [generated/](generated/) | Generated artifacts — do not hand-edit |

Per-plan FDD state (plan, validation contract, features, handoffs) lives in the
gitignored `.harness-runtime/plans/<slug>/` tree, **not** in `docs/`. The Library
holds durable conventions and memory; for concrete behaviour, the code is the
source of truth and the validation contract is the specification.

## Which document answers which question

- *"How do I make mtouch do X?"* → [agent-guide.md](agent-guide.md)
- *"Where does this code go, and why is it shaped this way?"* → [architecture.md](architecture.md)
- *"Why does macOS behave like that?"* → [platform-notes.md](platform-notes.md)
- *"What is this project unwilling to do?"* → [golden-rules.md](golden-rules.md)
- *"What exactly must be true for a release?"* → the validation contract in
  `.harness-runtime/plans/mtouch/validation-contract.md`

## Conventions

- Each document is self-contained enough for an agent to act on directly.
- Claims about behaviour carry their measurement. "Reproduced 4/4", "2.06 s of a
  60 s wait", "0/8 after, 4/8 before" — a number that came from a real run is
  worth more than an adjective, and it is what lets a future reader tell whether
  the claim still holds.
- One concept per file; relative links between them.
- Documents are marked deprecated rather than deleted.
