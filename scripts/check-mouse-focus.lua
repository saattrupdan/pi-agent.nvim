local root = vim.fn.getcwd()
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fake = tmp .. "/fake-pi"
vim.fn.writefile({
  "#!/bin/sh",
  "i=1; while [ $i -le 80 ]; do printf 'history-%s\\n' \"$i\"; i=$((i + 1)); done",
  "while IFS= read -r line; do printf 'received:%s\\n' \"$line\"; done",
}, fake)
vim.fn.setfperm(fake, "rwx------")

local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-n" }, { rpc = true })

local function remote(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end

local function assert_true(value, label)
  if not value then
    error(label)
  end
end

local function wait_for(predicate, label)
  assert_true(vim.wait(3000, predicate, 10), "timed out waiting for " .. label)
end

local function mode()
  return vim.rpcrequest(child, "nvim_get_mode").mode
end

local function click(win, row, col)
  local pos = vim.rpcrequest(child, "nvim_win_get_position", win)
  vim.rpcrequest(child, "nvim_input_mouse", "left", "press", "", 0, pos[1] + (row or 2), pos[2] + (col or 2))
  vim.wait(30)
  vim.rpcrequest(child, "nvim_input_mouse", "left", "release", "", 0, pos[1] + (row or 2), pos[2] + (col or 2))
  vim.wait(30)
end

local function current_win()
  return vim.rpcrequest(child, "nvim_get_current_win")
end

local function assert_active(win)
  assert_true(remote([[return vim.wo[...].winhighlight:find("PiAgentActiveBorder", 1, true) ~= nil]], win),
    "clicked pane has the active border")
end

local ok, err = xpcall(function()
  vim.rpcrequest(child, "nvim_ui_attach", 120, 50, { rgb = true })
  remote([[
    local root, tmp, fake = ...
    vim.o.columns = 120
    vim.o.lines = 50
    vim.o.mouse = "a"
    vim.o.mousetime = 0
    vim.env.TERM_PROGRAM = nil
    vim.env.ITERM_SESSION_ID = nil
    vim.env.PI_CODING_AGENT_DIR = tmp
    vim.env.PI_CODING_AGENT_SESSION_DIR = tmp .. "/sessions"
    vim.opt.rtp:prepend(root)
    vim.keymap.set("t", "<LeftMouse>", "global-click")
    local pi = require("pi-agent")
    pi.setup({ command = fake, keymap = false, abort_keymap = false })
    pi.open()
  ]], root, tmp, fake)
  wait_for(function() return mode() == "t" end, "first terminal input")
  local first = current_win()
  local base = remote([[for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= vim.api.nvim_get_current_win() then return w end
  end]])
  remote([[require("pi-agent").split()]])
  wait_for(function() return mode() == "t" and vim.rpcrequest(child, "nvim_get_current_win") ~= first end,
    "second terminal input")
  local second = current_win()
  local mapping = remote([[local m = vim.fn.maparg("<LeftMouse>", "t", false, true)
    return { buffer = m.buffer, expr = m.expr }]])
  assert_true(mapping.buffer == 1 and mapping.expr == 1, "click mapping is buffer-local and expression-based")
  assert_true(remote([[return vim.fn.maparg("<LeftMouse>", "n", false, true).buffer]]) == 1,
    "normal click mapping is buffer-local")

  click(first)
  wait_for(function() return current_win() == first and mode() == "t" end, "click focus with input active")
  assert_active(first)
  vim.rpcrequest(child, "nvim_input", "clicked-first<CR>")
  wait_for(function()
    return remote([[for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line:find("received:clicked-first", 1, true) then return true end
    end; return false]])
  end, "typing reaches clicked Pi job")
  click(second)
  wait_for(function() return current_win() == second and mode() == "t" end, "click back with input active")
  assert_active(second)

  -- A third pane exercises clicks across both rows and columns.
  vim.rpcrequest(child, "nvim_input", "<C-s>")
  wait_for(function() return current_win() ~= second and mode() == "t" end, "third terminal input")
  local third = current_win()
  click(first)
  wait_for(function() return current_win() == first and mode() == "t" end, "click across layout")
  click(third)
  wait_for(function() return current_win() == third and mode() == "t" end, "click vertically split pane")

  vim.rpcrequest(child, "nvim_input", "<C-\\><C-n>")
  wait_for(function() return mode():match("^n") end, "normal-mode scrollback")
  click(first)
  wait_for(function() return current_win() == first and mode() == "t" end, "normal-mode click focus")
  assert_active(first)
  click(first)
  wait_for(function() return mode():match("^n") end, "same-pane click retains native behavior")
  local pos = vim.rpcrequest(child, "nvim_win_get_position", first)
  vim.rpcrequest(child, "nvim_input_mouse", "left", "press", "", 0, pos[1] + 2, pos[2] + 2)
  vim.wait(30)
  vim.rpcrequest(child, "nvim_input_mouse", "left", "drag", "", 0, pos[1] + 3, pos[2] + 8)
  vim.wait(30)
  vim.rpcrequest(child, "nvim_input_mouse", "left", "release", "", 0, pos[1] + 3, pos[2] + 8)
  wait_for(function() return mode() == "v" end, "native same-pane drag selection")
  vim.rpcrequest(child, "nvim_input", "<Esc>")
  wait_for(function() return mode():match("^n") end, "leave selection")

  vim.rpcrequest(child, "nvim_input", "i")
  wait_for(function() return mode() == "t" end, "input before ordinary-window click")
  click(base, 0, 0)
  wait_for(function() return current_win() == base end, "click ordinary window")
  assert_true(mode():match("^n"), "ordinary-window click does not start insert mode")
  assert_true(remote([[return vim.fn.maparg("<LeftMouse>", "t")]]) == "global-click", "global mapping is untouched")
  remote([[require("pi-agent").open()]])
  wait_for(function() return mode() == "t" end, "reopen Pi input")
  click(second)
  wait_for(function() return current_win() == second and mode() == "t" end, "focus before hide")
  local clicked_buf = vim.rpcrequest(child, "nvim_win_get_buf", second)
  remote([[require("pi-agent").close(); require("pi-agent").open()]])
  wait_for(function() return mode() == "t" end, "input after toggle")
  assert_true(current_win() ~= base, "toggle restores a Pi pane")
  assert_true(vim.rpcrequest(child, "nvim_get_current_buf") == clicked_buf,
    "toggle restores the clicked session")
end, debug.traceback)

if vim.fn.jobwait({ child }, 0)[1] == -1 then
  pcall(vim.rpcnotify, child, "nvim_command", "qa!")
  if vim.fn.jobwait({ child }, 3000)[1] == -1 then
    vim.fn.jobstop(child)
  end
end
vim.fn.delete(tmp, "rf")
if not ok then
  print(err)
  os.exit(1)
end
print("Pi pane clicks preserve input mode and native normal-mode behavior.")
vim.cmd("qa!")
