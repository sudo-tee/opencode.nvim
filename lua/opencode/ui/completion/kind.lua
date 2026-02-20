local M = {}

local KIND_OFFSET = 1000

---Register a custom LSP CompletionItemKind for a completion source.
---@param source_name string
---@param kind_icon? string
---@return integer custom_kind_id
function M.register(source_name, kind_icon)
  local kind_name = 'Opencode' .. (source_name:gsub('^%l', string.upper))

  if not vim.lsp.protocol.CompletionItemKind[kind_name] then
    local next_id = KIND_OFFSET
    while vim.lsp.protocol.CompletionItemKind[next_id] do
      next_id = next_id + 1
    end

    vim.lsp.protocol.CompletionItemKind[kind_name] = next_id
    vim.lsp.protocol.CompletionItemKind[next_id] = (kind_icon and kind_icon .. ' ' or '') .. kind_name
  end

  return vim.lsp.protocol.CompletionItemKind[kind_name]
end

return M
