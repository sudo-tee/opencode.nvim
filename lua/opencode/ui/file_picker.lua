local M = {}

local function get_best_picker()
  local config = require('opencode.config')

  local preferred_picker = config.preferred_picker
  if preferred_picker and preferred_picker ~= '' then
    return preferred_picker
  end

  if pcall(require, 'telescope') then
    return 'telescope'
  end
  if pcall(require, 'fzf-lua') then
    return 'fzf'
  end
  if pcall(require, 'mini.pick') then
    return 'mini.pick'
  end
  if pcall(require, 'snacks') then
    return 'snacks'
  end
  return nil
end

local function format_file(path)
  -- when path is something like: file.extension dir1/dir2 -> format to dir1/dir2/file.extension
  local file_match, path_match = path:match('^(.-)\t(.-)$')
  if file_match and path_match then
    path = path_match .. '/' .. file_match
  end

  return {
    name = vim.fn.fnamemodify(path, ':t'),
    path = path,
  }
end

local function telescope_ui(callback, path)
  local builtin = require('telescope.builtin')
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  local opts = {
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local multi = picker and picker:get_multi_selection() or {}
        if multi and #multi > 0 then
          actions.close(prompt_bufnr)
          for _, entry in ipairs(multi) do
            if entry and entry.value and callback then
              callback(entry.value)
            end
          end
          return
        end

        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection and callback then
          callback(selection.value)
        end
      end)
      return true
    end,
  }

  if path then
    opts.cwd = path
  end

  builtin.find_files(opts)
end

local function fzf_ui(callback, path)
  local fzf_lua = require('fzf-lua')

  local opts = {
    actions = {
      ['default'] = function(selected)
        if not selected or #selected == 0 then
          return
        end

        for _, sel in ipairs(selected) do
          local file = fzf_lua.path.entry_to_file(sel)
          if file and file.path and callback then
            callback(file.path)
          end
        end
      end,
    },
  }

  if path then
    opts.cwd = path
  end

  fzf_lua.files(opts)
end

local function mini_pick_ui(callback, path)
  local mini_pick = require('mini.pick')
  local opts = {
    source = {
      choose = function(selected)
        if selected and callback then
          callback(selected)
        end
        return false
      end,
    },
  }

  if path then
    opts.source.cwd = path
  end

  mini_pick.builtin.files(nil, opts)
end

local function snacks_picker_ui(callback, path)
  local Snacks = require('snacks')

  local opts = {
    confirm = function(picker)
      local items = picker:selected({ fallback = true })
      picker:close()

      if items and callback then
        for _, it in ipairs(items) do
          if it and it.file then
            callback(it.file)
          end
        end
      end
    end,
  }

  if path then
    opts.cwd = path
  end

  Snacks.picker.files(opts)
end

function M.pick(callback, path)
  local picker = get_best_picker()

  if not picker then
    return
  end

  local wrapped_callback = function(selected_file)
    local file_name = format_file(selected_file)
    callback(file_name)
  end

  vim.schedule(function()
    if picker == 'telescope' then
      telescope_ui(wrapped_callback, path)
    elseif picker == 'fzf' then
      fzf_ui(wrapped_callback, path)
    elseif picker == 'mini.pick' then
      mini_pick_ui(wrapped_callback, path)
    elseif picker == 'snacks' then
      snacks_picker_ui(wrapped_callback, path)
    else
      callback(nil)
    end
  end)
end

return M
