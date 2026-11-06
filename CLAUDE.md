# teams-api

A Microsoft Teams client in Zig with no third-party dependencies: `std` only, no Node, no Java, no browser runtime.

`inspo/` holds third-party reference projects (`teams-token`, `teams-api`). Read them for protocol facts only; never copy code from them or add their dependencies.

## Style

- `docs/STYLE.md`: the Zig style guide. It wins where it disagrees with Tiger Style.
- `docs/TIGER_STYLE.md`: TigerBeetle's style guide.

Target Zig 0.17. `build.zig.zon` keeps `.dependencies = .{}`.

## How we work

I want to be heavily involved. We build this together, chunk by chunk.

- Work in small chunks: one function, one type or one test at a time, small enough to review in one sitting.
- Before each chunk, say what you're about to do and wait for my go-ahead.
- After each chunk, stop and show me the result before moving on.
- Never make large or sweeping changes without my explicit permission. That includes multi-file edits, rewrites, renames, restructuring and changes to the plan or the brief.
- Approval for one chunk doesn't carry over to the next.
- When a decision comes up mid-chunk, stop and ask rather than picking one yourself.
- After each approved chunk, commit it (message like `M1.1: package skeleton`). Never push.

## Secrets

Tokens, cookies and refresh tokens never go in the repo, in test fixtures, in logs or in chat. Tests use obviously fake values.

## Milestone gate

A milestone (M1, M2, …) isn't resolved until it has passed this gate. Run it after the last chunk, before resolving the ticket.

1. Run three reviews of all the milestone's code, the two style passes in separate subagents:
   - the `mr-review` skill, invoked each round (not run from memory) with its full checklist;
   - a pass against `docs/STYLE.md` only;
   - a pass against `docs/TIGER_STYLE.md` only (following `STYLE.md` where it explicitly overrides Tiger Style).
2. Every finding that a rule written in `STYLE.md` or `TIGER_STYLE.md` covers is approved in advance: apply it without asking. Don't waive a written rule because it seems not to fit. If it doesn't make sense in context, treat that as a sign the code is wrong somewhere else, and refactor until the rule fits.
3. Everything else (design decisions, `mr-review` findings no guide rule covers, anything that changes behaviour or the plan) goes to me one finding at a time, as usual.
4. Apply the fixes in chunks, committed like any other chunk, then report what was done. Record the gate's findings and fixes on the milestone's ticket.
5. The gate's own fixes are code changes too: run all three reviews again on them, and repeat until a round finds nothing new. Only then resolve the milestone.
