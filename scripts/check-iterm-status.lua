vim.o.columns = 120
vim.o.lines = 50

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")
local fake_pi = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  'printf idle > "$PI_AGENT_STATUS_FILE"',
  'completed=0',
  'while IFS= read -r command; do',
  '  case "$command" in',
  '    *need*) printf need_input > "$PI_AGENT_STATUS_FILE" ;;',
  '    *work*) printf working > "$PI_AGENT_STATUS_FILE" ;;',
  '    *reset*) completed=0; printf working > "$PI_AGENT_STATUS_FILE" ;;',
  '    *finish*) completed=$((completed + 1)); printf "finished:%s" "$completed" > "$PI_AGENT_STATUS_FILE" ;;',
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

local function last_status_output()
  for i = #output, 1, -1 do
    if output[i]:find("\27]21337;status=", 1, true) then
      return output[i]
    end
  end
  return ""
end

local function status()
  return last_status_output():match("\27%]21337;status=([^;]*);")
end

local function marker()
  local encoded = (output[#output] or ""):match("SetUserVar=pi_agent_sort_status=([^\7]*)")
  assert_true(encoded ~= nil, "Pi marker accompanies status")
  return vim.fn.system({ "base64", "-D" }, encoded)
end

local function send(buf, command)
  vim.api.nvim_chan_send(vim.b[buf].terminal_job_id, command .. "\n")
end

local ok, err = xpcall(function()
  pi.setup({ command = fake_pi, keymap = false })
  assert_true(#output == 0, "ordinary Neovim does not publish a Pi marker")
  pi.open()
  local first = vim.api.nvim_get_current_buf()
  assert_true(status() == "Idle", "new Pi pane is idle before its first response")
  assert_true(output[1]:sub(1, 8) == "\27]21337;", "status precedes permission-gated icon update")
  assert_true(output[1]:find("SetProfileProperty=Icon=Mg==;Custom Icon Path=", 1, true), "Pi icon installed")
  local encoded_icon = output[1]:match("Custom Icon Path=([^\7]+)")
  local icon_path = vim.json.decode(vim.fn.system({ "base64", "-D" }, encoded_icon))
  assert_true(icon_path == root .. "/media/pi-tab-icon.png", "icon uses bundled Pi logo")
  assert_true(output[1]:find("indicator=;status-color=", 1, true), "initial idle has no colored dot")
  local initial_expiry = tonumber(marker():match("^idle:(%d+)$"))
  assert_true(initial_expiry ~= nil, "Pi marker starts idle")
  assert_true(vim.wait(6500, function()
    return tonumber(marker():match("^idle:(%d+)$")) > initial_expiry
  end, 100), "Pi marker renews while idle")
  assert_true(status() == "Idle", "marker renewal leaves the visible status alone")

  pi.split()
  local second = vim.api.nvim_get_current_buf()
  assert_true(first ~= second, "independent Pi sessions")
  wait_for(function() return status() == "Idle" end, "both idle")
  send(first, "work")
  wait_for(function() return status() == "Working" end, "one working")
  assert_true(not output[#output]:find("SetProfileProperty", 1, true), "icon set only once")
  send(second, "need")
  wait_for(function() return status() == "Need input" end, "input takes priority")
  assert_true(output[#output]:find("indicator=#ff453a", 1, true), "input indicator color")
  send(second, "idle")
  wait_for(function() return status() == "Working" end, "working after input resolves")

  pi.close()
  send(first, "finish")
  wait_for(function() return status() == "Idle" end, "completion in active tab stays idle")
  send(first, "reset")
  wait_for(function() return status() == "Working" end, "handoff continues working")
  send(first, "finish")
  wait_for(function() return status() == "Idle" end, "completion after handoff reuses its counter")
  pi.open()
  assert_true(status() == "Idle", "reopening keeps aggregate state")

  send(first, "work")
  wait_for(function() return status() == "Working" end, "new response starts working")
  vim.api.nvim_exec_autocmds("FocusLost", {})
  send(first, "finish")
  wait_for(function() return status() == "Finished" end, "background completion is finished")
  assert_true(last_status_output():find("indicator=#30d158", 1, true), "only finished has green dot")
  assert_true(marker():match("^finished:%d+$") ~= nil, "Pi marker tracks finished")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert_true(status() == "Idle", "selecting finished tab acknowledges completion")
  assert_true(last_status_output():find("indicator=;status-color=", 1, true), "acknowledged idle has no dot")
  vim.wait(700)
  assert_true(status() == "Idle", "acknowledged completion does not reappear on poll")

  send(first, "work")
  wait_for(function() return status() == "Working" end, "subsequent response starts working")
  vim.api.nvim_exec_autocmds("FocusLost", {})
  send(first, "finish")
  wait_for(function() return status() == "Finished" end, "subsequent background completion is distinct")
  send(second, "work")
  wait_for(function() return status() == "Working" end, "working outranks another finished pane")
  send(second, "finish")
  wait_for(function() return status() == "Finished" end, "multiple completed panes aggregate as finished")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert_true(status() == "Idle", "tab activation acknowledges all completed panes")

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
  assert_true(marker() == "", "Pi marker cleared with final pane")

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
