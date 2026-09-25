local M = {}

---Reconstruct both revisions from a full-context unified patch.
---@param patch string
---@return string[]?, string[]?
function M.sides(patch)
  local before, after = {}, {}
  local old_pos, new_pos = 1, 1
  ---@type number, number
  local old_count, new_count = 0, 0
  local saw_hunk = false
  for _, line in ipairs(vim.split(patch:gsub('\r\n', '\n'), '\n', { plain = true })) do
    local old_start, old_size, new_start, new_size =
      line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if old_start then
      if saw_hunk and (old_count ~= 0 or new_count ~= 0) then
        return nil, nil
      end
      local old_length = old_size == '' and 1 or assert(tonumber(old_size))
      local new_length = new_size == '' and 1 or assert(tonumber(new_size))
      if
        tonumber(old_start) ~= old_pos - (old_length == 0 and 1 or 0)
        or tonumber(new_start) ~= new_pos - (new_length == 0 and 1 or 0)
      then
        return nil, nil
      end
      old_count, new_count = old_length, new_length
      saw_hunk = true
    elseif saw_hunk and (old_count > 0 or new_count > 0) then
      local marker, text = line:sub(1, 1), line:sub(2)
      if marker == ' ' then
        before[#before + 1], after[#after + 1] = text, text
        old_count, new_count = old_count - 1, new_count - 1
        old_pos, new_pos = old_pos + 1, new_pos + 1
      elseif marker == '-' then
        before[#before + 1] = text
        old_count, old_pos = old_count - 1, old_pos + 1
      elseif marker == '+' then
        after[#after + 1] = text
        new_count, new_pos = new_count - 1, new_pos + 1
      else
        return nil, nil
      end
      if old_count < 0 or new_count < 0 then
        return nil, nil
      end
    end
  end
  if not saw_hunk or old_count ~= 0 or new_count ~= 0 then
    return nil, nil
  end
  return before, after
end

return M
