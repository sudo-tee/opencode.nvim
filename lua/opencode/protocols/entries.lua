local M = {}

---Preserve entry identity for consumers holding references to observed messages.
---@param existing? table
---@param replacement table
---@return table
function M.replace(existing, replacement)
  if not existing then
    return replacement
  end
  for key in pairs(existing) do
    existing[key] = nil
  end
  for key, value in pairs(replacement) do
    existing[key] = value
  end
  return existing
end

---Prepend an older history page, keeping entries already received online.
---@param state table
---@param entries table[] Older entries, in chronological order
---@param on_added? fun(entry: table)
function M.prepend(state, entries, on_added)
  local prefix = {}
  for _, entry in ipairs(entries) do
    if not state.entries_by_id[entry.id] then
      state.entries_by_id[entry.id] = entry
      if on_added then
        on_added(entry)
      end
      prefix[#prefix + 1] = entry.id
    end
  end
  if #prefix > 0 then
    vim.list_extend(prefix, state.entry_order)
    state.entry_order = prefix
  end
end

return M
