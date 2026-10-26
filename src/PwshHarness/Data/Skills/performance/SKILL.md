---
name: performance
description: Measure and improve PowerShell runtime or memory cost. Use when performance is part of the task or a measured bottleneck blocks it.
---
# PowerShell performance

Measure representative work before optimizing. Preserve behavior and safety checks.

- Use `Measure-Command` or a stopwatch around the operation that is actually slow.
- Separate cold startup, repeated-call overhead, model time, command time and waiting when those distinctions matter.
- Avoid array `+=` in large loops; use a generic list or collect the output of a loop.
- Filter at the source and stop bounded queries early. Do not materialize an entire tree for a small answer.
- Batch independent inspections and avoid launching a new process for each item.
- Use dictionaries or sets for repeated keyed lookup.
- Prefer string builders or `-join` over repeated string concatenation in large loops.
- Use existing lightweight .NET filesystem seams where appropriate; validate links, encoding and identity behavior when replacing provider cmdlets.
- Bound concurrency to the environment. Isolate tests whose wall-clock contracts require predictable scheduling.
- Compare the same representative input after the change. Report the measurement and its limits; do not infer broad speedups from an unrelated microbenchmark.
