local util = require('opencode.util')

local M = {}

---@param line integer
---@param patch string
---@return integer
function M.translate(line, patch)
  local shift = 0
  for old_start, old_size, new_start, new_size in patch:gmatch('@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@') do
    local old_line = tonumber(old_start)
    local old_count = old_size == '' and 1 or tonumber(old_size)
    local new_count = new_size == '' and 1 or tonumber(new_size)
    if line < old_line then
      break
    end
    if line < old_line + old_count then
      return tonumber(new_start) + math.min(line - old_line, math.max(0, new_count - 1))
    end
    shift = shift + new_count - old_count
  end
  return math.max(1, line + shift)
end

---@param comment OpencodeContextReviewComment
---@param lines string[]
---@param hint? integer
---@return OpencodeReviewCommentResolution
function M.resolve(comment, lines, hint)
  local expected = hint or comment.anchor_side_line
  local code = vim.split(comment.code, '\n', { plain = true })
  local before, after = comment.context_before, comment.context_after
  local function matches(block, pos)
    for index, text in ipairs(block) do
      if lines[pos + index - 1] ~= text then
        return false
      end
    end
    return true
  end
  local function score(pos, size)
    local result = 0
    for index, text in ipairs(before) do
      if lines[pos - #before + index - 1] == text then
        result = result + 1
      end
    end
    for index, text in ipairs(after) do
      if lines[pos + size + index - 1] == text then
        result = result + 1
      end
    end
    return result
  end
  if comment.side == 'after' then
    local best, best_score, hits = nil, nil, 0
    for pos = 1, #lines - #code + 1 do
      if matches(code, pos) then
        hits = hits + 1
        local rank = score(pos, #code)
        if
          not best
          or rank > best_score
          or (rank == best_score and math.abs(pos - expected) < math.abs(best - expected))
        then
          best, best_score = pos, rank
        end
      end
    end
    if best then
      return {
        status = hits == 1 and best == expected and 'exact' or 'moved',
        start_line = best,
        end_line = best + #code - 1,
      }
    end
  end
  local best_start, best_end, distance
  local next_after = {}
  if #after > 0 then
    local next_match
    for pos = #lines + 1, 1, -1 do
      if matches(after, pos) then
        next_match = pos
      end
      next_after[pos] = next_match
    end
  end
  for start = 1, #lines + 1 do
    if (start == 1 and #before == 0) or (#before > 0 and start - #before >= 1 and matches(before, start - #before)) then
      local finish = #after == 0 and #lines or (next_after[start] and next_after[start] - 1)
      if finish and finish + #after <= #lines then
        local offset = math.abs(start - expected)
        if not distance or offset < distance then
          best_start, best_end, distance = start, finish, offset
        end
      end
    end
  end
  if best_start and (#before > 0 or #after > 0) then
    return {
      status = 'modified',
      start_line = best_start,
      end_line = best_end,
      current_code = table.concat(vim.list_slice(lines, best_start, best_end), '\n'),
    }
  end
  return { status = 'removed' }
end

---@param comment OpencodeContextReviewComment
---@return OpencodeReviewCommentResolution
function M.current(comment, hint)
  local path = util.apply_path_map(comment.file)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return M.resolve(comment, vim.api.nvim_buf_get_lines(buf, 0, -1, false), hint)
  end
  if vim.fn.filereadable(path) == 0 then
    return { status = 'missing_file' }
  end
  return M.resolve(comment, vim.fn.readfile(path), hint)
end

return M
