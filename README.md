# pi-agent.nvim

A tiny Neovim plugin that opens your [Pi](https://github.com/) agent in a centered floating window, rooted at the current git repo (or `cwd` if there's no git worktree).

## Features

- Floating terminal window, 70% × 70% of the editor by default
- Automatically `cd`s into the git root of the current buffer, falling back to `cwd`
- Toggle in and out — the `pi` session persists across toggles until you exit it
- Configurable size, border, and command

## Requirements

- Neovim 0.9+
- The [`pi`](https://github.com/) CLI on your `$PATH`

## Installation

### lazy.nvim

```lua
return {
  "saattrupdan/pi-agent.nvim",
  config = function()
    require("pi-agent").setup()
  end,
}
```

### packer.nvim

```lua
use({
  "saattrupdan/pi-agent.nvim",
  config = function()
    require("pi-agent").setup()
  end,
})
```

## Configuration

The defaults:

```lua
require("pi-agent").setup({
  command = "pi",      -- command to run in the floating terminal
  width   = 0.7,       -- fraction of editor width
  height  = 0.7,       -- fraction of editor height
  border  = "rounded", -- any value accepted by nvim_open_win
  keymap  = "<C-,>",   -- toggle keymap (set to false or "" to disable)
  trim_yank = true,    -- strip terminal padding from yanks in the agent buffer
})
```

### Changing or disabling the default keymap

By default `<C-,>` toggles the window in both normal and terminal mode. To use a different binding, e.g. `<leader>pi`:

```lua
require("pi-agent").setup({ keymap = "<leader>pi" })
```

Any string accepted by `vim.keymap.set` works here — for example `"<leader>p"`, `"<F4>"`, or `"<C-g>p"`.

To disable the built-in keymap and define your own:

```lua
require("pi-agent").setup({ keymap = false })
vim.keymap.set("n", "<F4>", "<cmd>PiAgent<CR>", { desc = "Toggle Pi agent" })
```

> Note: some terminals don't transmit `<C-,>` as a distinct key. If pressing it does nothing, pick another binding or configure your terminal to send the right escape sequence (e.g. via Kitty/WezTerm key mappings).

## Usage

| Command         | Description                              |
| --------------- | ---------------------------------------- |
| `:PiAgent`      | Toggle the floating Pi agent window      |
| `:PiAgentOpen`  | Open (or focus) the floating window      |
| `:PiAgentClose` | Hide the floating window                 |

Default keymap: `<C-,>` toggles the window in normal and terminal modes. See [Configuration](#configuration) to change or disable it.

### Copying chat text

Terminal buffers pad every visible line with trailing spaces, and Pi's TUI indents messages with extra leading whitespace, so a naive yank pastes a wall of padding. With `trim_yank = true` (default), any yank inside the agent buffer is post-processed: trailing whitespace is stripped from each line, the common leading indent is removed, and surrounding blank lines are dropped. The usual flow — `<C-\><C-n>`, move up, `V` to select lines, `y` — produces clean text ready to paste elsewhere. Set `trim_yank = false` to opt out.

## How it works

When you open the window, the plugin runs `git -C <cwd> rev-parse --show-toplevel`. If that succeeds, the floating terminal is launched in the repo root; otherwise it uses the current working directory. The buffer is kept around between toggles, so closing the window doesn't kill your `pi` session — only exiting `pi` itself does.

## License

MIT
