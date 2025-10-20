local M = {}
local picker = require('opencode.ui.picker')

local picker_title = function()
  local config = require('opencode.config')
  local delete_config = config.keymap.session_picker.delete_session
  local delete_key = delete_config and '  | ' .. delete_config[1] .. ' to delete' or ''
  return 'Select A Session' .. delete_key
end

local function format_session(session)
  local util = require('opencode.util')
  local parts = {}

  if session.description then
    table.insert(parts, session.description)
  end

  if session.message_count then
    table.insert(parts, session.message_count .. ' messages')
  end

  local modified = util.time_ago(session.modified)
  if modified then
    table.insert(parts, modified)
  end

  table.insert(parts, 'ID: ' .. (session.id or 'N/A'))
  return table.concat(parts, ' ~ ')
end

local function telescope_ui(sessions, callback, on_delete, on_new)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  local current_picker

  local function refresh_picker()
    local new_sessions = vim.tbl_filter(function(s)
      return sessions[vim.fn.index(sessions, s) + 1] ~= nil
    end, sessions)
    sessions = new_sessions

    current_picker:refresh(
      finders.new_table({
        results = sessions,
        entry_maker = function(session)
          return {
            value = session,
            display = format_session(session),
            ordinal = format_session(session),
          }
        end,
      }),
      { reset_prompt = false }
    )
  end

  current_picker = pickers.new({}, {
    prompt_title = picker_title(),
    finder = finders.new_table({
      results = sessions,
      entry_maker = function(session)
        return {
          value = session,
          display = format_session(session),
          ordinal = format_session(session),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection and callback then
          callback(selection.value)
        end
      end)

      local config = require('opencode.config')
      local delete_config = config.keymap.session_picker.delete_session
      if delete_config and delete_config[1] then
        local key = delete_config[1]
        local modes = delete_config.mode or { 'i', 'n' }
        if type(modes) == 'string' then
          modes = { modes }
        end

        local delete_fn = function()
          local selection = action_state.get_selected_entry()
          if selection and on_delete then
            local idx = vim.fn.index(sessions, selection.value) + 1
            if idx > 0 then
              table.remove(sessions, idx)
              on_delete(selection.value)
              refresh_picker()
            end
          end
        end

        for _, mode in ipairs(modes) do
          map(mode, key, delete_fn)
        end
      end

      -- Add new session mapping using shared callback
      local new_config = require('opencode.config').keymap.session_picker.new_session
      if new_config and new_config[1] then
        local key = new_config[1]
        local modes = new_config.mode or { 'i', 'n' }
        if type(modes) == 'string' then
          modes = { modes }
        end
        local new_fn = function()
          if on_new then
            local new_session = on_new()
            if new_session then
              actions.close(prompt_bufnr)
              if callback then
                callback(new_session)
              end
            end
          end
        end
        for _, mode in ipairs(modes) do
          map(mode, key, new_fn)
        end
      end

      return true
    end,
  })

  current_picker:find()
end

local function fzf_ui(sessions, callback, on_delete, on_new)
  local fzf_lua = require('fzf-lua')
  local config = require('opencode.config')

  local actions_config = {
    ['default'] = function(selected, opts)
      if not selected or #selected == 0 then
        return
      end
      local idx = opts.fn_fzf_index(selected[1])
      if idx and sessions[idx] and callback then
        callback(sessions[idx])
      end
    end,
  }

  local delete_config = config.keymap.session_picker.delete_session
  if delete_config and delete_config[1] then
    local key = delete_config[1]
    key = require('fzf-lua.utils').neovim_bind_to_fzf(key)
    actions_config[key] = {
      fn = function(selected, opts)
        if not selected or #selected == 0 then
          return
        end
        local idx = opts.fn_fzf_index(selected[1])
        if idx and sessions[idx] and on_delete then
          local session = sessions[idx]
          table.remove(sessions, idx)
          on_delete(session)
        end
      end,
      header = 'delete',
      reload = true,
    }
  end

  -- New session action (shared on_new)
  local new_config = config.keymap.session_picker.new_session
  if new_config and new_config[1] then
    local key = require('fzf-lua.utils').neovim_bind_to_fzf(new_config[1])
    actions_config[key] = {
      fn = function()
        if on_new then
          local new_session = on_new()
          if new_session then
            table.insert(sessions, 1, new_session)
          end
        end
      end,
      header = 'new',
      reload = true,
    }
  end

  fzf_lua.fzf_exec(function(fzf_cb)
    for _, session in ipairs(sessions) do
      fzf_cb(format_session(session))
    end
    fzf_cb()
  end, {
    fzf_opts = {
      ['--prompt'] = picker_title() .. ' > ',
    },
    _headers = { 'actions' },
    actions = actions_config,
    fn_fzf_index = function(line)
      for i, session in ipairs(sessions) do
        if format_session(session) == line then
          return i
        end
      end
      return nil
    end,
  })
end

local function mini_pick_ui(sessions, callback, on_delete, on_new)
  local mini_pick = require('mini.pick')
  local config = require('opencode.config')

  local items = vim.tbl_map(function(session)
    return {
      text = format_session(session),
      session = session,
    }
  end, sessions)

  local delete_config = config.keymap.session_picker.delete_session
  local mappings = {}

  if delete_config and delete_config[1] then
    mappings.delete_session = {
      char = delete_config[1],
      func = function()
        local selected = mini_pick.get_picker_matches().current
        if selected and selected.session and on_delete then
          local idx = vim.fn.index(sessions, selected.session) + 1
          if idx > 0 then
            table.remove(sessions, idx)
            on_delete(selected.session)
            items = vim.tbl_map(function(session)
              return {
                text = format_session(session),
                session = session,
              }
            end, sessions)
            mini_pick.set_picker_items(items)
          end
        end
      end,
    }
  end

  -- New session mapping using shared on_new
  local new_config = config.keymap.session_picker.new_session
  if new_config and new_config[1] then
    mappings.new_session = {
      char = new_config[1],
      func = function()
        if on_new then
          local new_session = on_new()
          if new_session then
            table.insert(sessions, 1, new_session)
            items = vim.tbl_map(function(session)
              return {
                text = format_session(session),
                session = session,
              }
            end, sessions)
            mini_pick.set_picker_items(items)
          end
        end
      end,
    }
  end

  mini_pick.start({
    source = {
      items = items,
      name = picker_title(),
      choose = function(selected)
        if selected and selected.session and callback then
          callback(selected.session)
        end
        return false
      end,
    },
    mappings = mappings,
  })
end

local function snacks_picker_ui(sessions, callback, on_delete, on_new)
  local Snacks = require('snacks')
  local config = require('opencode.config')

  local delete_config = config.keymap.session_picker.delete_session

  local opts = {
    title = picker_title(),
    layout = { preset = 'select' },
    finder = function()
      return sessions
    end,
    format = 'text',
    transform = function(item)
      item.text = format_session(item)
    end,
    actions = {
      confirm = function(picker, item)
        picker:close()
        if item and callback then
          vim.schedule(function()
            callback(item)
          end)
        end
      end,
    },
  }

  if delete_config and delete_config[1] then
    local key = delete_config[1]
    local mode = delete_config.mode or 'i'

    opts.win = opts.win or {}
    opts.win.input = opts.win.input or { keys = {} }
    opts.win.input.keys[key] = { 'session_delete', mode = mode }

    opts.actions.session_delete = function(picker, item)
      if item and on_delete then
        vim.schedule(function()
          local idx = vim.fn.index(sessions, item) + 1
          if idx > 0 then
            table.remove(sessions, idx)
            on_delete(item)
            picker:find()
          end
        end)
      end
    end
  end

  -- New session key using shared on_new
  local new_config = config.keymap.session_picker.new_session
  if new_config and new_config[1] then
    local key = new_config[1]
    local mode = new_config.mode or 'i'

    opts.win = opts.win or {}
    opts.win.input = opts.win.input or { keys = {} }
    opts.win.input.keys[key] = { 'session_new', mode = mode }

    opts.actions.session_new = function(picker)
      vim.schedule(function()
        if on_new then
          local new_session = on_new()
          if new_session then
            table.insert(sessions, 1, new_session)
            picker:close()
            if callback then
              callback(new_session)
            end
          end
        end
      end)
    end
  end

  Snacks.picker.pick(opts)
end

function M.pick(sessions, callback)
  local picker_type = picker.get_best_picker()

  if not picker_type then
    return false
  end

  local function on_delete(session)
    local state = require('opencode.state')

    local session_id_to_delete = session.id

    if state.active_session and state.active_session.id == session.id then
      vim.notify('deleting current session, creating new session')
      state.active_session = require('opencode.core').create_new_session()
    end

    state.api_client:delete_session(session_id_to_delete):catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to delete session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
  end

  local function on_new()
    local parent_id
    for _, s in ipairs(sessions or {}) do
      if s.parentID ~= nil then
        parent_id = s.parentID
        break
      end
    end
    local state = require('opencode.state')
    local created = state.api_client:create_session(parent_id and { parentID = parent_id } or false):wait()
    if created and created.id then
      return require('opencode.session').get_by_id(created.id)
    end
    return nil
  end

  vim.schedule(function()
    if picker_type == 'telescope' then
      telescope_ui(sessions, callback, on_delete, on_new)
    elseif picker_type == 'fzf' then
      fzf_ui(sessions, callback, on_delete, on_new)
    elseif picker_type == 'mini.pick' then
      mini_pick_ui(sessions, callback, on_delete, on_new)
    elseif picker_type == 'snacks' then
      snacks_picker_ui(sessions, callback, on_delete, on_new)
    else
      callback(nil)
    end
  end)

  return true
end

return M
