vim.o.columns = 100
vim.o.lines = 40
vim.o.scrolloff = 30

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")
local fake_pi = vim.fn.tempname()
local script = { "#!/bin/sh" }
for i = 1, 80 do
  table.insert(script, string.format("printf 'initial-%03d\\n' %d", i, i))
end
table.insert(script, "while IFS= read -r command; do printf 'stream-%s\\n' \"$command\"; done")
vim.fn.writefile(script, fake_pi)
vim.fn.setfperm(fake_pi, "rwx------")

local function assert_true(value, label)
  if not value then
    error("assertion failed: " .. label)
  end
end

local function wait_for(predicate, label)
  assert_true(vim.wait(3000, predicate, 10), "timed out waiting for " .. label)
end

local function session_buffer()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ok, value = pcall(vim.api.nvim_buf_get_var, buf, "pi_agent_session")
    if ok and value then
      return buf
    end
  end
end

local ok, err = xpcall(function()
  pi.setup({ command = fake_pi, width = 0.8, height = 0.6, keymap = false, abort_keymap = false })
  local base_win = vim.api.nvim_get_current_win()
  pi.open()
  wait_for(function()
    return session_buffer() ~= nil
  end, "terminal startup")
  local buf = session_buffer()
  local win
  wait_for(function()
    for _, candidate in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(candidate) == buf then
        win = candidate
        return true
      end
    end
    return false
  end, "Pi window")
  wait_for(function()
    return vim.api.nvim_buf_line_count(buf) >= 80
  end, "initial terminal output")

  local wheel_down = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
  end)
  assert_true(type(wheel_down.callback) == "function", "normal-mode wheel is mapped in the Pi pane")
  assert_true(vim.wo[base_win].scrolloff == 30, "ordinary window keeps global scrolloff")
  local tops = vim.api.nvim_win_call(win, function()
    local height = vim.api.nvim_win_get_height(win)
    local center = 20 + math.floor(height / 2)
    vim.fn.winrestview({ topline = 20, lnum = center, col = 0 })
    local before = vim.fn.winsaveview().topline
    vim.cmd("normal! 8k")
    local above = vim.fn.winsaveview().topline
    vim.fn.winrestview({ topline = 20, lnum = center, col = 0 })
    vim.cmd("normal! 8j")
    return { before, above, vim.fn.winsaveview().topline }
  end)
  assert_true(tops[2] < tops[1], "Pi scrolls as the cursor approaches the top half")
  assert_true(tops[3] > tops[1], "Pi scrolls as the cursor approaches the bottom half")
  assert_true(vim.wo[win].scrolloff == 30, "Pi pane inherits global scrolloff")
  local original_cmd = vim.cmd
  local terminal_returns = 0
  local scroll_attempts = 0
  vim.cmd = function(command)
    if command == "startinsert" then
      terminal_returns = terminal_returns + 1
    else
      if command:match("^normal!") then
        scroll_attempts = scroll_attempts + 1
      end
      original_cmd(command)
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 20, lnum = 25, col = 0 })
  end)
  wheel_down.callback()
  vim.wait(30)
  assert_true(terminal_returns == 0, "wheel-down stays in scrollback above the latest output")
  for _ = 1, 40 do
    wheel_down.callback()
    vim.wait(5)
    if terminal_returns > 0 then
      break
    end
  end
  assert_true(terminal_returns == 1, "wheel-down returns to terminal mode at the latest output")
  local attempts_at_bottom = scroll_attempts
  wheel_down.callback()
  vim.wait(30)
  assert_true(scroll_attempts == attempts_at_bottom, "normal-mode wheel does not scroll past the prompt")
  vim.cmd = original_cmd
  local bottom_top = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  local last_top = vim.api.nvim_buf_line_count(buf) - vim.api.nvim_win_get_height(win) + 1
  assert_true(bottom_top == last_top, "wheel-down stops at the last full screen")

  -- Wheel-down at the prompt is discarded before it can leave terminal mode.
  local wheel_down_terminal = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("<ScrollWheelDown>", "t", false, true)
  end)
  assert_true(wheel_down_terminal.buffer == 1, "terminal-mode wheel-down is buffer-local")
  assert_true(type(wheel_down_terminal.callback) == "function", "terminal-mode wheel-down checks the view")
  for _ = 1, 3 do
    assert_true(wheel_down_terminal.callback() == "", "wheel-down at the prompt is a no-op")
  end
  local wheel_up_terminal = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("<ScrollWheelUp>", "t", false, true)
  end)
  assert_true(wheel_up_terminal.buffer == 1, "terminal-mode wheel-up is buffer-local")
  assert_true(wheel_up_terminal.rhs == "<C-\\><C-n><ScrollWheelUp>", "wheel-up enters scrollback")
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 20, lnum = 25, col = 0 })
  end)
  assert_true(wheel_down_terminal.callback() == "<C-\\><C-n><ScrollWheelDown>",
    "wheel-down above the prompt enters scrollback")

  -- Headless Neovim cannot enter terminal-input mode; make the plugin observe
  -- terminal mode while testing wheel-scroll and streaming callbacks.
  local get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function() return { mode = "t" } end
  -- Simulate a user scrollback position, including the WinScrolled event Neovim
  -- emits for mouse-wheel scrolling in terminal mode.
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 20, lnum = 25, col = 0, curswant = 0 })
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win), modeline = false })
  vim.wait(30)
  local browsed_top = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  local job = vim.b[buf].terminal_job_id
  vim.api.nvim_chan_send(job, "one\r")
  wait_for(function()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find("stream%-one") then
        return true
      end
    end
    return false
  end, "streamed output")
  vim.wait(50)
  local after_stream = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  assert_true(after_stream == browsed_top, "streaming preserves manually browsed position")

  -- Returning the view to the bottom releases the browsing hold; the next
  -- output update should follow the newest line.
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = vim.fn.line("$") - vim.api.nvim_win_get_height(win) + 1 })
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win), modeline = false })
  vim.api.nvim_chan_send(job, "two\r")
  wait_for(function()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find("stream%-two") then
        return true
      end
    end
    return false
  end, "second streamed output")
  vim.wait(50)
  local bottom = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w$") >= vim.fn.line("$")
  end)
  assert_true(bottom, "output follows when browsing hold is released")
  vim.api.nvim_get_mode = get_mode

  pi.close()
  vim.cmd("qa!")
end, debug.traceback)

if not ok then
  print(err)
  os.exit(1)
end
