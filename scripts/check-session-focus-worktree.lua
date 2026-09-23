vim.o.columns = 160
vim.o.lines = 60

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pi = require("pi-agent")

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(value, label)
  if not value then
    error(label)
  end
end

local function pi_windows()
  local result = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match("^pi%-agent:") then
      table.insert(result, { win = win, buf = buf })
    end
  end
  return result
end

local function pi_buffers()
  local result = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):match("^pi%-agent:") then
      table.insert(result, buf)
    end
  end
  return result
end

local function wait_for(predicate, label)
  assert_true(vim.wait(3000, predicate, 20), label)
end

local function run_git(base, ...)
  local args = { "git", "-C", base, ... }
  vim.fn.system(args)
  assert_eq(vim.v.shell_error, 0, "git " .. table.concat({ ... }, " "))
end

local function set_title(buf, name, cwd_basename)
  local ok, err = pcall(vim.api.nvim_buf_set_var, buf, "term_title", "π - " .. name .. " - " .. cwd_basename)
  assert_true(ok, "set terminal title: " .. tostring(err))
end

local function run()
  local tmp = vim.fn.tempname()
  local base = tmp .. "/base"
  local worktree_one = tmp .. "/managed-one"
  local worktree_two = tmp .. "/managed-two"
  local sessions = tmp .. "/sessions"
  local log = tmp .. "/launch.log"
  local fake = tmp .. "/fake-pi"
  vim.fn.mkdir(base, "p")
  vim.fn.mkdir(sessions, "p")
  vim.fn.writefile({ "seed" }, base .. "/seed")

  run_git(base, "init", "-q")
  run_git(base, "config", "user.email", "smoke@example.invalid")
  run_git(base, "config", "user.name", "Smoke Test")
  run_git(base, "add", "seed")
  run_git(base, "commit", "-qm", "seed")
  run_git(base, "worktree", "add", "-qb", "smoke-one", worktree_one, "HEAD")
  run_git(base, "worktree", "add", "-qb", "smoke-two", worktree_two, "HEAD")

  vim.fn.writefile({
    "#!/bin/sh",
    "id=unknown",
    "while [ $# -gt 0 ]; do",
    "  if [ \"$1\" = \"--session-id\" ]; then id=$2; shift; fi",
    "  shift",
    "done",
    "printf '{\"type\":\"session\",\"cwd\":\"%s\"}\\n' \"$PWD\" > \"$PI_CODING_AGENT_SESSION_DIR/000_$id.jsonl\"",
    "printf '%s\\n' \"$PWD\" >> \"$PI_CODING_AGENT_LOG\"",
    "while IFS= read -r line; do :; done",
  }, fake)
  vim.fn.setfperm(fake, "rwxr-xr-x")
  vim.env.PI_CODING_AGENT_SESSION_DIR = sessions
  vim.env.PI_CODING_AGENT_LOG = log
  vim.cmd("cd " .. vim.fn.fnameescape(base))

  pi.setup({
    command = fake,
    width = 0.8,
    height = 0.8,
    border = "single",
    keymap = false,
    abort_keymap = false,
  })

  -- The first pane captures the regular checkout and writes its session header.
  pi.open()
  wait_for(function()
    return #pi_windows() == 1 and vim.fn.filereadable(log) == 1
  end, "initial pane did not start")
  local first_buf = vim.api.nvim_get_current_buf()
  assert_eq(vim.fn.getcwd(), base, "initial global cwd")

  -- Focus follows unique worktree basenames from a delayed OSC-title update.
  pi.split()
  wait_for(function() return #pi_windows() == 2 end, "split did not open")
  local second_buf = vim.api.nvim_get_current_buf()
  local wins = pi_windows()
  local first_win
  for _, item in ipairs(wins) do
    if item.buf == first_buf then
      first_win = item.win
    end
  end
  assert_true(first_win ~= nil, "first pane disappeared")
  set_title(first_buf, "one", vim.fn.fnamemodify(worktree_one, ":t"))
  set_title(second_buf, "two", vim.fn.fnamemodify(worktree_two, ":t"))
  vim.api.nvim_set_current_win(first_win)
  wait_for(function() return vim.fn.getcwd() == worktree_one end, "first worktree was not followed")
  vim.api.nvim_set_current_win((function()
    for _, item in ipairs(pi_windows()) do
      if item.buf == second_buf then return item.win end
    end
  end)())
  wait_for(function() return vim.fn.getcwd() == worktree_two end, "second worktree was not followed")

  -- Hiding and reopening restores the exact focused pane and its buffer.
  pi.close()
  assert_eq(#pi_windows(), 0, "hidden pane count")
  pi.open()
  wait_for(function() return #pi_windows() == 2 end, "panes did not reopen")
  assert_eq(vim.api.nvim_get_current_buf(), second_buf, "restored focused buffer")
  assert_eq(vim.fn.getcwd(), worktree_two, "cwd while hidden/reopened")

  -- Splits remain rooted in the original checkout, not the followed worktree.
  pi.split()
  wait_for(function() return #pi_windows() == 3 end, "second split did not open")
  wait_for(function()
    return vim.fn.filereadable(log) == 1 and #vim.fn.readfile(log) >= 3
  end, "launch log did not record all panes")
  local third_buf = vim.api.nvim_get_current_buf()
  set_title(third_buf, "three", vim.fn.fnamemodify(worktree_two, ":t"))
  wait_for(function() return vim.fn.getcwd() == worktree_two end, "new pane worktree was not followed")
  for _, launched_cwd in ipairs(vim.fn.readfile(log)) do
    assert_eq(launched_cwd, base, "split launch cwd")
  end

  -- Exiting a non-focused pane follows the surviving focused pane.
  local exited_buf = first_buf
  local exited_job = vim.fn.term_getjob(exited_buf)
  assert_true(exited_job > 0, "first pane has no job")
  vim.fn.jobstop(exited_job)
  wait_for(function() return #pi_windows() == 2 end, "surviving panes were not retained")
  assert_eq(vim.fn.getcwd(), worktree_two, "cwd after surviving pane exit")

  -- Stop the remaining jobs: the final pane restores the original checkout.
  for _, buf in ipairs(pi_buffers()) do
    local job = vim.fn.term_getjob(buf)
    if job > 0 then
      vim.fn.jobstop(job)
    end
  end
  wait_for(function() return #pi_windows() == 0 end, "final pane did not exit")
  assert_eq(vim.fn.getcwd(), base, "final cwd restoration")

  vim.cmd("cd " .. vim.fn.fnameescape(root))
  run_git(base, "worktree", "remove", "--force", worktree_one)
  run_git(base, "worktree", "remove", "--force", worktree_two)
  vim.fn.delete(tmp, "rf")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  print(err)
  os.exit(1)
end
os.exit(0)
