# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `trim_yank` now strips all leading whitespace per line (instead of common
  indent) and detects/skips splash screen border lines (box-drawing Unicode,
  ASCII borders, `>` prompt) from yanked content.
- Terminal buffer no longer forces insert mode on open — vim commands work
  immediately. Press `<CR>` in terminal mode to return to insert mode.

## [0.1.0] - 2026-05-23

### Added

- Floating terminal window that runs the `pi` CLI, sized at 70% × 70% of the editor by default.
- Automatic `cd` into the git root of the current buffer, falling back to `cwd` when not in a git worktree.
- `:PiAgent`, `:PiAgentOpen`, and `:PiAgentClose` user commands.
- Default `<C-,>` toggle keymap in normal and terminal modes, configurable via `keymap` (set to `false`/`""` to disable).
- `trim_yank` option (default `true`) that strips trailing terminal padding, the common leading indent, and surrounding blank lines from yanks in the agent buffer.
- `abort_keymap` option (default `<C-c>`) that sends `<Esc>` to Pi to abort the current run without leaving terminal mode.
- `<C-o>` is forwarded to Pi inside the agent buffer so a global tmap can't swallow Pi's detailed-tool-output toggle.
- `ExitPre` autocmd that stops the agent job on `:wqa` / `:qa` so Neovim doesn't raise `E947`.

[0.1.0]: https://github.com/saattrupdan/pi-agent.nvim/releases/tag/v0.1.0
