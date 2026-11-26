# Perf log

One row per perf-gate run (`scripts/perf-gate.sh`), appended by the script. Values are the
median of each test's iterations. SHA ends in `-dirty` when the tree had uncommitted changes.

- `sim` rows come from the `plain-perf-duo` simulator. They track trends only: they are not
  comparable to the device budgets, and XCUITest automation inflates launch times there
  (main → focused field is ~0.2–0.4 s outside the test harness, ~2 s inside it).
- `device` rows come from the phone and are held to `perf/budgets.json`.

Columns: launch = cold launch until responsive (ms), field = `main` to search field focused (ms),
hitch = page scroll hitch ratio (ms/s).

| Date | SHA | Target | Launch ms | Field ms | Hitch ms/s | Result |
|---|---|---|---|---|---|---|
| 2026-11-26 05:23 | 9b9ba4e | sim | 3353.9 | 2064.4 | n/a | pass |
| 2026-11-26 06:16 | 6ba5947 | sim | 3578.5 | 2035.5 | n/a | pass |
| 2026-11-26 06:33 | 2c966cc | sim | 3529.1 | 1851.1 | n/a | pass |
| 2026-11-26 07:13 | 34cc71f | sim | 3461.8 | 1880.7 | n/a | pass |
| 2026-11-26 12:10 | f556baf | sim | 3578.0 | 2045.0 | n/a | pass |
| 2026-11-26 12:26 | 77d08f4 | sim | 3570.7 | 507.9 | n/a | pass |
