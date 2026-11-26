@AGENTS.md

## Claude Code

- Before you call a UI change done, view the device or simulator screenshots with the Read tool.
- Build features with the subagent loop in `docs/workflow.md`: implement, verify on the device, run code/perf and design reviews, then iterate. Reviews always run on Codex (`codex review` / `codex exec`), never on Claude subagents.
- Give subagents the rules in AGENTS.md. Have them work in their own worktree, and merge their work into `dev` only after review.
- Clean up after yourself and after every subagent you start. Before you finish, check that no simulators, build or test files, worktrees or branches you or they created are left behind.
