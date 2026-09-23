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

local function frame_geometry(win, top, bottom, left, right)
  return {
    left = win.col,
    right = win.col + win.width + left + right,
    top = win.row,
    bottom = win.row + win.height + top + bottom,
  }
end

local function assert_frame_geometry(wins, top, bottom, left, right)
  top, bottom, left, right = top or 1, bottom or 1, left or 1, right or 1
  local frames = {}
  for index, win in ipairs(wins) do
    frames[index] = frame_geometry(win, top, bottom, left, right)
  end

  for first = 1, #frames do
    for second = first + 1, #frames do
      local a = frames[first]
      local b = frames[second]
      local horizontal_overlap = math.min(a.right, b.right) - math.max(a.left, b.left)
      local vertical_overlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top)
      assert_eq(horizontal_overlap > 0 and vertical_overlap > 0, false,
        string.format("frames %d and %d overlap", first, second))
    end
  end
end

local function assert_bounded_geometry(wins, top, bottom, left, right)
  for index, win in ipairs(wins) do
    local frame = frame_geometry(win, top, bottom, left, right)
    assert_eq(frame.left >= 0 and frame.right <= vim.o.columns, true,
      string.format("frame %d exceeds editor width", index))
    assert_eq(frame.top >= 0 and frame.bottom <= vim.o.lines - vim.o.cmdheight, true,
      string.format("frame %d exceeds editor height", index))
  end
  assert_frame_geometry(wins, top, bottom, left, right)
end

local function rerender_with_border(border, top, bottom, left, right)
  pi.config.border = border
  vim.api.nvim_exec_autocmds("VimResized", {})
  local wins = pi_windows()
  assert_frame_geometry(wins, top, bottom, left, right)

  -- Changing focus must not change a pane's allocation. In particular, the
  -- inactive replacement border must have the same asymmetric extents.
  local allocations = {}
  for index, win in ipairs(wins) do
    allocations[index] = { width = win.width, height = win.height }
    vim.api.nvim_set_current_win(win.win)
  end
  wins = pi_windows()
  for index, win in ipairs(wins) do
    assert_eq(win.width, allocations[index].width, "focus changed width")
    assert_eq(win.height, allocations[index].height, "focus changed height")
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
    border = "single",
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
    { col = 20, row = 23, width = 77, height = 13 },
    { col = 20, row = 39, width = 77, height = 14 },
    { col = 100, row = 23, width = 78, height = 13 },
    { col = 100, row = 39, width = 78, height = 14 },
  }

  for index, want in ipairs(expected) do
    local got = wins[index]
    assert_eq(got.col, want.col, "window " .. index .. " col")
    assert_eq(got.row, want.row, "window " .. index .. " row")
    assert_eq(got.width, want.width, "window " .. index .. " width")
    assert_eq(got.height, want.height, "window " .. index .. " height")
  end
  assert_frame_geometry(wins)
  -- The default one-cell pane gap is measured between complete frames, so
  -- border titles cannot overlap neighboring panes.
  assert_eq(wins[2].row, wins[1].row + wins[1].height + 3, "left pane gap")
  assert_eq(wins[4].row, wins[3].row + wins[3].height + 3, "right pane gap")
  assert_eq(wins[3].col, wins[1].col + wins[1].width + 3, "top pane gap")
  assert_eq(wins[4].col, wins[2].col + wins[2].width + 3, "bottom pane gap")

  -- Focus changes must preserve the frame allocation, not just its content.
  rerender_with_border("single", 1, 1, 1, 1)

  -- Named shadow occupies only its right and bottom cells.
  rerender_with_border("shadow", 0, 1, 0, 1)

  -- Custom borders can be asymmetric; this one has only top and left edges.
  rerender_with_border({ "╭", "─", "╮", "", "", "", "", "│" }, 1, 0, 1, 0)

  -- Both spellings are borderless in Neovim.
  rerender_with_border("none", 0, 0, 0, 0)
  rerender_with_border("", 0, 0, 0, 0)

  -- Force a nested layout into a smaller editor. Gaps are allowed to shrink,
  -- but allocations and coordinates must remain inside the editor.
  vim.o.columns = 8
  vim.o.lines = 8
  pi.config.border = "single"
  pi.config.pane_gap = 3
  vim.api.nvim_exec_autocmds("VimResized", {})
  assert_bounded_geometry(pi_windows(), 1, 1, 1, 1)
end

local ok, err = xpcall(run, debug.traceback)
vim.cmd("stopinsert")
if not ok then
  print(err)
  os.exit(1)
end
os.exit(0)
