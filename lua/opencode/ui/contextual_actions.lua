local state = require('opencode.state')

local M = {}

local namespace = vim.api.nvim_create_namespace('opencode_contextual_actions')
local augroup = vim.api.nvim_create_augroup('OpenCodeContextualActions', { clear = true })
local lifecycles = {}

local function buffer_mapping(buf, key)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if mapping.lhs == key then
      return mapping
    end
  end
end

local function restore_mapping(buf, mapping)
  local options = {
    desc = mapping.desc,
    silent = mapping.silent == 1,
    expr = mapping.expr == 1,
    nowait = mapping.nowait == 1,
    noremap = mapping.noremap ~= 0,
    script = mapping.script == 1,
    replace_keycodes = mapping.replace_keycodes == 1,
  }
  if mapping.callback then
    options.callback = mapping.callback
  end
  vim.api.nvim_buf_set_keymap(buf, 'n', mapping.lhs, mapping.callback and '' or mapping.rhs, options)
end

local function clear_contextual_actions(buf)
  local lifecycle = lifecycles[buf]
  if not lifecycle then
    return
  end

  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for key, mapping in pairs(lifecycle.saved_mappings) do
      vim.keymap.del('n', key, { buffer = buf })
      if mapping then
        restore_mapping(buf, mapping)
      end
    end
  end
  lifecycle.saved_mappings = {}
  lifecycle.actions = nil
end

local function ensure_lifecycle(buf)
  local lifecycle = lifecycles[buf]
  if lifecycle then
    return lifecycle
  end

  lifecycle = { saved_mappings = {}, actions = nil }
  assert(vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      clear_contextual_actions(buf)
    end,
    on_reload = function()
      clear_contextual_actions(buf)
    end,
    on_detach = function()
      clear_contextual_actions(buf)
      lifecycles[buf] = nil
    end,
  }))
  lifecycles[buf] = lifecycle
  return lifecycle
end

function M.show_contextual_actions_menu(buf, actions)
  local lifecycle = ensure_lifecycle(buf)
  actions = actions and #actions > 0 and actions or nil

  if vim.deep_equal(lifecycle.actions, actions) then
    return
  end

  clear_contextual_actions(buf)
  if not actions then
    return
  end
  lifecycle.actions = actions

  for _, action in ipairs(actions) do
    vim.api.nvim_buf_set_extmark(buf, namespace, action.display_line, 0, {
      virt_text = { { '⋮ ' .. action.text .. ' ', 'OpencodeContextualActions' } },
      virt_text_pos = 'right_align',
      hl_mode = 'combine',
    })

    if action.key and lifecycle.saved_mappings[action.key] == nil then
      lifecycle.saved_mappings[action.key] = buffer_mapping(buf, action.key) or false
      vim.keymap.set('n', action.key, function()
        if lifecycles[buf] ~= lifecycle or not vim.tbl_contains(lifecycle.actions or {}, action) then
          return
        end

        clear_contextual_actions(buf)
        if action.type and action.args then
          require('opencode.api')[action.type](unpack(action.args))
        end
      end, { buffer = buf, silent = true, desc = action.text })
    end
  end
end

local function refresh_contextual_actions(buf)
  local lifecycle = lifecycles[buf]
  if not lifecycle then
    return
  end

  if not state.windows or state.windows.output_buf ~= buf or vim.api.nvim_get_current_buf() ~= buf then
    clear_contextual_actions(buf)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  M.show_contextual_actions_menu(buf, require('opencode.ui.renderer').get_actions_for_line(line))
end

function M.setup_contextual_actions(windows)
  ensure_lifecycle(windows.output_buf)
  refresh_contextual_actions(windows.output_buf)
end

vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorMoved', 'BufEnter', 'WinEnter' }, {
  group = augroup,
  callback = function(event)
    refresh_contextual_actions(event.buf)
  end,
})

vim.api.nvim_create_autocmd({ 'BufLeave', 'BufDelete', 'BufHidden' }, {
  group = augroup,
  callback = function(event)
    clear_contextual_actions(event.buf)
  end,
})

return M
