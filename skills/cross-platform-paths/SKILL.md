---
name: cross-platform-paths
description: Handle filesystem paths, Unicode, encodings and line endings across Windows and Unix. Use for portability or path-handling changes.
---
# Cross-platform paths

Use the existing platform seams and test the platforms relevant to the change.

- Build filesystem paths with `Join-Path` or `System.IO.Path` methods, rather than concatenating separators.
- Use `-LiteralPath` for filenames that may contain brackets or wildcard characters.
- Linux paths are case-sensitive. Avoid assuming that Windows path spelling or reserved device names are portable.
- Resolve nonexistent targets with a suitable full-path operation; `Resolve-Path` requires an existing target.
- Use the OS temporary directory and the project's fixture override for disposable files.
- State encoding when it matters. PowerShell 7 defaults to UTF-8 without a BOM; preserve an existing BOM or line ending when required by the edit contract.
- Treat symlinks, junctions and hardlinks deliberately. Preserve the project's confinement and identity checks around file mutation.
- Keep tool paths relative to the current context when the tool contract requires it. Do not substitute a drive, provider, traversal path or network path.
- Guard platform-specific clipboard, terminal and filesystem APIs behind small seams.
