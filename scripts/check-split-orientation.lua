vim.o.columns = 200
vim.o.lines = 80

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")

local function pi_windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative == "editor" then
      table.insert(wins, {
        win = win,
        row = config.row,
        col = config.col,
        width = config.width,
        height = config.height,
      })
    end
  end
  table.sort(wins, function(a, b)
    if a.col == b.col then
      return a.row < b.row
    end
    return a.col < b.col
  end)
  return wins
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, expected, actual), 2)
  end
end

local function wait_for_windows(count)
  local ok = vim.wait(1000, function()
    return #pi_windows() == count
  end, 10)
  if not ok then
    error(string.format("expected %d Pi windows, got %d", count, #pi_windows()))
  end
end

local function run()
  pi.setup({
    command = "cat",
    width = 0.8,
    height = 0.4,
    border = "none",
    keymap = false,
    abort_keymap = false,
  })

  pi.open()
  wait_for_windows(1)

  pi.split()
  wait_for_windows(2)

  pi.split()
  wait_for_windows(3)

  local wins = pi_windows()
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(wins[1].win)
  pi.split()
  wait_for_windows(4)

  wins = pi_windows()
  -- A shallow layout keeps vertical halves landscape by aspect, so the
  -- final split must use parent context to produce a top/bottom grid.
  local expected = {
    { col = 20, row = 24, width = 79, height = 15 },
    { col = 20, row = 40, width = 79, height = 16 },
    { col = 100, row = 24, width = 80, height = 15 },
    { col = 100, row = 40, width = 80, height = 16 },
  }

  for index, want in ipairs(expected) do
    local got = wins[index]
    assert_eq(got.col, want.col, "window " .. index .. " col")
    assert_eq(got.row, want.row, "window " .. index .. " row")
    assert_eq(got.width, want.width, "window " .. index .. " width")
    assert_eq(got.height, want.height, "window " .. index .. " height")
  end
end

local ok, err = xpcall(run, debug.traceback)
vim.cmd("stopinsert")
if not ok then
  print(err)
  os.exit(1)
end
os.exit(0)
