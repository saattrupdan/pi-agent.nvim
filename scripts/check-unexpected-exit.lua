vim.o.columns = 100
vim.o.lines = 40

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")
local fake_pi = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  "printf 'fake Pi started\\n'",
  'if [ "$PI_FAKE_SUCCESS" = 1 ]; then exit 0; fi',
  'if [ "$PI_FAKE_WAIT" = 1 ]; then IFS= read -r command; exit 0; fi',
  'IFS= read -r command',
  'if [ "$command" = /resume ]; then printf "simulated resume failure\\n"; exit 17; fi',
  "exit 0",
}, fake_pi)
vim.fn.setfperm(fake_pi, "rwx------")

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

local function assert_true(value, label)
  if not value then
    error("assertion failed: " .. label)
  end
end

local function wait_for(predicate, label)
  assert_true(vim.wait(3000, predicate, 10), "timed out waiting for " .. label)
end

local function pi_buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ok, value = pcall(vim.api.nvim_buf_get_var, buf, "pi_agent_session")
    if ok and value then
      table.insert(buffers, buf)
    end
  end
  return buffers
end

local ok, err = xpcall(function()
  pi.setup({
    command = fake_pi,
    width = 0.8,
    height = 0.6,
    keymap = false,
    abort_keymap = false,
  })

  pi.open()
  wait_for(function()
    return #pi_buffers() == 1
  end, "failure pane startup")
  local failed_buf = pi_buffers()[1]
  local job = vim.b[failed_buf].terminal_job_id
  pi.close()
  vim.api.nvim_chan_send(job, "/resume\r")
  wait_for(function()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(failed_buf, 0, -1, false)) do
      if line:find("simulated resume failure", 1, true) then
        return true
      end
    end
    return false
  end, "simulated resume output")
  wait_for(function()
    return #notifications > 0
  end, "exit notification")
  assert_true(vim.api.nvim_buf_is_valid(failed_buf), "failed terminal buffer retained")
  assert_true(notifications[1].message:find("code 17", 1, true), "exit code reported")
  assert_true(notifications[1].message:find("<C%-x>") ~= nil, "close guidance reported")
  assert_true(notifications[1].message:find(":PiAgentOpen", 1, true), "restart guidance reported")

  pi.open()
  wait_for(function()
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == failed_buf then
        return true
      end
    end
    return false
  end, "failed pane reopened")

  local original_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  pi.close_pane()
  vim.fn.confirm = original_confirm
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(failed_buf)
  end, "failed pane closed")

  pi.config.command = "PI_FAKE_WAIT=1 " .. fake_pi
  pi.open()
  local stale_job_buf = pi_buffers()[1]
  local original_jobpid = vim.fn.jobpid
  local jobpid_called = false
  vim.fn.jobpid = function()
    jobpid_called = true
    error("E900: Invalid channel id")
  end
  local original_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  local close_ok, close_err = pcall(pi.close_pane)
  vim.fn.confirm = original_confirm
  vim.fn.jobpid = original_jobpid
  assert_true(close_ok, "close tolerates an invalid job channel: " .. tostring(close_err))
  assert_true(jobpid_called, "close checks the stale job channel")
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(stale_job_buf)
  end, "pane closed after invalid job channel")

  pi.config.command = "PI_FAKE_SUCCESS=1 " .. fake_pi
  pi.open()
  local success_buf = pi_buffers()[1]
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(success_buf)
  end, "successful pane teardown")
  assert_true(#pi_buffers() == 0, "successful exit removes pane")
end, debug.traceback)

vim.notify = original_notify
pcall(vim.fn.delete, fake_pi)
if not ok then
  print(err)
  os.exit(1)
end
os.exit(0)
