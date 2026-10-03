vim.o.columns = 100
vim.o.lines = 40

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

  pi.close()
  vim.cmd("qa!")
end, debug.traceback)

if not ok then
  pcall(function() pi.close() end)
  pcall(vim.cmd, "qa!")
  error(err)
end
