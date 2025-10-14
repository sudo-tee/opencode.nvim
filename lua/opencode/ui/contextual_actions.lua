local state = require('opencode.state')
local keymap = require('opencode.keymap')
local output_window = require('opencode.ui.output_window')

local M = {}

-- Module state
local last_line_num = nil
local dirty = false
local current_keymaps = {}

local function clear_keymaps(buf)
  for key, _ in pairs(current_keymaps) do
    vim.keymap.del('n', key, { buffer = buf })
  end
  current_keymaps = {}
end

function M.setup_contextual_actions()
  local ns_id = vim.api.nvim_create_namespace('opencode_contextual_actions')
  local augroup = vim.api.nvim_create_augroup('OpenCodeContextualActions', { clear = true })

  vim.api.nvim_create_autocmd('CursorHold', {
    group = augroup,
    buffer = state.windows.output_buf,
    callback = function()
      vim.schedule(function()
        local line_num = vim.api.nvim_win_get_cursor(0)[1]
        local actions = require('opencode.ui.formatter').output:get_actions_for_line(line_num)
        last_line_num = line_num

        vim.api.nvim_buf_clear_namespace(state.windows.output_buf, ns_id, 0, -1)
        clear_keymaps(state.windows.output_buf)

        if actions and #actions > 0 then
          dirty = true
          M.show_contextual_actions_menu(state.windows.output_buf, line_num, actions, ns_id)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    buffer = state.windows.output_buf,
    callback = function()
      vim.schedule(function()
        if not output_window.mounted() then
          return
        end
        local line_num = vim.api.nvim_win_get_cursor(0)[1]
        if last_line_num == line_num and not dirty then
          return
        end
        vim.api.nvim_buf_clear_namespace(state.windows.output_buf, ns_id, 0, -1)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufLeave', 'BufDelete', 'BufHidden' }, {
    group = augroup,
    buffer = state.windows.output_buf,
    callback = function()
      vim.api.nvim_buf_clear_namespace(state.windows.output_buf, ns_id, 0, -1)
      clear_keymaps(state.windows.output_buf)
      last_line_num = nil
      dirty = false
    end,
  })
end

function M.show_contextual_actions_menu(buf, line_num, actions, ns_id)
  clear_keymaps(buf)

  for _, action in ipairs(actions) do
    ---@type OutputExtmark
    local mark = {
      virt_text = { { '⋮ ' .. action.text .. ' ', 'OpencodeContextualActions' } },
      virt_text_pos = 'right_align',
      hl_mode = 'combine',
    }

    vim.api.nvim_buf_set_extmark(buf, ns_id, action.display_line - 1, 0, mark)
  end
  -- Setup key mappings for actions
  for _, action in ipairs(actions) do
    if action.key then
      current_keymaps[action.key] = true
      vim.keymap.set('n', action.key, function()
        if action.type and action.args then
          vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
          clear_keymaps(buf)
          local api = require('opencode.api')
          api[action.type](unpack(action.args))
        end
      end, { buffer = buf, silent = true, desc = action.text })
    end
  end
end

return M
