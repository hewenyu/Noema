# AGENTS.md — Documentation standard

This file defines where each kind of fact lives and how documentation is written. It applies to `docs/`, `README.md`, and the root [AGENTS.md](../AGENTS.md); [Agent Notes](../.agents/notes/README.md) follow their own format.

## One home per fact

| Tier | Job | Does not belong there |
|---|---|---|
| Root `AGENTS.md` | Standing orders needed in every session, one to three lines each, linking their home | Stories, examples, procedures, anything restated from a linked home |
| `docs/AGENTS.md` | This standard: tiers, writing rules, budgets | Repo-wide rules the root already carries |
| [`docs/architecture.md`](architecture.md) | Map of components, module graph, build and CI pipeline, seams | Type definitions, per-module detail, decision rationale |
| `README.md` | What Noema is, its current state, and the commands to build and test it | Rationale, rules restated from `AGENTS.md` |
| Script headers | Each script's usage, options, and exit codes (`scripts/**`) | Design rationale |
| `.agents/notes/` | Decision rationale and rejected alternatives | Current-state reference |

Placement: rationale → Agent Notes; script usage → the script's header comment; standing orders → root `AGENTS.md` with a link. Add a tier to this table in the same change that creates it (for example `docs/postmortem/` for incident write-ups, the only home for war stories).

## Writing rules

- **Document current state.** No "previously", "now", "no longer", or "new in v2" outside notes and changelogs.
- **Link instead of restating.** Search for a distinctive phrase before adding a rule; if it exists, link it.
- **Do not hand-copy what the source owns** (option lists, Info.plist keys, file inventories); point at the file.
- **No status annotations** ("implemented!", "TODO: future") in prose; status rots.
- **No reasoning transcripts.** Keep the resulting contract; delete the path used to derive it.
- **Name the exact thing.** Prefer the function, file, field, or command over a metaphor.
- **Reserve emphasis** for the clause that changes behavior.

## Word budgets

[`scripts/governance/doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json) sets ceilings; `scripts/governance/verify-doc-budgets.mjs` rejects excess (each CJK character counts as one word). When it fails: relocate content to its owning tier, then condense, and raise the ceiling only with a justification in the PR. `scripts/governance/check.sh` runs this check with the other governance gates.
