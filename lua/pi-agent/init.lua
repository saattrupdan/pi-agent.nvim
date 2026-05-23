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
