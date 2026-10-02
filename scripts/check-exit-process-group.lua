local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pid_file = assert(vim.env.PI_AGENT_TEST_PID_FILE)
local fake_pi = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  "sleep 300 &",
  "echo $! > \"$PI_AGENT_TEST_PID_FILE\"",
  "wait",
}, fake_pi)
vim.fn.setfperm(fake_pi, "rwx------")

require("pi-agent").setup({ command = fake_pi, keymap = false })
require("pi-agent").open()

local ready = vim.wait(5000, function()
  local file = io.open(pid_file, "r")
  if not file then
    return false
  end
  file:close()
  return true
end, 20)
assert(ready, "fake Pi descendant did not start")

-- This must run ExitPre and finish normally despite the live terminal job.
vim.cmd("qa")
