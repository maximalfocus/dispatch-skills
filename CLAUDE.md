# dispatch-skills repository conventions

## Sources of truth

`skills/*/SKILL.md` are the product: `/dispatch` (dispatcher), `/dispatch-aide` (aide, 副手),
`/dispatch-worker` (worker), `/dispatch-evolve` (evolution). `CONSTITUTION.md` governs every
change. The hand-off formats live only in `skills/dispatch/SKILL.md`; other skills reference them.
`scripts/install.sh` links the skills for Claude Code and `~/.agents/skills`.

## Editing discipline

- Run `scripts/size-gate.sh` and `scripts/validate.sh`; both must print `PASS`.
- Articles 1–5 of `CONSTITUTION.md` are byte-identical to `cdd-skills`; never edit them here.
- Mechanical behavior goes in `scripts/` with a test, not in skill prose (Articles 5 and 10.3).
- Keep the skills project-neutral: no employer, customer, product, or person names; examples use
  generic stacks.
- Commit as `maximalfocus <21332201+maximalfocus@users.noreply.github.com>`; deliver through a PR.

Integration-branch: main
