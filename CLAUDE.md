# teams-api

A Microsoft Teams client in Zig with no third-party dependencies: `std` plus Apple system frameworks, no Node, no Java, no browser runtime in the client. `scripts/teams-token.fish` signs in through agent-browser and stores the skype token and region in the login keychain.

`inspo/` holds a third-party reference project (`teams-api`). Read it for protocol facts only; never copy code from it or add its dependencies.

## Style

- `docs/STYLE.md`: the Zig style guide. It wins where it disagrees with Tiger Style.
- `docs/TIGER_STYLE.md`: TigerBeetle's style guide.

Target Zig 0.17. `build.zig.zon` keeps `.dependencies = .{}`.

## How we work

Build this semi-autonomously. I'm involved at milestone boundaries, not chunk by chunk.

- Each milestone starts from a written plan I've approved. Within it, work through the chunks without waiting for my go-ahead.
- Keep chunks small: one function, one type or one test at a time. Commit each once `zig build test` passes (message like `M1.1: package skeleton`). Never push.
- Decide routine things yourself, following the style guides: naming, internal structure, error sets, test shape, refactors inside the milestone's code. Note any decision worth knowing in the commit message.
- Stop and ask only for: changes to the plan, the brief or behaviour I'd see; a new dependency or outside tool; anything touching secrets, the keychain or files outside the repo; any live Teams call that writes (send, edit, delete, react); or being genuinely blocked.
- When one decision blocks you, park it, carry on with work that doesn't depend on it, and bring parked questions to the next checkpoint.
- At the end of a milestone, run the gate, then give me one report: what was built, decisions you made, and parked questions.

## Writes to Teams

The `send` command may post messages; I lifted the ban for it in M5. Nothing else may write to Teams: no editing, deleting, reacting, marking as read, changing presence or any other state change. Other code, tests and scripts only make GET requests to read. This holds until I explicitly lift it for another write; a plan or milestone that includes writes does not lift it on its own.

Agents' live send tests go only to my own notes chat (`48:notes`), are kept minimal, and run only after I confirm each one at that moment.

## Secrets

Tokens, cookies and refresh tokens never go in the repo, in test fixtures, in logs or in chat. Tests use obviously fake values.

## Milestone gate

A milestone (M1, M2, …) isn't resolved until it has passed this gate. Run it after the last chunk, before resolving the milestone.

1. Run three reviews of all the milestone's code, the two style passes in separate subagents:
   - the `mr-review` skill, invoked each round (not run from memory) with its full checklist;
   - a pass against `docs/STYLE.md` only;
   - a pass against `docs/TIGER_STYLE.md` only (following `STYLE.md` where it explicitly overrides Tiger Style).
2. Every finding that a rule written in `STYLE.md` or `TIGER_STYLE.md` covers is approved in advance: apply it without asking. Don't waive a written rule because it seems not to fit. If it doesn't make sense in context, treat that as a sign the code is wrong somewhere else, and refactor until the rule fits.
3. Everything else (design decisions, `mr-review` findings no guide rule covers, anything that changes behaviour or the plan) goes to me one finding at a time in the milestone report.
4. Apply the fixes in chunks, committed like any other chunk, then report what was done. Record the gate's findings and fixes in a `## M<n> gate` section of `docs/PLAN.md`.
5. The gate's own fixes are code changes too: run all three reviews again on them, and repeat until a round finds nothing new. Only then resolve the milestone.
