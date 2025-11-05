local M = {}
local picker = require('opencode.ui.picker')
local config = require('lua.opencode.config')

local picker_title = function()
  local config = require('opencode.config') --[[@as OpencodeConfig]]
  local keymap_config = config.keymap.timeline_picker or {}

  local legend = {}
  local actions = {
    { key = keymap_config.undo, label = 'undo' },
    { key = keymap_config.fork, label = 'fork' },
  }

  for _, action in ipairs(actions) do
    if action.key and action.key[1] then
      table.insert(legend, action.key[1] .. ' ' .. action.label)
    end
  end

  return 'Timeline' .. (#legend > 0 and ' | ' .. table.concat(legend, ' | ') or '')
end

local function format_message(msg)
  local util = require('opencode.util')
  local parts = {}
  local length_limit = config.debug and 50 or 70

  local preview = msg.parts and msg.parts[1] and msg.parts[1].text or ''
  if #preview > length_limit then
    preview = preview:sub(1, length_limit - 3) .. '...'
  end

  if preview and preview ~= '' then
    table.insert(parts, preview)
  end

  local time_str = util.format_time(msg.info.time.created)
  if time_str then
    table.insert(parts, time_str)
  end

  if config.debug then
    table.insert(parts, 'ID: ' .. (msg.info.id or 'N/A'))
  end

  return table.concat(parts, ' ~ ')
end

local function telescope_ui(messages, callback, on_undo, on_fork)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  local current_picker = pickers.new({}, {
    prompt_title = picker_title(),
    finder = finders.new_table({
      results = messages,
      entry_maker = function(msg)
        return {
          value = msg,
          display = format_message(msg),
          ordinal = format_message(msg),
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

      local timeline_config = config.keymap.timeline_picker or {}

      if timeline_config.undo and timeline_config.undo[1] then
        local key = timeline_config.undo[1]
        local modes = timeline_config.undo.mode or { 'i', 'n' }
        if type(modes) == 'string' then
          modes = { modes }
        end

        local undo_fn = function()
          local selection = action_state.get_selected_entry()
          if selection and on_undo then
            actions.close(prompt_bufnr)
            on_undo(selection.value)
          end
        end

        for _, mode in ipairs(modes) do
          map(mode, key, undo_fn)
        end
      end

      if timeline_config.fork and timeline_config.fork[1] then
        local key = timeline_config.fork[1]
        local modes = timeline_config.fork.mode or { 'i', 'n' }
        if type(modes) == 'string' then
          modes = { modes }
        end

        local fork_fn = function()
          local selection = action_state.get_selected_entry()
          if selection and on_fork then
            actions.close(prompt_bufnr)
            on_fork(selection.value)
          end
        end

        for _, mode in ipairs(modes) do
          map(mode, key, fork_fn)
        end
      end

      return true
    end,
  })

  current_picker:find()
end

local function fzf_ui(messages, callback, on_undo, on_fork)
  local fzf_lua = require('fzf-lua')
  local config = require('opencode.config')

  local actions_config = {
    ['default'] = function(selected, opts)
      if not selected or #selected == 0 then
        return
      end
      local idx = opts.fn_fzf_index(selected[1])
      if idx and messages[idx] and callback then
        callback(messages[idx])
      end
    end,
  }

  local timeline_config = config.keymap.timeline_picker or {}

  if timeline_config.undo and timeline_config.undo[1] then
    local key = require('fzf-lua.utils').neovim_bind_to_fzf(timeline_config.undo[1])
    actions_config[key] = {
      fn = function(selected, opts)
        if not selected or #selected == 0 then
          return
        end
        local idx = opts.fn_fzf_index(selected[1])
        if idx and messages[idx] and on_undo then
          on_undo(messages[idx])
        end
      end,
      header = 'undo',
    }
  end

  if timeline_config.fork and timeline_config.fork[1] then
    local key = require('fzf-lua.utils').neovim_bind_to_fzf(timeline_config.fork[1])
    actions_config[key] = {
      fn = function(selected, opts)
        if not selected or #selected == 0 then
          return
        end
        local idx = opts.fn_fzf_index(selected[1])
        if idx and messages[idx] and on_fork then
          on_fork(messages[idx])
        end
      end,
      header = 'fork',
    }
  end

  fzf_lua.fzf_exec(function(fzf_cb)
    for _, msg in ipairs(messages) do
      fzf_cb(format_message(msg))
    end
    fzf_cb()
  end, {
    fzf_opts = {
      ['--prompt'] = picker_title() .. ' > ',
    },
    _headers = { 'actions' },
    actions = actions_config,
    fn_fzf_index = function(line)
      for i, msg in ipairs(messages) do
        if format_message(msg) == line then
          return i
        end
      end
      return nil
    end,
  })
end

local function mini_pick_ui(messages, callback, on_undo, on_fork)
  local mini_pick = require('mini.pick')
  local config = require('opencode.config')

  local items = vim.tbl_map(function(msg)
    return {
      text = format_message(msg),
      message = msg,
    }
  end, messages)

  local timeline_config = config.keymap.timeline_picker or {}
  local mappings = {}

  if timeline_config.undo and timeline_config.undo[1] then
    mappings.undo = {
      char = timeline_config.undo[1],
      func = function()
        local selected = mini_pick.get_picker_matches().current
        if selected and selected.message and on_undo then
          on_undo(selected.message)
        end
      end,
    }
  end

  if timeline_config.fork and timeline_config.fork[1] then
    mappings.fork = {
      char = timeline_config.fork[1],
      func = function()
        local selected = mini_pick.get_picker_matches().current
        if selected and selected.message and on_fork then
          on_fork(selected.message)
        end
      end,
    }
  end

  mini_pick.start({
    source = {
      items = items,
      name = picker_title(),
      choose = function(selected)
        if selected and selected.message and callback then
          callback(selected.message)
        end
        return false
      end,
    },
    mappings = mappings,
  })
end

local function snacks_picker_ui(messages, callback, on_undo, on_fork)
  local Snacks = require('snacks')
  local config = require('opencode.config')

  local timeline_config = config.keymap.timeline_picker or {}

  local opts = {
    title = picker_title(),
    layout = { preset = 'select' },
    finder = function()
      return messages
    end,
    format = 'text',
    transform = function(item)
      item.text = format_message(item)
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

  if timeline_config.undo and timeline_config.undo[1] then
    local key = timeline_config.undo[1]
    local mode = timeline_config.undo.mode or 'i'

    opts.win = opts.win or {}
    opts.win.input = opts.win.input or { keys = {} }
    opts.win.input.keys[key] = { 'timeline_undo', mode = mode }

    opts.actions.timeline_undo = function(picker, item)
      if item and on_undo then
        vim.schedule(function()
          picker:close()
          on_undo(item)
        end)
      end
    end
  end

  if timeline_config.fork and timeline_config.fork[1] then
    local key = timeline_config.fork[1]
    local mode = timeline_config.fork.mode or 'i'

    opts.win = opts.win or {}
    opts.win.input = opts.win.input or { keys = {} }
    opts.win.input.keys[key] = { 'timeline_fork', mode = mode }

    opts.actions.timeline_fork = function(picker, item)
      if item and on_fork then
        vim.schedule(function()
          picker:close()
          on_fork(item)
        end)
      end
    end
  end

  Snacks.picker.pick(opts)
end

function M.pick(messages, callback)
  local picker_type = picker.get_best_picker()

  if not picker_type then
    return false
  end

  local function on_undo(msg)
    require('opencode.api').undo(msg.info.id)
  end

  local function on_fork(msg)
    -- TODO: Implement fork functionality
    vim.notify('Fork functionality not yet implemented', vim.log.levels.WARN)
  end

  vim.schedule(function()
    if picker_type == 'telescope' then
      telescope_ui(messages, callback, on_undo, on_fork)
    elseif picker_type == 'fzf' then
      fzf_ui(messages, callback, on_undo, on_fork)
    elseif picker_type == 'mini.pick' then
      mini_pick_ui(messages, callback, on_undo, on_fork)
    elseif picker_type == 'snacks' then
      snacks_picker_ui(messages, callback, on_undo, on_fork)
    else
      callback(nil)
    end
  end)

  return true
end

return M
