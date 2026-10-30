vim.o.columns = 120
vim.o.lines = 50

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")
local fake_pi = vim.fn.tempname()
local log_dir = vim.fn.tempname()
vim.fn.mkdir(log_dir, "p")
vim.env.PI_FAKE_LOG_DIR = log_dir
vim.fn.writefile({
  "#!/bin/sh",
  'printf "%s\\n" "$PI_AGENT_STATUS_FILE" > "$PI_FAKE_LOG_DIR/$$"',
  'printf idle > "$PI_AGENT_STATUS_FILE"',
  'while IFS= read -r command; do',
  '  case "$command" in',
  '    *work*) printf working > "$PI_AGENT_STATUS_FILE" ;;',
  '    *idle*) printf idle > "$PI_AGENT_STATUS_FILE" ;;',
  '    *fail*) exit 17 ;;',
  '  esac',
  'done',
}, fake_pi)
vim.fn.setfperm(fake_pi, "rwx------")

local function assert_true(value, label)
  if not value then error("assertion failed: " .. label) end
end

local function wait_for(predicate, label)
  assert_true(vim.wait(3500, predicate, 20), "timed out waiting for " .. label)
end

local function panes()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, value = pcall(vim.api.nvim_buf_get_var, buf, "pi_agent_session")
    if ok and value then found[buf] = win end
  end
  return found
end

local function title(win)
  local parts = vim.api.nvim_win_get_config(win).title
  return parts[1][1], parts[1][2], parts[2][1], parts[3][1]
end

local ok, err = xpcall(function()
  pi.setup({ command = fake_pi, keymap = false })
  pi.open()
  wait_for(function()
    for _, win in pairs(panes()) do
      local dot, group, label = title(win)
      if dot == "● " and group == "PiAgentStatusIdle" and label == "Idle · " then
        return true
      end
    end
    return false
  end, "first idle indicator")

  local first = vim.api.nvim_get_current_buf()
  local first_job = vim.b[first].terminal_job_id
  pi.split()
  local second = vim.api.nvim_get_current_buf()
  assert_true(first ~= second, "split gets a distinct session")
  wait_for(function() return vim.tbl_count(panes()) == 2 end, "two visible panes")
  vim.api.nvim_chan_send(first_job, "work\n")
  wait_for(function()
    local visible = panes()
    local _, first_group, first_label, first_name = title(visible[first])
    local _, second_group, second_label, second_name = title(visible[second])
    return first_group == "PiAgentStatusWorking" and first_label == "Working · "
      and second_group == "PiAgentStatusIdle" and second_label == "Idle · "
      and first_name ~= second_name
  end, "independent colored pane indicators")

  pi.close()
  vim.api.nvim_chan_send(first_job, "idle\n")
  vim.api.nvim_chan_send(vim.b[second].terminal_job_id, "work\n")
  vim.wait(650)
  pi.open()
  wait_for(function()
    local visible = panes()
    if not visible[first] or not visible[second] then return false end
    local _, first_group = title(visible[first])
    local _, second_group = title(visible[second])
    return first_group == "PiAgentStatusIdle" and second_group == "PiAgentStatusWorking"
  end, "independent statuses after hiding and reopening")

  vim.api.nvim_chan_send(vim.b[second].terminal_job_id, "fail\n")
  wait_for(function()
    local visible = panes()
    return visible[second] and select(2, title(visible[second])) == "PiAgentStatusError"
  end, "failed pane indicator")
  assert_true(vim.api.nvim_buf_is_valid(second), "failed output remains available")

  local paths = vim.fn.glob(log_dir .. "/*", true, true)
  assert_true(#paths == 2, "each child receives its own status file")
  local first_path = vim.fn.readfile(paths[1])[1]
  local second_path = vim.fn.readfile(paths[2])[1]
  assert_true(first_path ~= second_path, "status files differ")
  assert_true(vim.fn.filereadable(first_path) == 1, "first status file exists")
  assert_true(vim.fn.filereadable(second_path) == 1, "second status file exists")
  local confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  pi.close_pane()
  pi.close_pane()
  vim.fn.confirm = confirm
  assert_true(vim.fn.filereadable(first_path) == 0, "first status file removed")
  assert_true(vim.fn.filereadable(second_path) == 0, "second status file removed")
end, debug.traceback)

pcall(vim.fn.delete, fake_pi)
vim.fn.delete(log_dir, "rf")
if not ok then
  print(err)
  os.exit(1)
end
