local state = require('opencode.state')

local M = {}

local namespace = vim.api.nvim_create_namespace('opencode_contextual_actions')
local augroup = vim.api.nvim_create_augroup('OpenCodeContextualActions', { clear = true })
local lifecycles = {}
local refresh_contextual_actions

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

local function lifecycle_for(buf)
  if not lifecycles[buf] then
    lifecycles[buf] = {
      saved_mappings = {},
      generation = 0,
      observing = false,
      actions = nil,
    }
  end
  return lifecycles[buf]
end

local function invalidate(buf, lifecycle)
  if lifecycles[buf] ~= lifecycle then
    return
  end

  lifecycle.generation = lifecycle.generation + 1
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for key, snapshot in pairs(lifecycle.saved_mappings) do
    vim.keymap.del('n', key, { buffer = buf })
    if snapshot.mapping then
      restore_mapping(buf, snapshot.mapping)
    end
  end
  lifecycle.saved_mappings = {}
  lifecycle.actions = nil
end

function M.setup_contextual_actions(windows)
  local buf = windows.output_buf
  local lifecycle = lifecycle_for(buf)
  if lifecycle.observing then
    refresh_contextual_actions(buf)
    return
  end

  assert(vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      invalidate(buf, lifecycle)
    end,
    on_reload = function()
      invalidate(buf, lifecycle)
    end,
    on_detach = function()
      invalidate(buf, lifecycle)
      if lifecycles[buf] == lifecycle then
        lifecycles[buf] = nil
      end
    end,
  }))
  lifecycle.observing = true
  refresh_contextual_actions(buf)
end

function M.show_contextual_actions_menu(buf, actions)
  local lifecycle = lifecycle_for(buf)
  if not actions or #actions == 0 then
    if lifecycle.actions then
      invalidate(buf, lifecycle)
    end
    return
  end

  if vim.deep_equal(lifecycle.actions, actions) then
    return
  end

  invalidate(buf, lifecycle)
  lifecycle.actions = actions

  for _, action in ipairs(actions) do
    vim.api.nvim_buf_set_extmark(buf, namespace, action.display_line, 0, {
      virt_text = { { '⋮ ' .. action.text .. ' ', 'OpencodeContextualActions' } },
      virt_text_pos = 'right_align',
      hl_mode = 'combine',
    })
  end

  for _, action in ipairs(actions) do
    if action.key and not lifecycle.saved_mappings[action.key] then
      lifecycle.saved_mappings[action.key] = { mapping = buffer_mapping(buf, action.key) }
      local generation = lifecycle.generation
      vim.keymap.set('n', action.key, function()
        if lifecycles[buf] ~= lifecycle or lifecycle.generation ~= generation then
          return
        end

        invalidate(buf, lifecycle)
        if action.type and action.args then
          require('opencode.api')[action.type](unpack(action.args))
        end
      end, { buffer = buf, silent = true, desc = action.text })
    end
  end
end

refresh_contextual_actions = function(buf)
  local lifecycle = lifecycles[buf]
  if not lifecycle then
    return
  end

  if not state.windows or state.windows.output_buf ~= buf or vim.api.nvim_get_current_buf() ~= buf then
    invalidate(buf, lifecycle)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  M.show_contextual_actions_menu(buf, require('opencode.ui.renderer').get_actions_for_line(line))
end

vim.api.nvim_create_autocmd({ 'CursorHold', 'BufEnter', 'WinEnter' }, {
  group = augroup,
  callback = function(event)
    refresh_contextual_actions(event.buf)
  end,
})

vim.api.nvim_create_autocmd('CursorMoved', {
  group = augroup,
  callback = function(event)
    refresh_contextual_actions(event.buf)
  end,
})

vim.api.nvim_create_autocmd({ 'BufLeave', 'BufDelete', 'BufHidden' }, {
  group = augroup,
  callback = function(event)
    local lifecycle = lifecycles[event.buf]
    if lifecycle then
      invalidate(event.buf, lifecycle)
    end
  end,
})

return M
