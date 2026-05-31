# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Floating Pi area now supports multiple live terminal sessions in tiled panes:
  `<C-s>` splits the current pane, `<C-d>` closes the current pane/session, and
  `<C-w>h/j/k/l` plus `<C-w><C-w>` navigate among visible Pi panes with
  buffer-local mappings.

- Yanks from the agent buffer are post-processed via `TextYankPost`: each
  line has terminal padding, box-drawing vertical glyphs (`│ ┃ ║ ╽ ╿ ▏ ▕ ╎
  ╏ ┆ ┇ ┊ ┋ |`), and the input-box `>` prompt stripped from its edges;
  border-only lines (`┌─┐`, `└─┘`, etc.) are dropped; leading and trailing
  blank lines are removed. The on-screen visual highlight is unchanged —
  only the register contents are cleaned, so the UI is never touched.

### Changed

- Floating Pi area now defaults to 80% × 80% of the editor and rerenders its
  pane layout when Neovim is resized.
- Terminal buffer no longer forces insert mode on open — vim commands work
  immediately. Press `<CR>` in terminal mode to return to insert mode.

### Fixed

- Splitting the original left pane after splitting the right pane now correctly
  creates a top/bottom split instead of falling back to a full-width layout.
- Multi-pane splitting now uses layout-derived pane rectangles and visual aspect
  ratio, so full-width panes split side-by-side while half-width portrait panes
  split top/bottom.
- Directional pane navigation now ranks layout edges and overlapping ranges, so
  up/down moves to the spatial pane directly above/below instead of an unrelated
  left-most pane.
- The active Pi pane is highlighted when multiple panes are visible, including
  after focus changes, splits, closes, and layout rerenders.
- Pane navigation from terminal mode now lands in the destination Pi pane and
  returns to terminal mode; navigation from normal mode stays in normal mode.
- Streaming output no longer jumps the floating terminal away from the
  conversation history when browsing scrollback in normal mode.

## [0.1.0] - 2026-05-23

### Added

- Floating terminal window that runs the `pi` CLI, sized at 70% × 70% of the editor by default.
- Automatic `cd` into the git root of the current buffer, falling back to `cwd` when not in a git worktree.
- `:PiAgent`, `:PiAgentOpen`, and `:PiAgentClose` user commands.
- Default `<C-,>` toggle keymap in normal and terminal modes, configurable via `keymap` (set to `false`/`""` to disable).
- `abort_keymap` option (default `<C-c>`) that sends `<Esc>` to Pi to abort the current run without leaving terminal mode.
- `<C-o>` is forwarded to Pi inside the agent buffer so a global tmap can't swallow Pi's detailed-tool-output toggle.
- `ExitPre` autocmd that stops the agent job on `:wqa` / `:qa` so Neovim doesn't raise `E947`.

[0.1.0]: https://github.com/saattrupdan/pi-agent.nvim/releases/tag/v0.1.0
