vim.o.columns = 120
vim.o.lines = 50

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")
local fake_pi = vim.fn.tempname()
local status_paths = vim.fn.tempname()
vim.fn.mkdir(status_paths, "p")
vim.fn.writefile({
  "#!/bin/sh",
  'printf %s "$PI_AGENT_STATUS_FILE" > ' .. vim.fn.shellescape(status_paths) .. '/"$$"',
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

local function pane_window(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  error("pane is not visible")
end

local function focus(buf)
  vim.api.nvim_set_current_win(pane_window(buf))
end

local function title(buf)
  local chunks = vim.api.nvim_win_get_config(pane_window(buf)).title
  local parts = {}
  for _, chunk in ipairs(chunks) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
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

  send(first, "work")
  wait_for(function() return status() == "Working" end, "single-session working label")
  send(first, "finish")
  wait_for(function() return status() == "Idle" end, "focused completion is immediately seen")
  send(first, "work")
  wait_for(function() return status() == "Working" end, "response before leaving tab")
  local pid = vim.fn.jobpid(vim.b[first].terminal_job_id)
  local path = vim.fn.readfile(status_paths .. "/" .. pid)[1]
  vim.fn.writefile({ "finished:999" }, path)
  vim.api.nvim_exec_autocmds("FocusLost", {})
  assert_true(status() == "Idle", "completion just before focus loss was seen in outgoing pane")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  send(first, "reset")
  wait_for(function() return status() == "Working" end, "reset after direct completion write")
  send(first, "finish")
  wait_for(function() return status() == "Idle" end, "focused response after reset")

  local first_win = pane_window(first)
  local scratch = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(first_win, scratch)
  send(first, "work")
  wait_for(function() return status() == "Working" end, "work behind replacement buffer")
  send(first, "finish")
  wait_for(function() return status() == "Finished" end, "replacement buffer does not acknowledge hidden terminal")
  vim.api.nvim_win_set_buf(first_win, first)
  assert_true(status() == "Idle", "restoring actual terminal buffer acknowledges result")
  vim.api.nvim_buf_delete(scratch, { force = true })
  send(first, "work")
  wait_for(function() return status() == "Working" end, "single-session second response")
  vim.api.nvim_exec_autocmds("FocusLost", {})
  send(first, "finish")
  wait_for(function() return status() == "Finished" end, "single-session finished label")
  assert_true(title(first):find("● ", 1, true) == 1, "unseen completion marks pane title")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert_true(status() == "Idle", "returning to focused pane acknowledges its result")
  assert_true(not title(first):find("●", 1, true), "acknowledgement clears pane marker")

  pi.split()
  local second = vim.api.nvim_get_current_buf()
  assert_true(first ~= second, "independent Pi sessions")
  wait_for(function() return status() == "2 idle" end, "both idle")
  send(first, "work")
  wait_for(function() return status() == "1 working" end, "idle pane omitted")
  assert_true(not output[#output]:find("SetProfileProperty", 1, true), "icon set only once")
  send(second, "need")
  wait_for(function() return status() == "1 needs input · 1 working" end, "input takes priority")
  assert_true(last_status_output():find("indicator=#ff453a", 1, true), "input indicator color")
  send(second, "idle")
  wait_for(function() return status() == "1 working" end, "working after input resolves")
  vim.b[first].term_title = "π - First task - " .. vim.fn.fnamemodify(root, ":t")
  send(first, "finish")
  wait_for(function() return status() == "1 finished" end, "unfocused pane stays unread in active tab")
  wait_for(function() return title(first) == "● First task · 1" end, "marker preserves conversation name")
  focus(first)
  assert_true(status() == "2 idle", "pane focus acknowledges only that pane")
  assert_true(title(first) == "First task · 1", "pane focus removes only the marker")
  send(first, "reset")
  wait_for(function() return status() == "1 working" end, "handoff continues working")
  send(first, "finish")
  wait_for(function() return status() == "2 idle" end, "handoff completion counter can restart")

  send(first, "work")
  wait_for(function() return status() == "1 working" end, "work before hiding panes")
  pi.close()
  send(first, "finish")
  wait_for(function() return status() == "1 finished" end, "hidden pane remains unread in active tab")
  vim.api.nvim_exec_autocmds("FocusLost", {})
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert_true(status() == "1 finished", "returning to hidden panes acknowledges nothing")
  vim.api.nvim_exec_autocmds("FocusLost", {})
  pi.open()
  assert_true(status() == "1 finished", "reopening in background does not acknowledge")
  assert_true(title(first):find("● ", 1, true) == 1, "hidden completion marker appears on reopening")
  focus(second)
  assert_true(status() == "1 finished", "background pane focus does not acknowledge")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert_true(status() == "1 finished", "returning to another pane preserves unread result")
  focus(first)
  assert_true(status() == "2 idle", "visiting unread pane acknowledges result")
  assert_true(last_status_output():find("indicator=;status-color=", 1, true), "all idle has no dot")
  vim.wait(700)
  assert_true(status() == "2 idle", "acknowledged completion does not reappear on poll")

  send(first, "work")
  wait_for(function() return status() == "1 working" end, "first concurrent response")
  send(second, "work")
  wait_for(function() return status() == "2 working" end, "count changes without priority change")
  vim.api.nvim_exec_autocmds("FocusLost", {})
  send(first, "finish")
  wait_for(function() return status() == "1 finished · 1 working" end, "mixed completion stays visible")
  assert_true(last_status_output():find("indicator=#30d158", 1, true), "mixed completion has green dot")
  assert_true(marker():match("^finished:%d+$") ~= nil, "mixed completion sorts above working")
  send(second, "finish")
  wait_for(function() return status() == "2 finished" end, "both results unread")
  assert_true(title(first):find("● ", 1, true) == 1 and title(second):find("● ", 1, true) == 1,
    "both panes show unread markers")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert_true(status() == "1 finished", "tab activation acknowledges only its focused pane")
  assert_true(not title(first):find("●", 1, true) and title(second):find("● ", 1, true) == 1,
    "unvisited pane keeps its marker")
  vim.wait(700)
  assert_true(status() == "1 finished", "poll preserves per-pane acknowledgement")
  focus(second)
  assert_true(status() == "2 idle", "visiting remaining pane clears final result")

  pi.split()
  local third = vim.api.nvim_get_current_buf()
  wait_for(function() return status() == "3 idle" end, "three idle sessions")
  send(first, "work")
  wait_for(function() return status() == "1 working" end, "idle counts omitted with three panes")
  send(second, "work")
  wait_for(function() return status() == "2 working" end, "two working and one idle")
  send(second, "finish")
  wait_for(function() return status() == "1 finished · 1 working" end, "mixed label omits idle sessions")
  focus(second)
  assert_true(status() == "1 working", "acknowledging result restores working priority")
  assert_true(marker():match("^working:%d+$") ~= nil, "sort marker returns to working")
  local confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  focus(third)
  pi.close_pane()
  focus(second)
  send(second, "work")
  wait_for(function() return status() == "2 working" end, "two remaining sessions working")
  send(first, "fail")
  wait_for(function() return status() == "1 error · 1 working" end, "error outranks working")
  assert_true(marker():match("^error:%d+$") ~= nil, "error has urgent sort priority")
  send(second, "need")
  wait_for(function() return status() == "1 needs input · 1 error" end, "input and error both visible")
  assert_true(marker():match("^need_input:%d+$") ~= nil, "input has urgent sort priority")
  pi.close_pane()
  assert_true(status() == "Error", "remaining failed pane uses single-session label")
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
pcall(vim.fn.delete, status_paths, "rf")
if not ok then
  print(err)
  os.exit(1)
end
os.exit(0)
