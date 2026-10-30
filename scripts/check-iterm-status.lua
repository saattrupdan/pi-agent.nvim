vim.o.columns = 120
vim.o.lines = 50

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")
local fake_pi = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  'printf idle > "$PI_AGENT_STATUS_FILE"',
  'while IFS= read -r command; do',
  '  case "$command" in',
  '    *need*) printf need_input > "$PI_AGENT_STATUS_FILE" ;;',
  '    *work*) printf working > "$PI_AGENT_STATUS_FILE" ;;',
  '    *idle*) printf idle > "$PI_AGENT_STATUS_FILE" ;;',
  '    *fail*) exit 17 ;;',
  '  esac',
  'done',
}, fake_pi)
vim.fn.setfperm(fake_pi, "rwx------")

local previous_term = vim.env.TERM_PROGRAM
local previous_id = vim.env.ITERM_SESSION_ID
local previous_tmux = vim.env.TMUX
vim.env.TMUX = nil
vim.env.TERM_PROGRAM = "iTerm.app"
vim.env.ITERM_SESSION_ID = "test-iterm-session"
local original_stdout = io.stdout
local original_list_uis = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function() return { { chan = 1 } } end
local output = {}
io.stdout = {
  write = function(_, text) table.insert(output, text); return true end,
  flush = function() return true end,
}

local function assert_true(value, label)
  if not value then error("assertion failed: " .. label) end
end

local function wait_for(predicate, label)
  assert_true(vim.wait(3500, predicate, 20), "timed out waiting for " .. label)
end

local function status()
  return (output[#output] or ""):match("\27%]21337;status=([^;]*);")
end

local function send(buf, command)
  vim.api.nvim_chan_send(vim.b[buf].terminal_job_id, command .. "\n")
end

local ok, err = xpcall(function()
  pi.setup({ command = fake_pi, keymap = false })
  pi.open()
  local first = vim.api.nvim_get_current_buf()
  assert_true(status() == "Starting", "first Pi pane starts iTerm status")
  assert_true(output[1]:sub(1, 8) == "\27]21337;", "status precedes permission-gated icon update")
  assert_true(output[1]:find("SetProfileProperty=Icon=Mg==;Custom Icon Path=", 1, true), "Pi icon installed")
  local encoded_icon = output[1]:match("Custom Icon Path=([^\7]+)")
  local icon_path = vim.json.decode(vim.fn.system({ "base64", "-D" }, encoded_icon))
  assert_true(icon_path == root .. "/media/pi-tab-icon.png", "icon uses bundled Pi logo")
  assert_true(output[1]:find("status%-color=#8e8e93") ~= nil, "starting color")
  wait_for(function() return status() == "Idle" end, "first Pi idle")
  assert_true(not output[#output]:find("SetProfileProperty", 1, true), "icon set only once")

  pi.split()
  local second = vim.api.nvim_get_current_buf()
  assert_true(first ~= second, "independent Pi sessions")
  wait_for(function() return status() == "Idle" end, "both idle")
  send(first, "work")
  wait_for(function() return status() == "Working" end, "one working")
  send(second, "need")
  wait_for(function() return status() == "Need input" end, "input takes priority")
  assert_true(output[#output]:find("indicator=#ff453a", 1, true), "input indicator color")
  send(second, "idle")
  wait_for(function() return status() == "Working" end, "working after input resolves")

  pi.close()
  send(first, "idle")
  wait_for(function() return status() == "Idle" end, "hidden panes keep status current")
  pi.open()
  assert_true(status() == "Idle", "reopening keeps aggregate state")

  send(first, "fail")
  wait_for(function() return status() == "Error" end, "failed Pi pane")
  send(second, "work")
  wait_for(function() return status() == "Working" end, "working outranks failed pane")
  local confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  pi.close_pane()
  assert_true(status() == "Error", "remaining failed pane status")
  pi.close_pane()
  vim.fn.confirm = confirm
  assert_true(status() == "", "status cleared after final pane")
  assert_true(output[#output]:sub(1, 8) == "\27]21337;", "clear precedes permission-gated icon reset")
  assert_true(output[#output]:find("SetProfileProperty=Icon=MQ==", 1, true), "automatic icon restored")

  vim.env.TERM_PROGRAM = "other-terminal"
  local count = #output
  pi.open()
  vim.fn.confirm = function() return 1 end
  pi.close_pane()
  vim.fn.confirm = confirm
  assert_true(#output == count, "other terminals receive no iTerm2 control sequences")
  vim.env.TERM_PROGRAM = "iTerm.app"
  vim.env.TMUX = "/tmp/test-tmux-socket,123,0"
  pi.open()
  vim.fn.confirm = function() return 1 end
  pi.close_pane()
  vim.fn.confirm = confirm
  assert_true(#output == count, "tmux does not receive direct iTerm2 control sequences")
  vim.env.TMUX = nil
  vim.api.nvim_list_uis = original_list_uis
  pi.open()
  vim.fn.confirm = function() return 1 end
  pi.close_pane()
  vim.fn.confirm = confirm
  assert_true(#output == count, "headless checks do not alter the enclosing iTerm2 tab")
end, debug.traceback)

io.stdout = original_stdout
vim.api.nvim_list_uis = original_list_uis
vim.env.TERM_PROGRAM = previous_term
vim.env.ITERM_SESSION_ID = previous_id
vim.env.TMUX = previous_tmux
pcall(vim.fn.delete, fake_pi)
if not ok then
  print(err)
  os.exit(1)
end
os.exit(0)
