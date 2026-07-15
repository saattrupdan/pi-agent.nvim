# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `keymap`, `abort_keymap`, and `new_session_keymap` now accept a table of
  strings in addition to a single string, allowing multiple keybindings — e.g.
  `{ "<C-,>", "<leader>cc" }` for tmux-compatible local + leader bindings.

- Active Pi pane now has a distinct background colour and inactive panes are
  slightly transparent (Neovim 0.10+), making the focused session more prominent
  in split view.

### Fixed

- Corrected vertical centering of the floating pane: the calculation now accounts
  for border rows and `cmdheight`, so the visual frame (border + content) is truly
  centered within the usable editor area.

- Pi pane titles now poll the session directory captured when each pane starts,
  so moving between buffers or repos cannot make split panes share or lose
  conversation names.
- Split-pane titles now follow their own Pi session files and continue polling
  for `/name` changes, instead of reusing whichever pane wrote most recently.
- Floating window height reduced by 1 line to give the Pi footer breathing room at the bottom.
- Buffer name collision error (`E95: Buffer with this name already exists`) when
  toggling with multiple split panes — buffer names now include the session ID
  to guarantee uniqueness.
- Buffer name now syncs with the conversation name, so `:ls` and bufferline
  plugins show the session title instead of a generic name.
- Each split pane now has its conversation name shown in the title — inactive
  panes now display the session title correctly instead of showing a generic
  title.
- Each split pane now has an independent Pi session with its own conversation
  title, instead of all panes sharing the same session name.
- Inactive Pi panes now follow their output: when a non-focused session emits
  new lines it scrolls to the bottom instead of jumping to the top. The focused
  pane keeps its browsing-view behaviour so scrolling back to read is preserved.
- Streaming output no longer auto-scrolls when browsing in normal mode: the
  cursor stays where you are instead of jumping to follow new output.
- `ctrl+l` on a fresh splash screen (no conversation history) no longer shows a
  black screen — it now just reloads extensions to reset the input box without
  sending `/new`, preserving the splash. With history, it still confirms before
  resetting.
- Pressing `V` (shift+v) now uses line-wise visual mode instead of character-wise,
  so extending the selection with `k`/`j` selects whole lines rather than a
  column-bounded range.

### Added

- `<C-l>` now asks for confirmation before sending `/new` to start a fresh
  session, preventing accidental resets. Default is Yes (press `<Enter>` to
  confirm). Configurable via `new_session_keymap`.
- `pane_gap` configures empty cells between tiled Pi panes, defaulting to one
  cell so active borders do not overlap adjacent panes.
- Floating Pi area now supports multiple live terminal sessions in tiled panes:
  `<C-s>` splits the current pane, `<C-x>` closes the current pane/session
  (after a one-key confirmation), and
  `<C-w>h/j/k/l` plus `<C-w><C-w>` navigate among visible Pi panes with
  buffer-local mappings.

- Yanks from the agent buffer are post-processed via `TextYankPost`: each
  line has terminal padding, box-drawing vertical glyphs (`│ ┃ ║ ╽ ╿ ▏ ▕ ╎
  ╏ ┆ ┇ ┊ ┋ |`), and the input-box `>` prompt stripped from its edges;
  border-only lines (`┌─┐`, `└─┘`, etc.) are dropped; leading and trailing
  blank lines are removed. The on-screen visual highlight is unchanged —
  only the register contents are cleaned, so the UI is never touched.

### Changed

- Floating Pi area now defaults to 95% × 95% of the editor (up from 80%) and
  rerenders its pane layout when Neovim is resized.
- Terminal buffer no longer forces insert mode on open — vim commands work
  immediately. Press `<CR>` in terminal mode to return to insert mode.
- Closed pane confirmation (`<C-x>`) now defaults to Yes (press `<Enter>` to
  confirm) instead of No.

### Fixed

- Splitting panes inside an existing left/right split now uses top/bottom splits
  for both first-level halves instead of creating extra side-by-side columns.
- Splitting the original left pane after splitting the right pane now correctly
  creates a top/bottom split instead of falling back to a full-width layout.
- Multi-pane splitting now uses layout-derived pane rectangles and contextual
  parent split orientation, so full-width panes split side-by-side while
  left/right child panes split top/bottom.
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
