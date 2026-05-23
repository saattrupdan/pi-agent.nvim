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
  command = "pi",     -- command to run in the floating terminal
  width   = 0.7,      -- fraction of editor width
  height  = 0.7,      -- fraction of editor height
  border  = "rounded",-- any value accepted by nvim_open_win
})
```

## Usage

| Command         | Description                              |
| --------------- | ---------------------------------------- |
| `:PiAgent`      | Toggle the floating Pi agent window      |
| `:PiAgentOpen`  | Open (or focus) the floating window      |
| `:PiAgentClose` | Hide the floating window                 |

Suggested keymaps:

```lua
vim.keymap.set("n", "<leader>pi", "<cmd>PiAgent<CR>", { desc = "Toggle Pi agent" })
vim.keymap.set("t", "<C-;>", [[<C-\><C-n><cmd>PiAgent<CR>]], { desc = "Toggle Pi agent" })
```

## How it works

When you open the window, the plugin runs `git -C <cwd> rev-parse --show-toplevel`. If that succeeds, the floating terminal is launched in the repo root; otherwise it uses the current working directory. The buffer is kept around between toggles, so closing the window doesn't kill your `pi` session — only exiting `pi` itself does.

## License

MIT
