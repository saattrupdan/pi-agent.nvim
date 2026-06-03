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
  pane_gap = 1,
  keymap = "<C-,>",
  abort_keymap = "<C-c>",
  new_session_keymap = "<C-l>",
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

local function pane_gap()
  local gap = M.config.pane_gap
  if type(gap) ~= "number" and type(gap) ~= "string" then
    return 0
  end
  return math.max(0, math.floor(tonumber(gap) or 0))
end

local function split_size(size, gap)
  local actual_gap = math.min(gap, math.max(0, size - 2))
  local available = math.max(2, size - actual_gap)
  local first = math.max(1, math.floor(available / 2))
  local second = math.max(1, available - first)
  return first, second, actual_gap
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

local function id_in_layout(id)
  if not id then
    return false
  end
  for _, leaf_id in ipairs(collect_leaves(state.layout, {})) do
    if leaf_id == id then
      return true
    end
  end
  return false
end

local function valid_layout_session(id)
  return id_in_layout(id) and state.sessions[id] ~= nil
end

local function current_session_id()
  local current_win = vim.api.nvim_get_current_win()
  for id, session in pairs(state.sessions) do
    if session.win == current_win and is_valid_win(session.win) and valid_layout_session(id) then
      return id
    end
  end

  local current_buf = vim.api.nvim_get_current_buf()
  for id, session in pairs(state.sessions) do
    if session.buf == current_buf and valid_layout_session(id) then
      return id
    end
  end

  if valid_layout_session(state.current_id) then
    return state.current_id
  end

  local first_id = first_leaf(state.layout)
  if valid_layout_session(first_id) then
    return first_id
  end
  return nil
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

local function follow_output(session)
  if not session or not is_valid_win(session.win) then
    return
  end
  vim.api.nvim_win_call(session.win, function()
    pcall(vim.api.nvim_win_set_cursor, session.win, { vim.fn.line("$"), 0 })
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

  local gap = pane_gap()
  if node.split == "vertical" then
    local first_width, second_width, actual_gap = split_size(rect.width, gap)
    rects_for_layout(node.first, {
      row = rect.row,
      col = rect.col,
      width = first_width,
      height = rect.height,
    }, rects)
    rects_for_layout(node.second, {
      row = rect.row,
      col = rect.col + first_width + actual_gap,
      width = second_width,
      height = rect.height,
    }, rects)
  else
    local first_height, second_height, actual_gap = split_size(rect.height, gap)
    rects_for_layout(node.first, {
      row = rect.row,
      col = rect.col,
      width = rect.width,
      height = first_height,
    }, rects)
    rects_for_layout(node.second, {
      row = rect.row + first_height + actual_gap,
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
  return visual_width > visual_height and "vertical" or "horizontal"
end

local function leaf_parent_split(node, target_id, parent_split)
  if not node then
    return nil
  end
  if node.id == target_id then
    return parent_split
  end
  return leaf_parent_split(node.first, target_id, node.split)
    or leaf_parent_split(node.second, target_id, node.split)
end

local function contextual_split_direction(id, rect)
  if leaf_parent_split(state.layout, id) == "vertical" then
    return "horizontal"
  end
  return split_direction(rect)
end

local function layout_rects()
  return rects_for_layout(state.layout, pane_area(), {})
end

local function update_active_marker()
  local mark_active = visible_session_count() > 1
  local rects = layout_rects()
  each_session(function(session, id)
    if not is_valid_win(session.win) then
      return
    end

    local active = mark_active and id == state.current_id
    local rect = rects[id] or pane_area()
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

local function find_layout_rect(id)
  return layout_rects()[id]
end

local function range_overlap(start_a, end_a, start_b, end_b)
  return math.max(0, math.min(end_a, end_b) - math.max(start_a, start_b))
end

local function range_gap(start_a, end_a, start_b, end_b)
  if end_a < start_b then
    return start_b - end_a
  end
  if end_b < start_a then
    return start_a - end_b
  end
  return 0
end

local function better_pane_score(score, best_score)
  if not best_score then
    return true
  end
  for index, value in ipairs(score) do
    if value ~= best_score[index] then
      return value < best_score[index]
    end
  end
  return false
end

local function directional_score(direction, source, rect, candidate_id)
  local source_right = source.col + source.width
  local source_bottom = source.row + source.height
  local rect_right = rect.col + rect.width
  local rect_bottom = rect.row + rect.height
  local primary
  local overlap
  local gap
  local center_delta

  if direction == "h" then
    if rect_right > source.col then
      return nil
    end
    primary = source.col - rect_right
    overlap = range_overlap(source.row, source_bottom, rect.row, rect_bottom)
    gap = range_gap(source.row, source_bottom, rect.row, rect_bottom)
    center_delta = math.abs(source.row + source.height / 2 - (rect.row + rect.height / 2))
  elseif direction == "l" then
    if rect.col < source_right then
      return nil
    end
    primary = rect.col - source_right
    overlap = range_overlap(source.row, source_bottom, rect.row, rect_bottom)
    gap = range_gap(source.row, source_bottom, rect.row, rect_bottom)
    center_delta = math.abs(source.row + source.height / 2 - (rect.row + rect.height / 2))
  elseif direction == "k" then
    if rect_bottom > source.row then
      return nil
    end
    primary = source.row - rect_bottom
    overlap = range_overlap(source.col, source_right, rect.col, rect_right)
    gap = range_gap(source.col, source_right, rect.col, rect_right)
    center_delta = math.abs(source.col + source.width / 2 - (rect.col + rect.width / 2))
  else
    if rect.row < source_bottom then
      return nil
    end
    primary = rect.row - source_bottom
    overlap = range_overlap(source.col, source_right, rect.col, rect_right)
    gap = range_gap(source.col, source_right, rect.col, rect_right)
    center_delta = math.abs(source.col + source.width / 2 - (rect.col + rect.width / 2))
  end

  return {
    overlap > 0 and 0 or 1,
    primary,
    -overlap,
    gap,
    center_delta,
    candidate_id,
  }
end

local function nearest_pane(direction)
  local id = current_session_id()
  local session = id and state.sessions[id]
  if not session or not is_valid_win(session.win) then
    return nil
  end

  local rects = layout_rects()
  local source = rects[id]
  if not source then
    return nil
  end
  local best_id = nil
  local best_score = nil

  each_session(function(candidate, candidate_id)
    if candidate_id == id or not is_valid_win(candidate.win) then
      return
    end
    local rect = rects[candidate_id]
    if not rect then
      return
    end
    local score = directional_score(direction, source, rect, candidate_id)
    if score and better_pane_score(score, best_score) then
      best_score = score
      best_id = candidate_id
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

  vim.keymap.set({ "n", "t" }, "<C-x>", function()
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

  -- Map a configurable key to send /new to Pi so you can start a fresh session
  -- without leaving terminal mode or typing the slash command manually.
  if M.config.new_session_keymap and M.config.new_session_keymap ~= "" then
    vim.keymap.set("t", M.config.new_session_keymap, function()
      if session.job then
        vim.api.nvim_chan_send(session.job, "/new\r")
      end
    end, vim.tbl_extend("force", opts, { desc = "Pi: new session" }))
  end
end

local function setup_session_autocmds(session)
  local group = vim.api.nvim_create_augroup("PiAgentBuffer" .. session.id, { clear = true })

  vim.api.nvim_buf_attach(session.buf, false, {
    on_lines = function()
      vim.schedule(function()
        if vim.api.nvim_get_current_win() == session.win then
          if session.view then
            restore_browsing_view(session)
          elseif not in_terminal_mode() then
            -- In normal mode: don't auto-scroll, stay where the cursor is
          else
            -- In terminal mode: follow new output
            follow_output(session)
          end
        else
          follow_output(session)
        end
      end)
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
  local rects = layout_rects()

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
  local rect = id and find_layout_rect(id)
  if not id or not rect or not state.sessions[id] then
    return
  end

  local split = contextual_split_direction(id, rect)
  local session = create_session()
  local replacement = {
    split = split,
    first = { id = id },
    second = { id = session.id },
  }

  if not replace_leaf(state.layout, id, replacement) then
    remove_session(session.id, true)
    return
  end
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

  -- One-keystroke confirmation: <y> closes, anything else cancels.
  if vim.fn.confirm("Close this Pi pane?", "&Yes\n&No", 2) ~= 1 then
    if was_terminal then
      vim.cmd("startinsert")
    end
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
