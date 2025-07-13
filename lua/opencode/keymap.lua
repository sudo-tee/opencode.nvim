local api = require('opencode.api')

local M = {}

-- Binds a keymap config with its api fn
-- Name of api fn & keymap global config should always be the same
function M.setup(keymap)
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

---@param lhs string The left-hand side of the mapping
---@param rhs function|string The right-hand side of the mapping
---@param bufnrs number|number[] Buffer number(s) to set the mapping for
---@param mode string|string[] Mode(s) for the mapping
---@param opts? table Additional options for vim.keymap.set
function M.buf_keymap(lhs, rhs, bufnrs, mode, opts)
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

return M
