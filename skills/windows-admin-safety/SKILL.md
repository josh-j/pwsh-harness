---
name: windows-admin-safety
description: Plan or run Windows administration changes involving services, registry, tasks, permissions or deletion. Use for actual administration work.
---
# Windows administration

Distinguish editing a script from executing an administrative action. Keep execution within the user's authorization.

- Inspect current state and identify the exact target set before a change. Keep prior values needed for rollback.
- Use literal paths for deletion and permission changes. Validate computed paths before recursive operations.
- Support `ShouldProcess` and useful `-WhatIf` behavior in reusable mutating functions when appropriate.
- Use fixtures, mocks or a dry run to test potentially destructive behavior; do not mutate a real system merely to test a branch.
- Prefer CIM commands to removed WMI cmdlets in PowerShell 7. Filter event queries at the source.
- Use `Get-CimInstance` or `Invoke-CimMethod` and `Get-WinEvent -FilterHashtable`; avoid removed `Get-WmiObject` and `Get-EventLog` commands.
- Check platform support and elevation only when the action needs them. Guard Windows-only APIs when a script also runs elsewhere.
- Set suitable error handling and verify the resulting service, task, registry or ACL state.
- Check availability before using optional or legacy modules and UI commands.
- Keep credentials out of source, configuration output and logs. Use the credential mechanism already authorized for the environment.

A skill describes a workflow; it does not grant additional permissions or enable autonomous mode.
