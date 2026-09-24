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

local function launch_records(log)
  local records = {}
  if vim.fn.filereadable(log) ~= 1 then
    return records
  end
  for _, line in ipairs(vim.fn.readfile(log)) do
    local cwd, manifest, session_file, session_id, isolation = line:match("^(.-)|(.-)|(.-)|(.-)|(.*)$")
    assert_true(cwd ~= nil, "malformed fake Pi launch record")
    table.insert(records, {
      cwd = cwd,
      manifest = manifest,
      session_file = session_file,
      session_id = session_id,
      isolation = isolation,
    })
  end
  return records
end

local function is_pi_buffer(buf)
  local ok, value = pcall(vim.api.nvim_buf_get_var, buf, "pi_agent_session")
  return ok and value == true
end

local function pi_windows()
  local result = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_pi_buffer(buf) then
      table.insert(result, { win = win, buf = buf })
    end
  end
  return result
end

local function pi_buffers()
  local result = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_pi_buffer(buf) then
      table.insert(result, buf)
    end
  end
  return result
end

local function pi_job(buf)
  return vim.bo[buf].channel or 0
end

local function global_cwd()
  return vim.fn.getcwd(-1, -1)
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
  local worktree_one = tmp .. "/foo - bar"
  local worktree_two = tmp .. "/bar"
  local sessions = tmp .. "/sessions"
  local outside = tmp .. "/outside"
  local log = tmp .. "/launch.log"
  local fake = tmp .. "/fake-pi"
  vim.fn.mkdir(base, "p")
  vim.fn.mkdir(sessions, "p")
  -- macOS exposes /var as a symlink to /private/var; use the same canonical
  -- paths Neovim and `git worktree list` report in all assertions and metadata.
  tmp = vim.loop.fs_realpath(tmp) or tmp
  base = tmp .. "/base"
  worktree_one = tmp .. "/foo - bar"
  worktree_two = tmp .. "/bar"
  sessions = tmp .. "/sessions"
  outside = tmp .. "/outside"
  log = tmp .. "/launch.log"
  fake = tmp .. "/fake-pi"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "seed" }, base .. "/seed")

  run_git(base, "init", "-q")
  run_git(base, "config", "user.email", "smoke@example.invalid")
  run_git(base, "config", "user.name", "Smoke Test")
  run_git(base, "add", "seed")
  run_git(base, "commit", "-qm", "seed")
  vim.fn.writefile({
    "#!/bin/sh",
    "id=unknown",
    "while [ $# -gt 0 ]; do",
    "  if [ \"$1\" = \"--session-id\" ]; then id=$2; shift; fi",
    "  shift",
    "done",
    "printf '%s|%s|%s|%s|%s\\n' \"$PWD\" \"${PI_WORKTREE_SESSION_MANIFEST:-}\" \"${PI_SESSION_FILE:-}\" \"${PI_SESSION_ID:-}\" \"${PI_WORKTREE_ISOLATION_DISABLE:-}\" >> \"$PI_CODING_AGENT_LOG\"",
    "if [ -n \"${PI_WORKTREE_SESSION_MANIFEST:-}\" ] || [ -n \"${PI_SESSION_FILE:-}\" ] || [ -n \"${PI_SESSION_ID:-}\" ]; then",
    "  exit 2",
    "fi",
    "printf '{\"type\":\"session\",\"cwd\":\"%s\"}\\n' \"$PWD\" > \"$PI_CODING_AGENT_SESSION_DIR/000_$id.jsonl\"",
    "(sleep 1; printf '{\"type\":\"session\",\"cwd\":\"%s\"}\\n' \"$PI_CODING_AGENT_DELAYED_CWD\" > \"$PI_CODING_AGENT_SESSION_DIR/000_$id.jsonl\") &",
    "while IFS= read -r line; do :; done",
  }, fake)
  vim.fn.setfperm(fake, "rwxr-xr-x")
  vim.env.PI_CODING_AGENT_SESSION_DIR = sessions
  vim.env.PI_CODING_AGENT_LOG = log
  vim.env.PI_CODING_AGENT_DELAYED_CWD = worktree_one
  -- Reproduce a pane launched from a parent managed Pi session. The fake Pi
  -- exits with status 2 if any of these identity variables leak through.
  vim.env.PI_WORKTREE_SESSION_MANIFEST = "stale-parent-manifest"
  vim.env.PI_SESSION_FILE = "/tmp/stale-parent-session.jsonl"
  vim.env.PI_SESSION_ID = "stale-parent-session"
  vim.env.PI_WORKTREE_ISOLATION_DISABLE = "1"
  vim.cmd("cd " .. vim.fn.fnameescape(base))

  pi.setup({
    command = fake,
    width = 0.8,
    height = 0.8,
    border = "single",
    keymap = "<C-,>",
    abort_keymap = false,
  })

  -- The first pane captures the regular checkout and writes its session header.
  pi.open()
  wait_for(function()
    return #pi_windows() == 1 and vim.fn.filereadable(log) == 1
  end, "initial pane did not start")
  local first_buf = vim.api.nvim_get_current_buf()
  assert_eq(global_cwd(), base, "initial global cwd")
  local git_launches = launch_records(log)
  assert_eq(#git_launches, 1, "initial Git launch count")
  assert_eq(git_launches[1].cwd, base, "initial Git launch cwd")
  assert_eq(git_launches[1].manifest, "", "initial Git manifest clearing")
  assert_eq(git_launches[1].session_file, "", "initial Git session-file clearing")
  assert_eq(git_launches[1].session_id, "", "initial Git session-id clearing")
  assert_eq(git_launches[1].isolation, "", "Git isolation remains enabled")

  -- Create managed worktrees only after Pi has started and its first poll has
  -- run. The delayed JSONL header below must be discovered from a fresh Git
  -- listing rather than an initial cached result.
  run_git(base, "worktree", "add", "-qb", "smoke-one", worktree_one, "HEAD")
  run_git(base, "worktree", "add", "-qb", "smoke-two", worktree_two, "HEAD")
  wait_for(function() return global_cwd() == worktree_one end, "delayed JSONL worktree was not followed")

  -- Focus follows unique worktree basenames from delayed OSC-title updates.
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
  vim.api.nvim_set_current_win(first_win)
  wait_for(function() return global_cwd() == worktree_one end, "first worktree was not followed")

  -- A window-local cwd must not hide a global cwd change when a title moves the
  -- active pane. This also exercises a basename containing the title delimiter.
  vim.cmd("cd " .. vim.fn.fnameescape(base))
  vim.api.nvim_win_call(first_win, function()
    vim.cmd("lcd " .. vim.fn.fnameescape(worktree_two))
  end)
  assert_eq(vim.fn.getcwd(), worktree_two, "window-local cwd")
  assert_eq(global_cwd(), base, "global cwd before title move")

  -- A resume-style title can move the active pane between existing validated
  -- worktrees without relying on its original JSONL session file.
  set_title(first_buf, "resumed", vim.fn.fnamemodify(worktree_two, ":t"))
  wait_for(function() return global_cwd() == worktree_two end, "resumed worktree was not followed")

  set_title(second_buf, "two", vim.fn.fnamemodify(worktree_two, ":t"))
  vim.api.nvim_set_current_win((function()
    for _, item in ipairs(pi_windows()) do
      if item.buf == second_buf then return item.win end
    end
  end)())
  wait_for(function() return global_cwd() == worktree_two end, "second worktree was not followed")

  -- Hiding and reopening restores the exact focused pane and its buffer.
  pi.close()
  assert_eq(#pi_windows(), 0, "hidden pane count")
  pi.open()
  wait_for(function() return #pi_windows() == 2 end, "panes did not reopen")
  assert_eq(vim.api.nvim_get_current_buf(), second_buf, "restored focused buffer")
  assert_eq(global_cwd(), worktree_two, "cwd while hidden/reopened")

  -- Splits remain rooted in the original checkout, not the followed worktree.
  pi.split()
  wait_for(function() return #pi_windows() == 3 end, "second split did not open")
  wait_for(function()
    return #launch_records(log) >= 3
  end, "launch log did not record all panes")
  local third_buf = vim.api.nvim_get_current_buf()
  set_title(third_buf, "three", vim.fn.fnamemodify(worktree_two, ":t"))
  wait_for(function() return global_cwd() == worktree_two end, "new pane worktree was not followed")
  git_launches = launch_records(log)
  assert_eq(#git_launches, 3, "Git launch count")
  for _, launch in ipairs(git_launches) do
    assert_eq(launch.cwd, base, "split launch cwd")
    assert_eq(launch.manifest, "", "Git manifest clearing")
    assert_eq(launch.session_file, "", "Git session-file clearing")
    assert_eq(launch.session_id, "", "Git session-id clearing")
    assert_eq(launch.isolation, "", "Git isolation remains enabled")
  end

  -- Exiting a non-focused pane follows the surviving focused pane.
  local exited_buf = first_buf
  local exited_job = pi_job(exited_buf)
  assert_true(exited_job > 0, "first pane has no job")
  vim.fn.jobstop(exited_job)
  wait_for(function() return #pi_windows() == 2 end, "surviving panes were not retained")
  assert_eq(global_cwd(), worktree_two, "cwd after surviving pane exit")

  -- Stop the remaining jobs: the final pane restores the original checkout.
  for _, buf in ipairs(pi_buffers()) do
    local job = pi_job(buf)
    if job > 0 then
      vim.fn.jobstop(job)
    end
  end
  wait_for(function() return #pi_windows() == 0 end, "final pane did not exit")
  assert_eq(global_cwd(), base, "final cwd restoration")

  -- Opening, hiding, and reopening must also work outside any Git repository.
  -- The launch must clear the parent identity and disable isolation only for
  -- this non-Git lifecycle.
  vim.cmd("cd " .. vim.fn.fnameescape(outside))
  local non_git_start = #launch_records(log)
  pi.toggle()
  wait_for(function()
    return #pi_windows() == 1 and #launch_records(log) == non_git_start + 1
  end, "non-Git pane did not open")
  assert_eq(global_cwd(), outside, "non-Git initial cwd")
  local non_git_launch = launch_records(log)[non_git_start + 1]
  assert_eq(non_git_launch.cwd, outside, "non-Git launch cwd")
  assert_eq(non_git_launch.manifest, "", "non-Git manifest clearing")
  assert_eq(non_git_launch.session_file, "", "non-Git session-file clearing")
  assert_eq(non_git_launch.session_id, "", "non-Git session-id clearing")
  assert_eq(non_git_launch.isolation, "1", "non-Git isolation disabled")

  vim.cmd("stopinsert")
  pi.toggle()
  assert_eq(#pi_windows(), 0, "non-Git hidden pane count")
  assert_eq(global_cwd(), outside, "non-Git cwd while hidden")
  pi.toggle()
  wait_for(function() return #pi_windows() == 1 end, "non-Git pane did not reopen")
  assert_eq(global_cwd(), outside, "non-Git cwd while reopened")
  assert_eq(#launch_records(log), non_git_start + 1, "non-Git reopen launch count")
  assert_eq(launch_records(log)[non_git_start + 1].isolation, "1", "non-Git reopen isolation")

  for _, buf in ipairs(pi_buffers()) do
    local job = pi_job(buf)
    if job > 0 then
      vim.fn.jobstop(job)
    end
  end
  wait_for(function() return #pi_windows() == 0 end, "non-Git pane did not exit")
  assert_eq(global_cwd(), outside, "non-Git final cwd restoration")

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
