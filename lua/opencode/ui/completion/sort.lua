local M = {}

---Sort completion items by relevance to input
---@param items CompletionItem[] List of completion items
---@param input string Input to match against
---@param get_name? fun(item: CompletionItem): string Function to extract name from item (defaults to item.label)
---@param compare? fun (a: CompletionItem, b: CompletionItem):boolean Function for tie-breaking comparaison (defaults to alphabetical)
---@return table[] Sorted items
function M.sort_by_relevance(items, input, get_name, compare)
  get_name = get_name or function(item)
    return item.label
  end

  compare = compare or function(a, b)
    return get_name(a):lower() < get_name(b):lower()
  end

  local input_lower = input:lower()

  table.sort(items, function(a, b)
    local a_name = get_name(a):lower()
    local b_name = get_name(b):lower()

    -- Exact matches first
    local a_exact = a_name == input_lower
    local b_exact = b_name == input_lower
    if a_exact ~= b_exact then
      return a_exact
    end

    -- Then starts with input
    local a_starts = a_name:find('^' .. vim.pesc(input_lower))
    local b_starts = b_name:find('^' .. vim.pesc(input_lower))
    if a_starts ~= b_starts then
      return a_starts ~= nil
    end

    -- Use custom tie breaker
    return compare(a, b)
  end)

  return items
end

return M

