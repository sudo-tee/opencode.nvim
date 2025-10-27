local M = {}
local picker = require('opencode.ui.picker')

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

  local origin_win = vim.api.nvim_get_current_win()
  local origin_mode = vim.fn.mode()
  local origin_pos = vim.api.nvim_win_get_cursor(origin_win)

  local confirmed = false

  local opts = {
    confirm = function(picker_obj)
      local items = picker_obj:selected({ fallback = true })
      confirmed = true
      picker_obj:close()

      if items and callback then
        for _, it in ipairs(items) do
          if it and it.file then
            callback(it.file)
          end
        end
      end
    end,
    on_close = function(obj)
      vim.notify(vim.inspect(obj))
      -- snacks doesn't seem to restore window / mode / cursor position when you
      -- cancel the picker. if we pick a file, we're already handling that case elsewhere
      if confirmed or not vim.api.nvim_win_is_valid(origin_win) then
        return
      end

      vim.api.nvim_set_current_win(origin_win)
      if origin_mode:match('i') then
        vim.cmd('startinsert')
      end
      vim.api.nvim_win_set_cursor(origin_win, origin_pos)
    end,
  }

  if path then
    opts.cwd = path
  end

  Snacks.picker.files(opts)
end

function M.pick(callback, path)
  local picker_type = picker.get_best_picker()

  if not picker_type then
    return
  end

  local wrapped_callback = function(selected_file)
    local file_name = format_file(selected_file)
    callback(file_name)
  end

  vim.schedule(function()
    if picker_type == 'telescope' then
      telescope_ui(wrapped_callback, path)
    elseif picker_type == 'fzf' then
      fzf_ui(wrapped_callback, path)
    elseif picker_type == 'mini.pick' then
      mini_pick_ui(wrapped_callback, path)
    elseif picker_type == 'snacks' then
      snacks_picker_ui(wrapped_callback, path)
    else
      callback(nil)
    end
  end)
end

return M
