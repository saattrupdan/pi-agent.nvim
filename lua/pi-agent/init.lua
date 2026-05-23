local M = {}

local state = {
  buf = nil,
  win = nil,
  job = nil,
}

local defaults = {
  command = "pi",
  width = 0.7,
  height = 0.7,
  border = "rounded",
  keymap = "<C-,>",
  trim_yank = true,
}

M.config = vim.deepcopy(defaults)

local function git_root(start_dir)
  local result = vim.fn.systemlist({ "git", "-C", start_dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not result[1] or result[1] == "" then
    return nil
  end
  return result[1]
end

local function resolve_cwd()
  local cwd = vim.fn.getcwd()
  return git_root(cwd) or cwd
end

local function open_float()
  local width = math.floor(vim.o.columns * M.config.width)
  local height = math.floor(vim.o.lines * M.config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf_existed = state.buf and vim.api.nvim_buf_is_valid(state.buf)
  if not buf_existed then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "hide"
  end

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = M.config.border,
    title = " pi-agent ",
    title_pos = "center",
  })

  if not buf_existed then
    local cwd = resolve_cwd()
    state.job = vim.fn.termopen(M.config.command, {
      cwd = cwd,
      on_exit = function()
        state.job = nil
        if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
          vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        state.buf = nil
      end,
    })

    -- Forward control keys Pi relies on (e.g. <C-o> toggles detailed tool
    -- output) so a global tmap can't swallow them in the agent buffer.
    for _, key in ipairs({ "<C-o>" }) do
      vim.keymap.set("t", key, key, { buffer = state.buf, nowait = true })
    end

    -- Map <C-c> to <Esc> so it aborts the current Pi run (Pi's normal
    -- cancel key) without colliding with <Esc> usage elsewhere in Neovim.
    vim.keymap.set("t", "<C-c>", function()
      if state.job then
        vim.api.nvim_chan_send(state.job, "\27")
      end
    end, { buffer = state.buf, nowait = true, desc = "Pi: abort current run" })

    if M.config.trim_yank then
      vim.api.nvim_create_autocmd("TermLeave", {
        buffer = state.buf,
        callback = function()
          if not vim.api.nvim_buf_is_valid(state.buf) then
            return
          end
          local was_modifiable = vim.bo[state.buf].modifiable
          vim.bo[state.buf].modifiable = true
          local ok, lines = pcall(vim.api.nvim_buf_get_lines, state.buf, 0, -1, false)
          if ok then
            local changed = false
            for i, line in ipairs(lines) do
              local trimmed = line:gsub("%s+$", "")
              if trimmed ~= line then
                lines[i] = trimmed
                changed = true
              end
            end
            if changed then
              pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, lines)
              vim.bo[state.buf].modified = false
            end
          end
          vim.bo[state.buf].modifiable = was_modifiable
        end,
      })

      vim.api.nvim_create_autocmd("TextYankPost", {
        buffer = state.buf,
        callback = function()
          local event = vim.v.event
          if event.operator ~= "y" then
            return
          end
          local lines = vim.deepcopy(event.regcontents or {})
          if #lines == 0 then
            return
          end

          for i, line in ipairs(lines) do
            lines[i] = line:gsub("%s+$", "")
          end

          local min_indent = math.huge
          for _, line in ipairs(lines) do
            if line ~= "" then
              min_indent = math.min(min_indent, #line:match("^ *"))
            end
          end
          if min_indent > 0 and min_indent ~= math.huge then
            for i, line in ipairs(lines) do
              lines[i] = line:sub(min_indent + 1)
            end
          end

          while #lines > 0 and lines[1] == "" do
            table.remove(lines, 1)
          end
          while #lines > 0 and lines[#lines] == "" do
            table.remove(lines)
          end

          local regname = event.regname
          if regname == nil or regname == "" then
            regname = '"'
          end
          vim.fn.setreg(regname, lines, event.regtype)
          if regname == '"' then
            vim.fn.setreg("0", lines, event.regtype)
          end
        end,
      })
    end
  end

  vim.cmd("startinsert")
end

function M.is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(state.win)
    vim.cmd("startinsert")
    return
  end
  open_float()
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  vim.api.nvim_create_user_command("PiAgent", M.toggle, {})
  vim.api.nvim_create_user_command("PiAgentOpen", M.open, {})
  vim.api.nvim_create_user_command("PiAgentClose", M.close, {})

  -- Let `:wqa` / `:qa` exit cleanly even when the agent buffer is still
  -- alive — otherwise Neovim raises E947 for the running terminal job.
  vim.api.nvim_create_autocmd("ExitPre", {
    group = vim.api.nvim_create_augroup("PiAgentExit", { clear = true }),
    callback = function()
      if state.job then
        pcall(vim.fn.jobstop, state.job)
        state.job = nil
      end
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
      end
      state.buf = nil
      state.win = nil
    end,
  })

  if M.config.keymap and M.config.keymap ~= "" then
    vim.keymap.set("n", M.config.keymap, M.toggle, { desc = "Toggle Pi agent" })
    vim.keymap.set("t", M.config.keymap, function()
      vim.cmd("stopinsert")
      M.toggle()
    end, { desc = "Toggle Pi agent" })
  end
end

return M
