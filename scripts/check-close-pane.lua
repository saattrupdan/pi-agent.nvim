local root = vim.fn.getcwd()
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fake = tmp .. "/fake-pi"
vim.fn.writefile({
  "#!/bin/sh",
  "printf 'ready\\n'",
  "while IFS= read -r line; do [ \"$line\" = exit ] && exit 0; printf 'received:%s\\n' \"$line\"; done",
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
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })
    _G.editor_buf = vim.api.nvim_get_current_buf()
  ]], root, tmp, fake)

  for iteration = 1, 12 do
    remote([[require("pi-agent").open()]])
    wait_for(function() return mode().mode == "t" end, "Pi input")
    if iteration % 2 == 0 then
      input("<C-s>")
      wait_for(function()
        return remote([[local count = 0
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(w).relative ~= "" then count = count + 1 end
          end
          return count]]) == 2 and mode().mode == "t"
      end, "split input")
    end
    local count = iteration % 2 == 0 and 2 or 1
    for remaining = count, 1, -1 do
      if iteration % 3 == 1 and mode().mode == "t" then
        input("<C-x>")
        wait_for(function() return mode().mode:match("^r") end, "cancel confirmation")
        input("n")
        wait_for(function() return mode().mode == "t" end, "input after cancel")
      end
      local normal_close = iteration % 4 == 0
      if normal_close then
        input("<C-\\><C-n>")
        wait_for(function() return mode().mode:match("^n") end, "normal-mode close")
      end
      local closing_buf = vim.rpcrequest(child, "nvim_get_current_buf")
      if iteration % 3 == 0 then
        remote([[local job = vim.b.terminal_job_id
          vim.defer_fn(function() pcall(vim.api.nvim_chan_send, job, "exit\r") end, 100)]])
      end
      input("<C-x>")
      wait_for(function() local m = mode(); return m.blocking or m.mode:match("^r") end, "close confirmation")
      if iteration % 3 == 0 then
        wait_for(function()
          return not vim.rpcrequest(child, "nvim_buf_is_valid", closing_buf)
        end, "Pi exits during confirmation")
        assert(mode().mode:match("^r"), "confirmation remains open after Pi exits")
      end
      input("y")
      wait_for(function()
        return not mode().blocking and remote([[local count = 0
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.b[buf].pi_agent_session then count = count + 1 end
          end
          return count]]) == remaining - 1
      end, "pane removed")
      if remaining > 1 and not normal_close then
        wait_for(function() return mode().mode == "t" end, "surviving Pi input")
        input("still-alive<CR>")
        wait_for(function()
          return remote([[for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
            if line:find("received:still-alive", 1, true) then return true end
          end; return false]])
        end, "surviving Pi receives input")
      else
        assert(mode().mode:match("^n"), "close preserves normal mode")
      end
    end
  end
  assert(vim.fn.jobwait({ child }, 0)[1] == -1, "Neovim survived Ctrl+X")
  assert(remote([[return vim.bo[editor_buf].modified
    and vim.api.nvim_buf_get_lines(editor_buf, 0, -1, false)[1] == "unsaved editor text"]]),
    "closing Pi preserves unsaved editor text")
end, debug.traceback)

if vim.fn.jobwait({ child }, 0)[1] == -1 then
  pcall(vim.rpcnotify, child, "nvim_command", "qa!")
  if vim.fn.jobwait({ child }, 3000)[1] == -1 then
    vim.fn.jobstop(child)
  end
end
vim.fn.delete(tmp, "rf")
if not ok then
  print("Neovim exit status: " .. tostring(vim.fn.jobwait({ child }, 1000)[1]))
  print(err)
  print(table.concat(stderr, "\n"))
  vim.cmd("cquit 1")
end
print("Ctrl+X repeatedly closes Pi panes without exiting Neovim.")
vim.cmd("qa!")
