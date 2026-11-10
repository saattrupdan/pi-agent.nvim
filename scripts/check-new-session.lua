local root = vim.fn.getcwd()
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fake = tmp .. "/fake-pi"
vim.fn.writefile({
  "#!/bin/sh",
  "printf 'conversation history\\n'",
  "printf 'context [██████░░░░] 60%%  session [████████░░] 80%%  weekly [████░░░░░░] 40%%\\n'",
  "while IFS= read -r line; do",
  "  [ \"$line\" = exit ] && exit 0",
  "  printf 'received:%s\\n' \"$line\"",
  "  if [ \"$line\" = show-splash ]; then printf '\\033[2J\\033[H  ██████████████████      \\n  ██████      ██████      \\n'; fi",
  "  if [ \"$line\" = show-history ]; then i=0; while [ \"$i\" -lt 80 ]; do printf 'history row %s\\n' \"$i\"; i=$((i + 1)); done; fi",
  "done",
}, fake)
vim.fn.setfperm(fake, "rwx------")

local stderr = {}
local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-n" }, {
  rpc = true,
  on_stderr = function(_, lines)
    vim.list_extend(stderr, lines)
  end,
})

local function remote(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end

local function mode()
  return vim.rpcrequest(child, "nvim_get_mode")
end

local function wait_for(predicate, label)
  assert(vim.wait(3000, predicate, 10), "timed out waiting for " .. label)
end

local function input(keys)
  vim.rpcrequest(child, "nvim_input", keys)
end

local function received(command)
  return remote([[local command = ...
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line:find("received:" .. command, 1, true) then return true end
    end
    return false]], command)
end

local ok, err = xpcall(function()
  vim.rpcrequest(child, "nvim_ui_attach", 120, 50, { rgb = true })
  remote([[
    local root, tmp, fake = ...
    vim.env.TERM_PROGRAM = nil
    vim.env.ITERM_SESSION_ID = nil
    vim.env.PI_CODING_AGENT_DIR = tmp
    vim.env.PI_CODING_AGENT_SESSION_DIR = tmp .. "/sessions"
    vim.opt.rtp:prepend(root)
    require("pi-agent").setup({ command = fake, keymap = false, abort_keymap = false })
    require("pi-agent").open()
  ]], root, tmp, fake)
  wait_for(function() return mode().mode == "t" end, "Pi input")
  wait_for(function()
    return remote([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      :find("weekly [████░░░░░░] 40%", 1, true) ~= nil]])
  end, "conversation history with filled usage bars")

  input("<C-l>")
  wait_for(function() return mode().mode:match("^r") end, "cancel confirmation")
  input("n")
  wait_for(function() return mode().mode == "t" end, "Pi input after cancel")
  input("after-cancel<CR>")
  wait_for(function() return received("after-cancel") end, "input after cancel")
  assert(not received("/new") and not received("/reload"), "cancel must not reset Pi")

  input("<C-l>")
  wait_for(function() return mode().mode:match("^r") end, "reset confirmation")
  input("<CR>")
  wait_for(function() return received("/new") end, "/new after confirmation")
  wait_for(function() return mode().mode == "t" end, "Pi input after reset")
  assert(not received("/reload"), "history must not reload instead of starting a new session")

  input("show-splash<CR>")
  wait_for(function()
    return remote([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      :find("██████████████████", 1, true) ~= nil]])
  end, "fresh splash")
  input("<C-l>")
  wait_for(function() return received("/reload") end, "fresh splash reload without confirmation")
  assert(mode().mode == "t", "fresh splash stays in terminal input")

  input("show-history<CR>")
  wait_for(function() return received("show-history") end, "history after splash")
  wait_for(function()
    return remote([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      :find("history row 79", 1, true) ~= nil]])
  end, "splash scrolled out of live screen")
  input("<C-l>")
  wait_for(function() return mode().mode:match("^r") end, "confirmation with splash in scrollback")
  input("y")
  wait_for(function() return received("/new") end, "/new with splash in scrollback")
  wait_for(function() return mode().mode == "t" end, "Pi input after second reset")
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
  print(table.concat(stderr, "\n"))
  vim.cmd("cquit 1")
end
print("Ctrl+L confirms and sends /new for conversation history.")
vim.cmd("qa!")
