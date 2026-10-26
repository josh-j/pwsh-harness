---
name: module-authoring
description: Organize PowerShell module source and validate public APIs. Use when changing module layout, exports or loading behavior.
---
# PowerShell module source

Read the existing layout and nearby public APIs before extending a module.

- Keep reusable public functions separate from private implementation where the project does so.
- Use approved verbs, meaningful names and the project's help style. Keep the public surface small.
- Load companion source from a captured script directory rather than the caller's working directory.
- Preserve unrelated comments and source structure. When changing a function signature, find and update its callers.
- Choose exports deliberately and test the public API through a fresh process.
- Treat local data files as data; use a literal data reader instead of evaluating their contents.
- Test loading from another working directory and, when relevant, from the packaged layout.
- Preserve encoding and line endings when changing existing files.

Run the related tests and static analysis before reporting the change as complete.
