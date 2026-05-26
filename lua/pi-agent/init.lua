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
  abort_keymap = "<C-c>",
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

-- Helper: is this line purely border/prompt characters?
local function is_border(line)
  local s = line:gsub("%s+", "")
  if s == "" then return true end
  -- Box-drawing Unicode + ASCII borders + prompt char
  if s:match("^[┌┬┐└┴┘├┤┬┼┐└┌┘┤├┬┴┼│─╔╗╝╚╠╣╦╩╩╬▀▄█▌▐░▒▓■□▢▣▤▥▦▧▨▩▪▫▬▭▮▯♦♣♠♥]+$") then
    return true
  end
  if s:match("^[+=%|-]+$") then
    return true
  end
  if s:match("^>$") then
    return true
  end
  return false
end

-- Strip leading/trailing whitespace and box-vertical chars (the various
-- Unicode line/double/heavy/dotted vertical glyphs plus ASCII `|`) along
-- with any whitespace they wrap, so a line like
-- "  │ > hello │  " collapses to "> hello".
--
-- Uses Vim's regex (rather than Lua patterns) because Vim's `[…]` class is
-- codepoint-aware — Lua's `[…]` operates on raw bytes, which breaks on
-- multi-byte UTF-8 box-drawing characters.
local edge_pattern = [[\v^[ 	|│┃║╽╿▏▕╎╏┆┇┊┋]+|[ 	|│┃║╽╿▏▕╎╏┆┇┊┋]+$]]
local function strip_edges(line)
  return vim.fn.substitute(line, edge_pattern, "", "g")
end

-- Clean a list of lines: drop border-only lines and strip edge whitespace
-- and border-vertical characters from each remaining line. Returns the
-- cleaned list and whether anything changed relative to the input.
local function clean_lines(lines)
  local out = {}
  local changed = false
  for _, line in ipairs(lines) do
    local stripped = strip_edges(line)
    if is_border(stripped) then
      changed = true
    else
      table.insert(out, stripped)
      if stripped ~= line then
        changed = true
      end
    end
  end
  return out, changed
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

    -- Map a configurable key to <Esc> so it aborts the current Pi run
    -- (Pi's normal cancel key) without colliding with <Esc> usage elsewhere
    -- in Neovim.
    if M.config.abort_keymap and M.config.abort_keymap ~= "" then
      vim.keymap.set("t", M.config.abort_keymap, function()
        if state.job then
          vim.api.nvim_chan_send(state.job, "\27")
        end
      end, { buffer = state.buf, nowait = true, desc = "Pi: abort current run" })
    end

    if M.config.trim_yank then
      local function trim_buffer()
        if not vim.api.nvim_buf_is_valid(state.buf) then
          return
        end
        local was_modifiable = vim.bo[state.buf].modifiable
        vim.bo[state.buf].modifiable = true
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, state.buf, 0, -1, false)
        if ok then
          local cleaned, changed = clean_lines(lines)
          if changed then
            pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, cleaned)
            vim.bo[state.buf].modified = false
          end
        end
        vim.bo[state.buf].modifiable = was_modifiable
      end

      vim.api.nvim_create_autocmd({ "TermLeave", "BufEnter", "ModeChanged" }, {
        buffer = state.buf,
        callback = trim_buffer,
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

          local cleaned = clean_lines(lines)

          while #cleaned > 0 and cleaned[1] == "" do
            table.remove(cleaned, 1)
          end
          while #cleaned > 0 and cleaned[#cleaned] == "" do
            table.remove(cleaned)
          end

          local regname = event.regname
          if regname == nil or regname == "" then
            regname = '"'
          end
          vim.fn.setreg(regname, cleaned, event.regtype)
          if regname == '"' then
            vim.fn.setreg("0", cleaned, event.regtype)
          end
        end,
      })
    end
  end
end

function M.is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(state.win)
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
