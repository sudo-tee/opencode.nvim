local M = {}
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local session_runtime = require('opencode.services.session_runtime')

---Format session parts for session picker
---@param session Session|GlobalSession object
---@param width? integer
---@return PickerItem
local function format_session_item(session, width)
  local project = (session --[[@as GlobalSession]]).project
  local title = session.title or 'N/A'
  if project then
    local label = project.name or vim.fn.pathshorten(project.worktree) or project.id or '?'
    title = title .. '  [' .. label .. ']'
  end
  local updated_time = (session.time and session.time.updated) or 'N/A'
  return base_picker.create_time_picker_item(title, updated_time, nil, width)
end

--- Append extmarks from source into target, offset by line_offset
--- Uses append semantics (no overwrite of same-line marks)
---@param target table<number, OutputExtmark[]> Target extmark map
---@param extmarks table<number, OutputExtmark[]> Source extmark map
---@param line_offset integer Line offset for source marks
local function append_extmarks(target, extmarks, line_offset)
  for line_idx, marks in pairs(extmarks or {}) do
    local actual = line_idx + line_offset
    target[actual] = target[actual] or {}
    for _, mark in ipairs(marks) do
      table.insert(target[actual], mark)
    end
  end
end

---Keep the first user entry and last assistant entry in a compact preview.
---@param entries table[]
---@return table[], integer omitted_count
local function filter_preview_entries(entries)
  if #entries <= 2 then
    return entries, 0
  end
  local first_user_idx = nil
  local last_assistant_idx = nil
  for i, entry in ipairs(entries) do
    if entry.kind == 'user' and not first_user_idx then
      first_user_idx = i
    end
    if entry.kind == 'assistant' then
      last_assistant_idx = i
    end
  end
  local result = {}
  if first_user_idx then
    table.insert(result, entries[first_user_idx])
  end
  if last_assistant_idx then
    table.insert(result, entries[last_assistant_idx])
  end
  if #result == 0 then
    return entries, 0
  end
  local omitted = #entries - #result
  return result, omitted
end

---@param entries table[]
---@param omitted_count? integer Number of messages omitted between first and second (for preview)
---@return { lines: string[], extmarks: table<number, OutputExtmark[]>, fold_ranges: table<{from: integer, to: integer}> }
local function format_entries(entries, omitted_count)
  local formatter = require('opencode.ui.formatter')
  local all_lines = {}
  local all_extmarks = {}
  local all_fold_ranges = {}
  local line_offset = 0
  local rendered_count = 0

  for _, entry in ipairs(entries) do
    if rendered_count == 1 and omitted_count and omitted_count > 0 then
      local notice = string.format('  ⋯ %d message(s) omitted ⋯', omitted_count)
      vim.list_extend(all_lines, { '', notice, '' })
      line_offset = line_offset + 3
    end

    local header = formatter.format_message_header(entry)
    vim.list_extend(all_lines, header.lines)
    append_extmarks(all_extmarks, header.extmarks, line_offset)
    for _, range in ipairs(header.fold_ranges or {}) do
      table.insert(all_fold_ranges, {
        from = range.from + line_offset,
        to = range.to + line_offset,
      })
    end
    line_offset = line_offset + #header.lines

    local content = entry.content or {}
    for content_idx, part in ipairs(content) do
      local part_output = formatter.format_part(part, entry, content_idx == #content, {
        interactive = false,
        get_child_parts = nil,
      })
      vim.list_extend(all_lines, part_output.lines)
      append_extmarks(all_extmarks, part_output.extmarks, line_offset)
      for _, range in ipairs(part_output.fold_ranges or {}) do
        table.insert(all_fold_ranges, {
          from = range.from + line_offset,
          to = range.to + line_offset,
        })
      end
      line_offset = line_offset + #part_output.lines
    end

    rendered_count = rendered_count + 1
  end

  return {
    lines = all_lines,
    extmarks = all_extmarks,
    fold_ranges = all_fold_ranges,
  }
end

local function session_location(session)
  if session.location ~= nil then
    return session.location
  end
  if type(session.directory) == 'string' then
    return { directory = session.directory }
  end
  return nil
end

local function session_ref(session)
  if type(session) ~= 'table' or type(session.id) ~= 'string' then
    error('Session picker requires a Session')
  end
  return { id = session.id, location = session_location(session) }
end

local function ordered_entries(observation)
  local observed = observation:read()
  local entries = {}
  for _, entry_id in ipairs(observed.entry_order or {}) do
    local entry = observed.entries_by_id and observed.entries_by_id[entry_id]
    if entry then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

--- Write formatted output to a preview buffer
---@param target PickerPreviewTarget
---@param formatted { lines: string[], extmarks: table, fold_ranges: table }
local function render_preview_buffer(target, formatted)
  if not target:is_valid() then
    return
  end
  local bufnr = target:get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local output_window = require('opencode.ui.output_window')

  target:set_lines(formatted.lines)
  bufnr = target:get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear old extmarks then apply new ones
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, output_window.namespace, 0, -1)
  output_window.apply_extmarks(bufnr, formatted.extmarks)

  -- Configure preview window to match the main output window's gutter.
  -- The formatter places vertical border extmarks at virt_text_win_col = -3
  -- which requires a 3-column gutter (signcolumn=yes + foldcolumn=1) so
  -- the border renders in the gutter instead of overlaying column 0 of text.
  target:with_window(function()
    vim.api.nvim_set_option_value('number', false, { win = 0 })
    vim.api.nvim_set_option_value('relativenumber', false, { win = 0 })
    vim.api.nvim_set_option_value('signcolumn', 'yes', { win = 0 })
    vim.api.nvim_set_option_value('foldcolumn', '1', { win = 0 })
    vim.api.nvim_set_option_value('statuscolumn', '', { win = 0 })
    vim.api.nvim_set_option_value('foldmethod', 'manual', { win = 0 })
    vim.cmd('silent! normal! zE') -- clear existing manual folds
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for _, range in ipairs(formatted.fold_ranges) do
      if range.from <= line_count and range.to <= line_count then
        vim.cmd(range.from .. ',' .. range.to .. 'fold')
      end
    end
  end)
end

---Prompt for a session title and return the renamed session, or nil on cancellation/failure.
---@param session Session
---@return Promise<Session|nil>
function M.rename(session)
  local promise = Promise.new()
  vim.schedule(function()
    vim.ui.input({ prompt = 'New session name: ', default = session.title or '' }, function(input)
      if not input or input == '' then
        promise:resolve(nil)
        return
      end
      session_runtime.rename_session(session, input):and_then(function(updated)
        promise:resolve(updated)
      end):catch(function(err)
        vim.schedule(function()
          vim.notify('Failed to rename session: ' .. vim.inspect(err), vim.log.levels.ERROR)
          promise:resolve(nil)
        end)
      end)
    end)
  end)
  return promise
end

---@param sessions Session[]
---@param callback fun(session: Session|nil)
---@param opts? { scope?: 'project' | 'global' }
function M.pick(sessions, callback, opts)
  opts = opts or {}
  local connection = require('opencode.state').opencode_server
  local preview_unsubscribe

  local function release_preview()
    if preview_unsubscribe then
      preview_unsubscribe()
      preview_unsubscribe = nil
    end
  end

  local function finish(selected)
    release_preview()
    callback(selected)
  end

  local actions = {
    rename = {
      key = config.keymap.session_picker.rename_session,
      label = 'rename',
      fn = function(selected, opts)
        return M.rename(selected):and_then(function(updated_session)
          if not updated_session then
            return nil
          end
          local idx = util.find_index_of(opts.items, function(item)
            return item.id == updated_session.id
          end)
          if idx > 0 then
            opts.items[idx] = updated_session
          end
          return opts.items
        end)
      end,
      reload = true,
    },
    delete = {
      key = config.keymap.session_picker.delete_session,
      label = 'del',
      fn = Promise.async(function(selected, opts)
        local sessions_to_delete = type(selected) == 'table' and selected.id == nil and selected or { selected }
        session_runtime.delete_sessions(sessions_to_delete, opts.items or {}, function(session)
          local idx = util.find_index_of(opts.items, function(item)
            return item.id == session.id
          end)
          if idx > 0 then
            table.remove(opts.items, idx)
          end
        end):await()

        vim.notify('Deleted ' .. #sessions_to_delete .. ' session(s)', vim.log.levels.INFO)
        return opts.items
      end),
      multi_selection = true,
      reload = true,
    },
    new = {
      key = config.keymap.session_picker.new_session,
      label = 'new',
      fn = Promise.async(function(selected, opts)
        local parent_id
        for _, s in ipairs(opts.items or {}) do
          if s.parentID ~= nil then
            parent_id = s.parentID
            break
          end
        end

        local new_session = session_runtime.create_new_session(parent_id and { parentID = parent_id } or false):await()
        if new_session then
          table.insert(opts.items, 1, new_session)
          return opts.items
        end
      end),
      reload = true,
    },
    open_in_tab = {
      key = config.keymap.session_picker.open_in_tab,
      label = 'tab',
      fn = Promise.async(function(selected, opts)
        local sessions = type(selected) == 'table' and selected.id == nil and selected or { selected }

        if opts.close then
          opts.close()
          Promise.delay(0):await()
        end

        for _, session in ipairs(sessions) do
          session_runtime.open_session_in_tab(session):await()
          Promise.delay(0):await()
        end
      end),
      multi_selection = true,
    },
    fork = {
      key = config.keymap.session_picker.fork_session,
      label = 'fork',
      fn = Promise.async(function(selected, opts)
        local new_session = session_runtime.fork_session(selected):await()
        if new_session then
          session_runtime.select_session(new_session):await()
          table.insert(opts.items, 1, new_session)
          return opts.items
        end
      end),
      reload = true,
    },
    toggle = {
      key = config.keymap.session_picker.toggle_scope,
      label = 'scope',
      fn = Promise.async(function(_, _)
        local new_scope = (opts.scope == 'global') and 'project' or 'global'
        local new_sessions = Promise.wrap(session_runtime.list_sessions_by_scope(new_scope)):await()
        local filtered_sessions = session_runtime.filter_pickable_sessions(new_sessions, nil)
        opts.scope = new_scope
        return filtered_sessions
      end),
      reload = true,
    },
  }
  local preview_seq = 0

  return base_picker.pick({
    items = sessions,
    format_fn = format_session_item,
    actions = actions,
    multi_select_fn = actions.open_in_tab.fn,
    callback = finish,
    title = (opts and opts.scope == 'global') and 'Select A Session (all projects)' or 'Select A Session',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
    preview = 'custom',
    ---@param session table
    ---@param target PickerPreviewTarget
    preview_fn = function(session, target)
      release_preview()
      preview_seq = preview_seq + 1
      local current_seq = preview_seq
      target:set_lines({ 'Loading...' })

      local observation = connection:observe(session_ref(session))
      local released = false
      local unsubscribe
      local function release()
        if released then
          return
        end
        released = true
        if unsubscribe then
          unsubscribe()
        end
        if preview_unsubscribe == release then
          preview_unsubscribe = nil
        end
      end
      local function render(observed_session)
        if current_seq ~= preview_seq or not target:is_valid() then
          release()
          return
        end
        local observed = observed_session:read()
        local sync = observed.sync and observed.sync.messages
        if sync and sync.state == 'current' then
          local entries = ordered_entries(observed_session)
          release()
          if #entries == 0 then
            target:set_lines({ 'No messages' })
            return
          end
          local preview_entries, omitted = filter_preview_entries(entries)
          render_preview_buffer(target, format_entries(preview_entries, omitted))
        elseif sync and (sync.state == 'error' or sync.state == 'unsupported') then
          release()
          target:set_lines({ 'Failed to load messages' })
        end
      end

      local ok, result = pcall(function()
        return observation:watch({ 'messages' }, render)
      end)
      if not ok then
        target:set_lines({ 'Failed to load messages' })
        return
      end
      unsubscribe = result
      if released then
        unsubscribe()
        return
      end
      preview_unsubscribe = release
      render(observation)
    end,
  })
end

---@param sessions Session[]
---@param cb fun(session: Session|nil)
---@param opts? { scope?: 'project' | 'global' }
function M.select(sessions, cb, opts)
  local picker = require('opencode.ui.picker')

  local success = M.pick(sessions, cb, opts)
  if not success then
    picker.select(sessions, {
      prompt = '',
      format_item = function(session)
        local parts = {}

        if session.title then
          table.insert(parts, session.title)
        else
          table.insert(parts, session.id)
        end

        local modified = util.format_time(session.modified)
        if modified then
          table.insert(parts, modified)
        end

        return table.concat(parts, ' ~ ')
      end,
    }, function(session_choice)
      cb(session_choice)
    end)
  end
end

return M
