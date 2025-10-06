local M = {}

-- Binds a keymap config with its api fn
-- Name of api fn & keymap global config should always be the same
---@param keymap OpencodeKeymap The keymap configuration table
function M.setup(keymap)
  local api = require('opencode.api')
  local cmds = api.commands
  local global = keymap.global

  for key, mapping in pairs(global) do
    if type(mapping) == 'string' then
      vim.keymap.set({ 'n', 'v' }, mapping, function()
        api[key]()
      end, { silent = false, desc = cmds[key] and cmds[key].desc })
    end
  end
end

---@param lhs string|false The left-hand side of the mapping, `false` disables keymaps
---@param rhs function|string The right-hand side of the mapping
---@param bufnrs number|number[] Buffer number(s) to set the mapping for
---@param mode string|string[] Agent(s) for the mapping
---@param opts? table Additional options for vim.keymap.set
function M.buf_keymap(lhs, rhs, bufnrs, mode, opts)
  if not lhs then
    return
  end

  opts = opts or { silent = true }
  bufnrs = type(bufnrs) == 'table' and bufnrs or { bufnrs }

  for _, bufnr in ipairs(bufnrs) do
    if
      not vim.api.nvim_buf_is_valid(bufnr --[[@as number]])
    then
      vim.notify(string.format('Invalid buffer number: %s', bufnr), vim.log.levels.WARN)
      return
    end
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', opts, { buffer = bufnr }))
  end
end

function M.clear_permission_keymap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local config = require('opencode.config').get()
  local keymaps = config.keymap.window

  pcall(function()
    vim.api.nvim_buf_del_keymap(buf, 'n', keymaps.permission_accept)
    vim.api.nvim_buf_del_keymap(buf, 'i', keymaps.permission_accept)
    vim.api.nvim_buf_del_keymap(buf, 'n', keymaps.permission_accept_all)
    vim.api.nvim_buf_del_keymap(buf, 'i', keymaps.permission_accept_all)
    vim.api.nvim_buf_del_keymap(buf, 'n', keymaps.permission_deny)
    vim.api.nvim_buf_del_keymap(buf, 'i', keymaps.permission_deny)
  end)
end

function M.toggle_permission_keymap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local state = require('opencode.state')
  local config = require('opencode.config').get()
  local keymaps = config.keymap.window
  local api = require('opencode.api')

  if state.current_permission then
    M.buf_keymap(keymaps.permission_accept, function()
      api.respond_to_permission('once')
    end, buf, { 'n', 'i' })

    M.buf_keymap(keymaps.permission_accept_all, function()
      api.respond_to_permission('always')
    end, buf, { 'n', 'i' })

    M.buf_keymap(keymaps.permission_deny, function()
      api.respond_to_permission('reject')
    end, buf, { 'n', 'i' })
  else
    M.clear_permission_keymap(buf)
  end
end

return M
