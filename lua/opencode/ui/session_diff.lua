local patch = require('opencode.session_patch')
local config = require('opencode.config')
local float_layout = require('opencode.ui.float_layout')
local help = require('opencode.ui.session_diff.help')
local icons = require('opencode.ui.icons')
local render = require('opencode.ui.session_diff.render')
local context = require('opencode.context')
local comment_input = require('opencode.ui.session_diff.comment_input')
local util = require('opencode.util')

local M = {}
local has_devicons, devicons = pcall(require, 'nvim-web-devicons')
local has_mini, mini_icons = pcall(require, 'mini.icons')

local function file_icon(name)
  if has_devicons then
    local icon, highlight = devicons.get_icon(name, vim.fn.fnamemodify(name, ':e'), { default = true })
    return icon, highlight
  end
  if has_mini then
    local icon, highlight = mini_icons.get('file', name)
    return icon, highlight
  end
  return vim.trim(icons.get('file')), nil
end

---@class OpencodeSessionDiffView
---@field tab integer
---@field list_win integer
---@field preview_win integer
---@field right_win? integer
---@field turn_preview_win? integer
---@field turn_win? integer
---@field turn_buf? integer
---@field help_win? integer
---@field help_return_win? integer
---@field files OpencodeV2FileDiff[]
---@field index integer
---@field mode 'patch'|'sides'
---@field list_buf integer
---@field tree OpencodeSessionDiffNode
---@field rows OpencodeSessionDiffNode[]
---@field session {id: string, title?: string}
---@field range_mode boolean
---@field turns {id: string, text: string, created?: number}[]
---@field message_count? integer
---@field turn_from integer
---@field turn_to integer
---@field from? string
---@field to? string
---@field range_key? string
---@field loading? boolean
---@field load_turns? fun(): Promise<{id: string, text: string, created?: number}[]>
---@field review_range? fun(from: string, to?: string, message_count?: integer): Promise<nil>
---@field sides table<integer, OpencodeReviewCommentSide>
---@field patch_map OpencodeSessionPatchLine[]
---@field patch_lines string[]
---@field before_lines string[]?
---@field after_lines string[]?
local view
---@type fun(lines: string[], filetype: string, scope?: 'list'|'preview'|'message_preview'): integer
local scratch

---@class OpencodeSessionDiffOptions
---@field from? string
---@field to? string
---@field load_turns fun(): Promise<{id: string, text: string, created?: number}[]>
---@field review_range fun(from: string, to?: string, message_count?: integer): Promise<nil>
---@field message_count? integer
---@field file? string

local function active()
  return view and vim.api.nvim_tabpage_is_valid(view.tab)
end

local function in_view()
  return active() and vim.api.nvim_get_current_tabpage() == view.tab
end

local function selected_row()
  for row, node in ipairs(view.rows) do
    if node.file_index == view.index then
      return row
    end
  end
end

---@param buf integer
---@param scope 'list'|'messages'|'preview'|'message_preview'|'help'
local function map_actions(buf, scope)
  local actions = {
    activate = M.activate,
    toggle_range = M.toggle_range,
    mark_from = function()
      M.mark_range('from')
    end,
    mark_to = function()
      M.mark_range('to')
    end,
    show_message_preview = M.show_turn_preview,
    hide_message_preview = M.hide_turn_preview,
    toggle_view = M.toggle_view,
    toggle_help = M.toggle_help,
    close = function() M.close({ focus_input = true }) end,
    add_comment = M.add_comment,
    delete_comment = M.delete_comment,
    next_comment = function() M.jump_comment(1) end,
    prev_comment = function() M.jump_comment(-1) end,
  }
  for key, entry in pairs(config.keymap.session_diff[scope]) do
    if entry ~= false then
      vim.keymap.set(entry.mode or 'n', key, actions[entry[1]], {
        buffer = buf,
        silent = true,
        desc = entry.desc,
        nowait = entry.nowait,
      })
    end
  end
end

local function help_key()
  for key, entry in pairs(config.keymap.session_diff.list) do
    if entry ~= false and entry[1] == 'toggle_help' then
      return key
    end
  end
end

---@param action string
---@param preferred? string
---@return string?
local function message_key(action, preferred)
  local mappings = config.keymap.session_diff.messages
  if preferred then
    local entry = mappings[preferred]
    if entry and entry ~= false and entry[1] == action then
      return preferred
    end
  end
  local keys = vim.tbl_keys(mappings)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local entry = mappings[key]
    if entry ~= false and entry[1] == action then
      return key
    end
  end
end

local function list_key(action, preferred)
  local mappings = config.keymap.session_diff.list
  if preferred then
    local entry = mappings[preferred]
    if entry and entry ~= false and entry[1] == action then
      return preferred
    end
  end
  local keys = vim.tbl_keys(mappings)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local entry = mappings[key]
    if entry ~= false and entry[1] == action then
      return key
    end
  end
end

local function message_title()
  local hints = {}
  local from = message_key('mark_from', 'f')
  local to = message_key('mark_to', 't')
  if from and to then
    hints[#hints + 1] = from .. '/' .. to .. ' mark'
  elseif from or to then
    hints[#hints + 1] = (from or to) .. ' mark'
  end
  local apply = message_key('activate', '<CR>')
  if apply then
    hints[#hints + 1] = apply .. ' apply'
  end
  local close = message_key('toggle_range', '<Esc>')
  if close then
    hints[#hints + 1] = close .. ' close'
  end
  return #hints > 0 and ' Messages  (' .. table.concat(hints, ', ') .. ') ' or ' Messages '
end

local function show_help_hint()
  local key = help_key()
  local title = '%#Title#Opencode Session Diff%#Normal#'
  vim.wo[view.list_win].winbar = key and (title .. ('%%=%%#Comment#Help: %%#Normal#%s'):format(key:gsub('%%', '%%%%')))
    or title
end

function M.toggle_help()
  if not in_view() then
    return
  end
  if view.help_win and vim.api.nvim_win_is_valid(view.help_win) then
    vim.api.nvim_win_close(view.help_win, true)
    view.help_win = nil
    local return_win = view.help_return_win
    view.help_return_win = nil
    if return_win and vim.api.nvim_win_is_valid(return_win) then
      vim.api.nvim_set_current_win(return_win)
    end
    return
  end

  local buf, width, height = help.create(config.keymap.session_diff)
  map_actions(buf, 'help')
  view.help_return_win = vim.api.nvim_get_current_win()
  view.help_win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Diff keymaps ',
    title_pos = 'center',
  })
  vim.wo[view.help_win].wrap = false
end

local function open_turn_window()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = ''
  vim.bo[buf].modifiable = false
  local win_config = float_layout.window_configs(nil, false)
  win_config.width = math.min(assert(win_config.width), math.floor(vim.o.columns * 0.75)) --[[@as integer]]
  win_config.height = math.min(assert(win_config.height), math.max(1, #view.turns)) --[[@as integer]]
  win_config.row = math.floor((vim.o.lines - win_config.height) / 2)
  win_config.col = math.floor((vim.o.columns - win_config.width) / 2)
  win_config.title = message_title()
  win_config.title_pos = 'center'
  view.turn_buf = buf
  view.turn_win = float_layout.open_win(buf, true, win_config)
  vim.wo[view.turn_win].wrap = false
  vim.wo[view.turn_win].cursorline = true
  vim.wo[view.turn_win].number = false
  vim.wo[view.turn_win].relativenumber = false
  vim.wo[view.turn_win].signcolumn = 'no'
  map_actions(buf, 'messages')
end

local function close_turn_window()
  if view.turn_win and vim.api.nvim_win_is_valid(view.turn_win) then
    vim.api.nvim_win_close(view.turn_win, true)
  end
  view.turn_win = nil
  view.turn_buf = nil
end

function M.hide_turn_preview()
  if view and view.turn_preview_win and vim.api.nvim_win_is_valid(view.turn_preview_win) then
    vim.api.nvim_win_close(view.turn_preview_win, true)
    view.turn_preview_win = nil
  end
end

function M.show_turn_preview()
  if not in_view() or not view.range_mode then
    return
  end
  M.hide_turn_preview()
  local turn_win = assert(view.turn_win)
  local index = vim.api.nvim_win_get_cursor(turn_win)[1]
  local turn = view.turns[index]
  if not turn then
    return
  end
  local lines = vim.split(turn.text, '\n', { plain = true })
  local max_width = math.max(1, math.min(vim.o.columns - 4, 80))
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(math.min(vim.fn.strdisplaywidth(line), max_width), width)
  end
  local buf = scratch(lines, 'markdown', 'message_preview')
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - math.min(#lines, 15)) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = math.min(#lines, 15),
    style = 'minimal',
    border = 'rounded',
    title = ' User message ',
    title_pos = 'center',
    focusable = true,
  })
  view.turn_preview_win = win
  vim.wo[win].wrap = true
end

function M.toggle_range()
  if not in_view() or not view.load_turns then
    return
  end
  if view.range_mode then
    view.range_mode = false
    M.hide_turn_preview()
    close_turn_window()
    render.title(view)
    vim.api.nvim_win_set_cursor(view.list_win, { selected_row() or 1, 0 })
    vim.api.nvim_set_current_win(view.list_win)
    return
  end
  if view.loading then
    return
  end
  local current = view
  local function show(turns)
    if view ~= current or not in_view() or #turns == 0 then
      return
    end
    view.turns = turns
    view.range_mode = true
    local from = #turns
    for index, turn in ipairs(turns) do
      if turn.id == view.from then
        from = index
      end
    end
    local to = from
    for index, turn in ipairs(turns) do
      if turn.id == view.to then
        to = index
      end
    end
    view.turn_from, view.turn_to = from, to
    open_turn_window()
    render.turns(view)
    render.title(view)
    local turn_win = assert(view.turn_win)
    vim.api.nvim_win_set_cursor(turn_win, { from, 0 })
  end
  if #view.turns > 0 then
    show(view.turns)
    return
  end
  view.loading = true
  view
    .load_turns()
    :and_then(function(turns)
      if view == current then
        view.loading = false
        show(turns)
      end
    end)
    :catch(function(err)
      if view == current then
        view.loading = false
        vim.notify('Failed to load session turns: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end)
end

function M.mark_range(endpoint)
  if not in_view() or not view.range_mode then
    return
  end
  local turn_win = assert(view.turn_win)
  local index = vim.api.nvim_win_get_cursor(turn_win)[1]
  if endpoint == 'from' and index > view.turn_to or endpoint == 'to' and index < view.turn_from then
    vim.notify('Range end must be at or after its start.', vim.log.levels.WARN)
    return
  end
  if endpoint == 'from' then
    view.turn_from = index
  else
    view.turn_to = index
  end
  render.turns(view)
  render.title(view)
end

scratch = function(lines, filetype, scope)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  map_actions(buf, scope or 'preview')
  return buf
end

local function set_preview(win, lines, filetype)
  vim.api.nvim_win_set_buf(win, scratch(lines, filetype))
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.wo[win].signcolumn = 'yes:1'
end

local function refresh_comments()
  render.comments(view)
  render.tree(view, file_icon)
  render.title(view)
end

---@param win integer
---@param first integer
---@param last integer
---@return OpencodeReviewCommentSide?, integer?, integer?, string?, integer?
local function comment_range(win, first, last)
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local side = view.sides[win]
  if side then
    return side, first, last, table.concat(lines, '\n'), first
  end
  local map = view.patch_map
  local chosen
  for row = first, last do
    local entry = map[row]
    if entry and entry.new then
      chosen = 'after'
      break
    elseif entry and entry.old then
      chosen = 'before'
    end
  end
  if not chosen then
    return nil
  end
  local start_line, end_line, anchor
  local code = {}
  for row = first, last do
    local entry = map[row]
    local number = entry and (chosen == 'after' and entry.new or nil)
    if entry and chosen == 'before' then number = entry.old end
    if number then
      start_line = start_line or number
      end_line = number
      anchor = anchor or entry.new or (map[row + 1] and map[row + 1].new) or number
    end
    if entry and (entry.old or entry.new) then
      code[#code + 1] = (assert(lines[row - first + 1])):sub(2)
    end
  end
  if chosen == 'before' then
    local after_line = anchor
    for row = last + 1, #map do
      if map[row].new then after_line = map[row].new; break end
    end
    anchor = after_line
  end
  return chosen, start_line, end_line, table.concat(code, '\n'), anchor
end

local function current_comment(file, side, number)
  for _, comment in ipairs(context.get_review_comments(file.file)) do
    if comment.session_id == view.session.id and comment.from == view.from and comment.to == view.to
      and comment.side == side and number and number >= comment.start_line and number <= comment.end_line then
      return comment
    end
  end
end

function M.add_comment()
  if not in_view() or not context.is_context_enabled('review_comments') then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local visual = vim.fn.mode():match('^[vV\22]') ~= nil
  local first, last = vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_win_get_cursor(win)[1]
  if visual then
    first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  end
  local side, start_line, end_line, code, anchor = comment_range(win, first, last)
  if not side or not start_line or not end_line then
    vim.notify('Select a code line in the diff.', vim.log.levels.WARN)
    return
  end
  local file = assert(view.files[view.index])
  local existing = not visual and current_comment(file, side, start_line) or nil
  local after = view.after_lines
  local context_start = side == 'before' and (anchor or start_line) or start_line
  local context_end = end_line
  if side == 'before' and not existing then
    context_end = context_start - 1
    local map = view.patch_map
    local patch_lines = view.patch_lines
    for row, entry in ipairs(map) do
      if entry.new == context_start and patch_lines[row]:sub(1, 1) == '+' then
        context_end = context_start
        break
      end
    end
  end
  local preceding, following = {}, {}
  if not existing then
    if view.mode == 'sides' then
      local context_win = side == 'before' and assert(view.right_win) or win
      local context_buf = vim.api.nvim_win_get_buf(context_win)
      preceding = vim.api.nvim_buf_get_lines(context_buf, math.max(0, context_start - 4), context_start - 1, false)
      following = vim.api.nvim_buf_get_lines(context_buf, context_end, context_end + 3, false)
    else
      preceding = vim.list_slice(after or {}, math.max(1, context_start - 3), context_start - 1)
      following = vim.list_slice(after or {}, context_end + 1, context_end + 3)
    end
  end
  comment_input.open({
    title = ('%s:%d-%d (%s)'):format(vim.fn.fnamemodify(file.file, ':t'), start_line, end_line, side),
    text = existing and existing.comment,
    on_submit = function(text)
      if existing then
        if text == '' then context.remove_review_comment(existing.id) else context.update_review_comment(existing.id, text) end
      elseif text ~= '' then
        context.add_review_comment({ id = 0, file = file.file, side = side, start_line = start_line,
          end_line = end_line, code = code, comment = text, session_id = view.session.id,
          from = view.from, to = view.to, context_before = preceding, context_after = following,
          anchor_side_line = anchor or start_line })
      end
      refresh_comments()
    end,
  })
end

function M.delete_comment()
  if not in_view() then return end
  local win = vim.api.nvim_get_current_win()
  local side, number = comment_range(win, vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_win_get_cursor(win)[1])
  local comment = current_comment(assert(view.files[view.index]), side, number)
  if comment then
    context.remove_review_comment(comment.id)
    refresh_comments()
  end
end

function M.jump_comment(direction)
  if not in_view() then return end
  local win = vim.api.nvim_get_current_win()
  local file = assert(view.files[view.index])
  local map = view.mode == 'patch' and view.patch_map or nil
  local rows = {}
  for _, comment in ipairs(context.get_review_comments(file.file)) do
    if comment.session_id == view.session.id and comment.from == view.from and comment.to == view.to then
      if map then
        for row, entry in ipairs(map) do
          local number = comment.side == 'after' and entry.new or nil
          if comment.side == 'before' then number = entry.old end
          if number == comment.start_line then rows[#rows + 1] = row end
        end
      elseif view.sides[win] == comment.side then
        rows[#rows + 1] = comment.start_line
      end
    end
  end
  table.sort(rows)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  if direction > 0 then
    for _, row in ipairs(rows) do
      if row > cursor then vim.api.nvim_win_set_cursor(win, { row, 0 }); return end
    end
    if rows[1] then vim.api.nvim_win_set_cursor(win, { rows[1], 0 }) end
  else
    for index = #rows, 1, -1 do
      if rows[index] < cursor then vim.api.nvim_win_set_cursor(win, { rows[index], 0 }); return end
    end
    if rows[#rows] then vim.api.nvim_win_set_cursor(win, { rows[#rows], 0 }) end
  end
end

local function update()
  local file = assert(view.files[view.index])
  local filetype = vim.filetype.match({ filename = file.file }) or vim.fn.fnamemodify(file.file, ':e')
  view.patch_map = patch.line_map(file.patch)
  view.patch_lines = vim.split(file.patch, '\n', { plain = true, trimempty = true })
  view.before_lines, view.after_lines = patch.sides(file.patch)
  if view.mode == 'sides' then
    local before, after = view.before_lines, view.after_lines
    if not before then
      vim.notify('Side-by-side unavailable for this patch; showing unified diff.', vim.log.levels.WARN)
      M.show_patch()
      return
    end
    vim.api.nvim_win_call(view.preview_win, function()
      vim.cmd('diffoff')
    end)
    local right_win = assert(view.right_win)
    vim.api.nvim_win_call(right_win, function()
      vim.cmd('diffoff')
    end)
    set_preview(view.preview_win, before, filetype)
    set_preview(right_win, after, filetype)
    view.sides = { [view.preview_win] = 'before', [right_win] = 'after' }
    vim.wo[view.preview_win].winbar = 'Before: ' .. file.file
    vim.wo[right_win].winbar = 'After: ' .. file.file
    vim.api.nvim_win_call(view.preview_win, function()
      vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(right_win, function()
      vim.cmd('diffthis')
    end)
  else
    set_preview(view.preview_win, vim.split(file.patch, '\n', { plain = true, trimempty = true }), 'diff')
    view.sides = {}
    vim.wo[view.preview_win].winbar = file.file
  end
  render.comments(view)
end

function M.show_patch()
  if not in_view() or view.mode ~= 'sides' then
    return
  end
  vim.api.nvim_win_call(view.preview_win, function()
    vim.cmd('diffoff')
  end)
  local right_win = assert(view.right_win)
  vim.api.nvim_win_call(right_win, function()
    vim.cmd('diffoff')
  end)
  vim.api.nvim_win_close(right_win, true)
  view.right_win = nil
  view.mode = 'patch'
  update()
end

function M.show_sides()
  if not in_view() or view.mode == 'sides' or #view.files == 0 then
    return
  end
  local file = assert(view.files[view.index])
  if not patch.sides(file.patch) then
    vim.notify('Side-by-side unavailable for this patch.', vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(view.preview_win)
  vim.cmd('rightbelow vsplit')
  view.right_win = vim.api.nvim_get_current_win()
  view.mode = 'sides'
  update()
  vim.api.nvim_set_current_win(view.list_win)
end

function M.toggle_view()
  if not in_view() then
    return
  end
  if view.mode == 'sides' then
    M.show_patch()
  else
    M.show_sides()
  end
end

function M.activate()
  if not in_view() then
    return
  end
  local row = vim.api.nvim_win_get_cursor(view.list_win)[1]
  if view.range_mode then
    local turns = view.turns
    local from = (turns[view.turn_from] --[[@as {id: string, text: string}]]).id
    local to = (turns[view.turn_to] --[[@as {id: string, text: string}]]).id
    local review_range = view.review_range --[[@as fun(from: string, to?: string, message_count?: integer): Promise<nil>]]
    review_range(from, from ~= to and to or nil, view.turn_to - view.turn_from + 1)
    return
  end
  local node = assert(view.rows[row])
  if node == view.tree then
    return
  end
  if node.file_index then
    view.index = node.file_index
    if view.mode == 'patch' then
      M.show_sides()
    else
      update()
    end
    return
  end
  node.expanded = not node.expanded
  render.tree(view, file_icon)
  render.title(view)
  vim.api.nvim_win_set_cursor(view.list_win, { row, 0 })
end

function M.select(direction)
  if not active() then
    return false
  end
  vim.api.nvim_set_current_tabpage(view.tab)
  if view.range_mode then
    M.toggle_range()
  end
  local rows = {}
  for row, node in ipairs(view.rows) do
    if node.file_index then
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then
    return true
  end
  local current = 0
  for position, row in ipairs(rows) do
    if view.rows[row].file_index == view.index then
      current = position
      break
    end
  end
  local row = assert(rows[(current - 1 + direction) % #rows + 1])
  local node = view.rows[row] --[[@as OpencodeSessionDiffNode]]
  view.index = node.file_index --[[@as integer]]
  vim.api.nvim_win_set_cursor(view.list_win, { row, 0 })
  update()
  return true
end

---@param path string
---@param from string
---@param session_id string
---@return boolean
function M.toggle_file(path, from, session_id)
  if not active() or view.session.id ~= session_id or view.from ~= from then
    return false
  end
  local target = vim.fn.fnamemodify(util.apply_reverse_path_map(path), ':p')
  for index, file in ipairs(view.files) do
    if vim.fn.fnamemodify(file.file, ':p') == target then
      if view.index == index and not view.range_mode then
        local caller_tab = vim.api.nvim_get_current_tabpage()
        M.close()
        if vim.api.nvim_tabpage_is_valid(caller_tab) then
          vim.api.nvim_set_current_tabpage(caller_tab)
        end
        return true
      end
      vim.api.nvim_set_current_tabpage(view.tab)
      if view.range_mode then
        M.toggle_range()
      end
      view.index = index
      local row = selected_row()
      if not row then
        local function expand(node)
          node.expanded = true
          for _, child in ipairs(node.children) do
            expand(child)
          end
        end
        expand(view.tree)
        render.tree(view, file_icon)
        render.title(view)
        row = assert(selected_row())
      end
      vim.api.nvim_win_set_cursor(view.list_win, { row, 0 })
      update()
      vim.api.nvim_set_current_win(view.list_win)
      return true
    end
  end
  vim.notify('File not found in selected turn diff: ' .. path, vim.log.levels.WARN)
  return true
end

---@param opts? {focus_input?: boolean}
function M.close(opts)
  if active() then
    vim.api.nvim_set_current_tabpage(view.tab)
    vim.cmd('tabclose')
  end
  view = nil
  if opts and opts.focus_input and #context.get_review_comments() > 0 then
    vim.schedule(function()
      require('opencode.ui.ui').focus_input({ restore_position = false, start_insert = true })
    end)
  end
end

---@param files OpencodeV2FileDiff[]
---@param session {id: string, title?: string}
---@param options? OpencodeSessionDiffOptions
function M.open(files, session, options)
  local index = 1
  if options and options.file then
    local target = vim.fn.fnamemodify(util.apply_reverse_path_map(options.file), ':p')
    local selected
    for file_index, file in ipairs(files) do
      if vim.fn.fnamemodify(file.file, ':p') == target then
        selected = file_index
        break
      end
    end
    if not selected then
      vim.notify('File not found in selected turn diff: ' .. options.file, vim.log.levels.WARN)
      return
    end
    index = selected
  end
  M.close()
  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()
  local list_win = vim.api.nvim_get_current_win()
  local list_buf = scratch({}, '', 'list')
  vim.api.nvim_win_set_buf(list_win, list_buf)
  vim.wo[list_win].winbar = ''
  vim.wo[list_win].number = false
  vim.wo[list_win].relativenumber = false
  vim.wo[list_win].signcolumn = 'no'
  vim.wo[list_win].cursorline = true
  vim.cmd('rightbelow vsplit')
  local preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(list_win)
  vim.api.nvim_win_set_width(list_win, math.min(42, math.max(24, math.floor(vim.o.columns / 3))))
  vim.wo[list_win].winfixwidth = true
  local range_key
  local message_count
  if options and options.load_turns then
    range_key = list_key('toggle_range', 'r')
  end
  if options and options.message_count then
    message_count = options.message_count
  elseif options and (not options.to or options.from == options.to) then
    message_count = 1
  end
  view = {
    tab = tab,
    list_win = list_win,
    list_buf = list_buf,
    preview_win = preview_win,
    files = files,
    tree = render.build_tree(files),
    rows = {},
    index = index,
    mode = 'patch',
    sides = {},
    patch_map = {},
    patch_lines = {},
    session = session,
    range_mode = false,
    turns = {},
    message_count = message_count,
    turn_from = 0,
    turn_to = 0,
    from = options and options.from,
    to = options and options.to,
    range_key = range_key,
    load_turns = options and options.load_turns,
    review_range = options and options.review_range,
  }
  show_help_hint()
  render.tree(view, file_icon)
  render.title(view)

  vim.api.nvim_create_autocmd('WinResized', {
    group = vim.api.nvim_create_augroup('OpencodeSessionDiffTitle', { clear = true }),
    callback = function()
      if active() then
        render.title(view)
        if view.range_mode then
          render.turns(view)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = list_buf,
    callback = function()
      if not in_view() then
        return
      end
      local row = vim.api.nvim_win_get_cursor(list_win)[1]
      if row == 1 and (view.range_mode or #view.rows > 1) then
        vim.api.nvim_win_set_cursor(list_win, { 2, 0 })
        return
      end
      if view.range_mode then
        if row > 2 and row % 2 == 1 then
          vim.api.nvim_win_set_cursor(list_win, { row - 1, 0 })
        end
        return
      end
      local node = view.rows[row]
      if node and node.file_index and node.file_index ~= view.index then
        view.index = node.file_index
        update()
      end
    end,
  })
  if #files > 0 then
    vim.api.nvim_win_set_cursor(list_win, { assert(selected_row()), 0 })
    M.show_sides()
  else
    set_preview(preview_win, { 'No changes in selected turn.' }, '')
  end
  vim.api.nvim_set_current_win(list_win)
end

return M
