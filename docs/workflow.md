# Build workflow: implement, verify, review, iterate

Each feature or milestone goes through one loop. The loop stops when the work passes every gate and both reviewers have no blocking findings, or after 3 review rounds, whichever comes first.

## Roles

- **Lead** (the main session): writes the brief, runs the gates, decides what counts as blocking, merges. Only the lead installs on the Duo and runs the perf gate, so the single device is never contended.
- **Implementer** (one per feature, in its own worktree off `dev`): builds the feature and fixes findings. Commits to its branch.
- **Code and performance reviewer** (fresh each round): reads the diff against AGENTS.md, the architecture rules and the perf numbers. Looks for main-thread work, extra layout passes, state with more than one owner, layering breaks, leaks and missing signposts.
- **Design reviewer** (fresh each round): looks only at the device result. It compares screenshots of both Duo screens and of a regular iPhone simulator, plus frames from a screen recording of each interaction, against `docs/ui-reference.md` and the motion table in the plan. Looks for alignment, spacing, chrome that shouldn't be there, wording, motion timing, and fold behavior.

Reviewers get the brief, the diff or the captures, and the rules. They never see the implementer's reasoning or the other reviewer's findings, so their reviews stay independent.

## The loop

1. **Brief.** The lead writes acceptance criteria: what the user does, what they see, the motion spec rows involved, and the budgets that apply.
2. **Implement.** The implementer builds the feature with tests and signposts. It runs `swift test` and the simulator UI tests before handing back.
3. **Verify.** The lead runs the build and tests, installs on the Duo, runs `scripts/perf-gate.sh`, and captures screenshots (`scripts/shot.sh`) and a short screen recording of each new interaction (`xcrun devicectl device capture screen-record`, frames extracted with `ffmpeg`). Any failure goes straight back to the implementer, without a review round.
4. **Review.** The two reviewers run in parallel. Each finding is tagged **blocking** (wrong behavior, a budget miss, a rule break, or something that visibly looks or feels off) or **polish**.
5. **Iterate.** The implementer fixes all blocking findings, plus polish items that are cheap. Then go back to step 3. Each later round reviews only what changed.
6. **Land.** Merge into `dev` and push. Append the perf numbers to `docs/perf-log.md`. Leave the build installed on the Duo. Remove the worktree, the branch, and any simulators and captures the loop created.

## Keeping it lean

- Small, mechanical changes (copy, one-line fixes) skip the review step and go through the gates only.
- Polish findings that remain after round 3 go to `docs/polish-backlog.md`, not into more rounds.
- Briefs, findings and fixes stay short: a list, not an essay.
