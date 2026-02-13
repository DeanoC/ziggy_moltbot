Work item 20a: polish terminal Markdown rendering for CLI help output.

- Render inline Markdown links as their label text (e.g. `[label](url)` → `label`) so embedded docs/links read cleanly in terminal help.
- Added a unit test covering link stripping in plain mode.

Rendering still honors tty/NO_COLOR/CLICOLOR and the `ZSC_HELP_MARKDOWN=ansi|plain` override.
