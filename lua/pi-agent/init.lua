local M = {}

local state = {
  sessions = {},
  layout = nil,
  current_id = nil,
  next_id = 1,
  visible = false,
}

local defaults = {
  command = "pi",
  width = 0.8,
  height = 0.8,
  border = "rounded",
  keymap = "<C-,>",
  abort_keymap = "<C-c>",
}

M.config = vim.deepcopy(defaults)

local ACTIVE_BORDER = "PiAgentActiveBorder"
local ACTIVE_TITLE = "PiAgentActiveTitle"
local CELL_ASPECT_RATIO = 2.2

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

local function in_terminal_mode()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "t"
end

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function pane_area()
  local width = math.max(1, math.floor(vim.o.columns * M.config.width))
  local height = math.max(1, math.floor(vim.o.lines * M.config.height))
  return {
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
  }
end

local function first_leaf(node)
  if not node then
    return nil
  end
  if node.id then
    return node.id
  end
  return first_leaf(node.first) or first_leaf(node.second)
end

local function collect_leaves(node, leaves)
  if not node then
    return leaves
  end
  if node.id then
    table.insert(leaves, node.id)
    return leaves
  end
  collect_leaves(node.first, leaves)
  collect_leaves(node.second, leaves)
  return leaves
end

local function each_session(callback)
  for id, session in pairs(state.sessions) do
    callback(session, id)
  end
end

local function visible_session_count()
  local count = 0
  each_session(function(session)
    if is_valid_win(session.win) then
      count = count + 1
    end
  end)
  return count
end

local function current_session_id()
  local current_buf = vim.api.nvim_get_current_buf()
  for id, session in pairs(state.sessions) do
    if session.buf == current_buf then
      return id
    end
  end
  return state.current_id or first_leaf(state.layout)
end

local function remember_view_if_browsing(session)
  if not session or not is_valid_win(session.win) or vim.api.nvim_get_current_win() ~= session.win then
    if session then
      session.view = nil
    end
    return
  end
  if in_terminal_mode() then
    session.view = nil
    return
  end

  vim.api.nvim_win_call(session.win, function()
    if vim.fn.line("w$") >= vim.fn.line("$") then
      session.view = nil
    else
      session.view = vim.fn.winsaveview()
    end
  end)
end

local function restore_browsing_view(session)
  if not session or not session.view or not is_valid_win(session.win) or in_terminal_mode() then
    return
  end

  local view = vim.deepcopy(session.view)
  vim.api.nvim_win_call(session.win, function()
    vim.fn.winrestview(view)
  end)
end

local function rects_for_layout(node, rect, rects)
  if not node then
    return rects
  end
  if node.id then
    rects[node.id] = rect
    return rects
  end

  if node.split == "vertical" then
    local first_width = math.max(1, math.floor(rect.width / 2))
    local second_width = math.max(1, rect.width - first_width)
    rects_for_layout(node.first, {
      row = rect.row,
      col = rect.col,
      width = first_width,
      height = rect.height,
    }, rects)
    rects_for_layout(node.second, {
      row = rect.row,
      col = rect.col + first_width,
      width = second_width,
      height = rect.height,
    }, rects)
  else
    local first_height = math.max(1, math.floor(rect.height / 2))
    local second_height = math.max(1, rect.height - first_height)
    rects_for_layout(node.first, {
      row = rect.row,
      col = rect.col,
      width = rect.width,
      height = first_height,
    }, rects)
    rects_for_layout(node.second, {
      row = rect.row + first_height,
      col = rect.col,
      width = rect.width,
      height = second_height,
    }, rects)
  end
  return rects
end

local function window_config(rect, id, active)
  return {
    relative = "editor",
    width = rect.width,
    height = rect.height,
    row = rect.row,
    col = rect.col,
    style = "minimal",
    border = M.config.border,
    title = active and string.format(" pi-agent %d ● ", id) or string.format(" pi-agent %d ", id),
    title_pos = "center",
  }
end

local function split_direction(rect)
  local visual_width = rect.width
  local visual_height = rect.height * CELL_ASPECT_RATIO
  return visual_width >= visual_height and "vertical" or "horizontal"
end

local function update_active_marker()
  local mark_active = visible_session_count() > 1
  each_session(function(session, id)
    if not is_valid_win(session.win) then
      return
    end

    local active = mark_active and id == state.current_id
    local row_col = vim.api.nvim_win_get_position(session.win)
    local rect = {
      row = row_col[1],
      col = row_col[2],
      width = vim.api.nvim_win_get_width(session.win),
      height = vim.api.nvim_win_get_height(session.win),
    }
    vim.api.nvim_win_set_config(session.win, window_config(rect, id, active))
    vim.wo[session.win].winhighlight = active
        and "FloatBorder:" .. ACTIVE_BORDER .. ",FloatTitle:" .. ACTIVE_TITLE
      or ""
  end)
end

local render_layout
local remove_session

local function replace_leaf(node, target_id, replacement)
  if not node then
    return false
  end
  if node.id == target_id then
    for key in pairs(node) do
      node[key] = nil
    end
    for key, value in pairs(replacement) do
      node[key] = value
    end
    return true
  end
  return replace_leaf(node.first, target_id, replacement) or replace_leaf(node.second, target_id, replacement)
end

local function collapse_leaf(node, target_id)
  if not node then
    return nil, false
  end
  if node.id then
    if node.id == target_id then
      return nil, true
    end
    return node, false
  end

  local first, removed_first = collapse_leaf(node.first, target_id)
  local second, removed_second = collapse_leaf(node.second, target_id)
  if not removed_first and not removed_second then
    return node, false
  end
  if first and second then
    node.first = first
    node.second = second
    return node, true
  end
  return first or second, true
end

local function find_visible_rect(id)
  if is_valid_win(state.sessions[id] and state.sessions[id].win) then
    local win = state.sessions[id].win
    local row_col = vim.api.nvim_win_get_position(win)
    return {
      row = row_col[1],
      col = row_col[2],
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
    }
  end
  return rects_for_layout(state.layout, pane_area(), {})[id] or pane_area()
end

local function nearest_pane(direction)
  local id = current_session_id()
  local session = id and state.sessions[id]
  if not session or not is_valid_win(session.win) then
    return nil
  end

  local source = find_visible_rect(id)
  local source_x = source.col + source.width / 2
  local source_y = source.row + source.height / 2
  local best_id = nil
  local best_score = nil

  each_session(function(candidate, candidate_id)
    if candidate_id == id or not is_valid_win(candidate.win) then
      return
    end
    local rect = find_visible_rect(candidate_id)
    local x = rect.col + rect.width / 2
    local y = rect.row + rect.height / 2
    local primary
    local secondary

    if direction == "h" then
      primary = source_x - x
      secondary = math.abs(source_y - y)
    elseif direction == "l" then
      primary = x - source_x
      secondary = math.abs(source_y - y)
    elseif direction == "k" then
      primary = source_y - y
      secondary = math.abs(source_x - x)
    else
      primary = y - source_y
      secondary = math.abs(source_x - x)
    end

    if primary > 0 then
      local score = primary * 1000 + secondary
      if not best_score or score < best_score then
        best_score = score
        best_id = candidate_id
      end
    end
  end)

  return best_id
end

local function focus_session(id, start_insert)
  local session = id and state.sessions[id]
  if not session or not is_valid_win(session.win) then
    return false
  end
  state.current_id = id
  vim.api.nvim_set_current_win(session.win)
  update_active_marker()
  if start_insert then
    vim.schedule(function()
      if is_valid_win(session.win) and vim.api.nvim_get_current_win() == session.win then
        vim.cmd("startinsert")
      end
    end)
  end
  return true
end

local function cycle_pane()
  local leaves = collect_leaves(state.layout, {})
  if #leaves == 0 then
    return nil
  end

  local id = current_session_id()
  for index, leaf_id in ipairs(leaves) do
    if leaf_id == id then
      return leaves[index % #leaves + 1]
    end
  end
  return leaves[1]
end

local function navigate_pane(direction)
  local was_terminal = in_terminal_mode()
  if was_terminal then
    vim.cmd("stopinsert")
  end

  local target_id = direction == "w" and cycle_pane() or nearest_pane(direction)
  if not focus_session(target_id, was_terminal) and was_terminal then
    vim.schedule(function()
      vim.cmd("startinsert")
    end)
  end
end

local function setup_session_keymaps(session)
  local opts = { buffer = session.buf, nowait = true }

  -- Forward control keys Pi relies on (e.g. <C-o> toggles detailed tool
  -- output) so a global tmap can't swallow them in the agent buffer.
  for _, key in ipairs({ "<C-o>" }) do
    vim.keymap.set("t", key, key, opts)
  end

  -- Terminal lines are padded with trailing spaces to the window width, so
  -- linewise visual would highlight all that padding. Remap V to a charwise
  -- select from column 0 to the last non-blank, and remap $ in visual mode to
  -- g_ so extending a selection also stops at text.
  vim.keymap.set("n", "V", "0vg_", opts)
  vim.keymap.set("x", "$", "g_", opts)

  vim.keymap.set({ "n", "t" }, "<C-s>", function()
    M.split()
  end, vim.tbl_extend("force", opts, { desc = "Pi: split pane" }))

  vim.keymap.set({ "n", "t" }, "<C-d>", function()
    M.close_pane()
  end, vim.tbl_extend("force", opts, { desc = "Pi: close pane" }))

  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set({ "n", "t" }, "<C-w>" .. direction, function()
      navigate_pane(direction)
    end, vim.tbl_extend("force", opts, { desc = "Pi: move pane " .. direction }))
  end

  vim.keymap.set({ "n", "t" }, "<C-w><C-w>", function()
    navigate_pane("w")
  end, vim.tbl_extend("force", opts, { desc = "Pi: cycle panes" }))

  -- Map a configurable key to <Esc> so it aborts the current Pi run (Pi's
  -- normal cancel key) without colliding with <Esc> usage elsewhere in Neovim.
  if M.config.abort_keymap and M.config.abort_keymap ~= "" then
    vim.keymap.set("t", M.config.abort_keymap, function()
      if session.job then
        vim.api.nvim_chan_send(session.job, "\27")
      end
    end, vim.tbl_extend("force", opts, { desc = "Pi: abort current run" }))
  end
end

local function setup_session_autocmds(session)
  local group = vim.api.nvim_create_augroup("PiAgentBuffer" .. session.id, { clear = true })

  vim.api.nvim_buf_attach(session.buf, false, {
    on_lines = function()
      if session.view then
        vim.schedule(function()
          restore_browsing_view(session)
        end)
      end
    end,
    on_detach = function()
      session.view = nil
    end,
  })

  vim.api.nvim_create_autocmd({ "TermLeave", "CursorMoved" }, {
    group = group,
    buffer = session.buf,
    callback = function()
      remember_view_if_browsing(session)
    end,
  })
  vim.api.nvim_create_autocmd("TermEnter", {
    group = group,
    buffer = session.buf,
    callback = function()
      session.view = nil
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(event)
      if tonumber(event.match) == session.win then
        remember_view_if_browsing(session)
      end
    end,
  })

  -- Post-process yanks from the agent buffer so the register holds just the
  -- message text — no terminal padding, no box-drawing borders, no surrounding
  -- blank lines. The UI is never modified; only register contents change.
  local edge_pattern = [[\v^[ 	|│┃║╽╿▏▕╎╏┆┇┊┋>]+|[ 	|│┃║╽╿▏▕╎╏┆┇┊┋]+$]]
  local border_pattern = [[\v^[ 	|│┃║╽╿▏▕╎╏┆┇┊┋─━═┄┅┈┉┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬>+=\-]*$]]
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = group,
    buffer = session.buf,
    callback = function()
      local event = vim.v.event
      if event.operator ~= "y" then
        return
      end
      local lines = vim.deepcopy(event.regcontents or {})
      if #lines == 0 then
        return
      end

      local cleaned = {}
      for _, line in ipairs(lines) do
        local stripped = vim.fn.substitute(line, edge_pattern, "", "g")
        if vim.fn.match(stripped, border_pattern) < 0 then
          table.insert(cleaned, stripped)
        end
      end

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

local function create_session()
  local id = state.next_id
  state.next_id = state.next_id + 1

  local session = {
    id = id,
    buf = vim.api.nvim_create_buf(false, true),
    win = nil,
    job = nil,
    view = nil,
    closing = false,
  }
  state.sessions[id] = session
  vim.bo[session.buf].bufhidden = "hide"

  setup_session_keymaps(session)
  setup_session_autocmds(session)

  local cwd = resolve_cwd()
  vim.api.nvim_buf_call(session.buf, function()
    session.job = vim.fn.termopen(M.config.command, {
      cwd = cwd,
      on_exit = function()
        vim.schedule(function()
          if session.closing then
            return
          end
          remove_session(id, false)
        end)
      end,
    })
  end)

  return session
end

render_layout = function(focus_id)
  if not state.layout then
    state.visible = false
    return
  end

  state.visible = true
  local rects = rects_for_layout(state.layout, pane_area(), {})

  each_session(function(session, id)
    local rect = rects[id]
    if not rect or not is_valid_buf(session.buf) then
      if is_valid_win(session.win) then
        pcall(vim.api.nvim_win_close, session.win, true)
      end
      session.win = nil
      return
    end

    local config = window_config(rect, id, false)
    if is_valid_win(session.win) then
      vim.api.nvim_win_set_config(session.win, config)
    else
      session.win = vim.api.nvim_open_win(session.buf, false, config)
    end
  end)

  focus_session(focus_id or state.current_id or first_leaf(state.layout), in_terminal_mode())
end

remove_session = function(id, stop_job)
  local session = state.sessions[id]
  if not session then
    return
  end

  session.closing = true
  if is_valid_win(session.win) then
    pcall(vim.api.nvim_win_close, session.win, true)
  end
  if stop_job and session.job then
    pcall(vim.fn.jobstop, session.job)
  end
  if is_valid_buf(session.buf) then
    pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
  end

  state.sessions[id] = nil
  state.layout = collapse_leaf(state.layout, id)
  if state.current_id == id then
    state.current_id = first_leaf(state.layout)
  end

  if state.visible then
    render_layout(state.current_id)
  end
end

function M.is_open()
  if not state.visible then
    return false
  end
  for _, session in pairs(state.sessions) do
    if is_valid_win(session.win) then
      return true
    end
  end
  return false
end

function M.open()
  if not state.layout then
    local session = create_session()
    state.layout = { id = session.id }
    state.current_id = session.id
  end

  render_layout(state.current_id or first_leaf(state.layout))
  vim.cmd("startinsert")
end

function M.close()
  each_session(function(session)
    if is_valid_win(session.win) then
      pcall(vim.api.nvim_win_close, session.win, true)
    end
    session.win = nil
  end)
  state.visible = false
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.split()
  local was_terminal = in_terminal_mode()
  if was_terminal then
    vim.cmd("stopinsert")
  end
  if not M.is_open() then
    M.open()
    return
  end

  local id = current_session_id()
  if not id or not state.sessions[id] then
    return
  end

  local rect = find_visible_rect(id)
  local split = split_direction(rect)
  local session = create_session()
  local replacement = {
    split = split,
    first = { id = id },
    second = { id = session.id },
  }

  replace_leaf(state.layout, id, replacement)
  state.current_id = session.id
  render_layout(session.id)
  vim.cmd("startinsert")
end

function M.close_pane()
  local was_terminal = in_terminal_mode()
  if was_terminal then
    vim.cmd("stopinsert")
  end

  local id = current_session_id()
  if not id then
    return
  end
  remove_session(id, true)

  if state.layout then
    focus_session(state.current_id or first_leaf(state.layout), was_terminal)
  else
    state.visible = false
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  vim.api.nvim_set_hl(0, ACTIVE_BORDER, { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, ACTIVE_TITLE, { default = true, link = "DiagnosticInfo" })

  vim.api.nvim_create_user_command("PiAgent", M.toggle, {})
  vim.api.nvim_create_user_command("PiAgentOpen", M.open, {})
  vim.api.nvim_create_user_command("PiAgentClose", M.close, {})

  local group = vim.api.nvim_create_augroup("PiAgent", { clear = true })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if state.visible then
        render_layout(state.current_id or first_leaf(state.layout))
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if not state.visible then
        return
      end
      local id = current_session_id()
      local session = id and state.sessions[id]
      if session and is_valid_win(session.win) and vim.api.nvim_get_current_win() == session.win then
        state.current_id = id
        update_active_marker()
      end
    end,
  })

  -- Let `:wqa` / `:qa` exit cleanly even when agent buffers are still alive —
  -- otherwise Neovim raises E947 for running terminal jobs.
  vim.api.nvim_create_autocmd("ExitPre", {
    group = group,
    callback = function()
      each_session(function(session)
        session.closing = true
        if session.job then
          pcall(vim.fn.jobstop, session.job)
          session.job = nil
        end
        if is_valid_buf(session.buf) then
          pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
        end
      end)
      state.sessions = {}
      state.layout = nil
      state.current_id = nil
      state.visible = false
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
