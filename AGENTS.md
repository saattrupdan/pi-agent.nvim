# pi-agent.nvim

Neovim plugin that opens the `pi` CLI in a centered floating terminal, rooted at the current git repo. Single-file Lua plugin, no build step, no dependencies beyond Neovim 0.9+ and the `pi` binary on `$PATH`.

## Stack

- Lua, targeting Neovim 0.9+ (uses `vim.keymap.set`, `vim.api.nvim_open_win`, `vim.fn.termopen`).
- No package manager, no tests, no CI.

## Layout

- `lua/pi-agent/init.lua` — the entire plugin. `M.setup(opts)` is the entry point.
- `README.md` — user-facing docs.
- `CHANGELOG.md` — Keep a Changelog format, SemVer.

## Running it

There is no dev server. To exercise changes locally, point a Neovim config at the working tree, e.g. via lazy.nvim's `dir = "/path/to/pi-agent.nvim"`, then `:PiAgent`.

## Conventions

- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`). See `git log` for prior style.
- Every change is committed *and pushed* in the same step — see the user's memory note.
- Update `CHANGELOG.md` under `## [Unreleased]` for user-visible changes; cut a new version section on release.
- Keep comments minimal; prefer naming. Existing comments explain *why* (e.g. the `<C-o>` forward, the `ExitPre` hook).

## Gotchas

- **Single shared state.** `state` (buf/win/job) at the top of `init.lua` is module-level — the plugin assumes one Pi session at a time. Don't introduce a second concurrent session without rethinking it.
- **Buffer survives toggles.** `M.close` only closes the window; the terminal buffer and `pi` job stay alive so toggling preserves the session. The buffer is deleted only on `on_exit` or `ExitPre`.
- **`<C-,>` is terminal-dependent.** Many terminals don't transmit it as a distinct key. If a test of the default keymap "does nothing", it's the terminal, not the plugin.
- **Terminal-mode keymaps are buffer-local.** `<C-o>` forwarding and `abort_keymap` are set on `state.buf` only, so global tmaps don't get clobbered. Add new control-key forwards inside the same `if not buf_existed` block.
- **Abort sends literal `<Esc>`.** `abort_keymap` writes `"\27"` to the job channel — it does *not* send SIGINT. This is intentional: Pi's cancel key is `<Esc>`, and a real `<C-c>` would kill the CLI.
- **`trim_yank` rewrites registers.** The `TextYankPost` autocmd calls `setreg` on the unnamed and `0` registers after every yank in the agent buffer. If yanks elsewhere look wrong, confirm the autocmd is buffer-scoped (it is — don't change that).
- **`ExitPre` must stop the job.** Without it, `:wqa` raises `E947` because of the running terminal. Don't remove the autocmd in `M.setup`.
