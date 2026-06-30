local M = {}

local function is_candidate(token)
  return token:find('[%a_]') ~= nil
end

local function is_path_segment(line, start_pos, end_pos)
  -- Path fragments belong to file/reference handling. Emitting their segments as
  -- symbols would make directories like `tests/data` look jumpable.
  local before = start_pos > 1 and line:sub(start_pos - 1, start_pos - 1) or ''
  local after = end_pos < #line and line:sub(end_pos + 1, end_pos + 1) or ''
  return before:match('[/\\%-]') ~= nil
    or after:match('[/\\%-]') ~= nil
    or (before == '.' and (start_pos == 2 or not line:sub(start_pos - 2, start_pos - 2):match('[%w_]')))
end

function M.find(line, scan_from)
  local start_pos, end_pos = line:find('[%w_][%w_]*', scan_from)
  if not start_pos then
    return nil
  end

  -- Qualified spans may contain `.`, `::`, or Lua's method `:`.
  -- A lone `:` followed by prose punctuation stays outside the symbol.
  while end_pos < #line do
    local delimiter = line:sub(end_pos + 1, end_pos + 2)
    local delimiter_len
    if delimiter == '::' then
      delimiter_len = 2
    elseif line:sub(end_pos + 1, end_pos + 1) == ':' then
      delimiter_len = 1
    elseif line:sub(end_pos + 1, end_pos + 1) == '.' then
      delimiter_len = 1
    else
      break
    end

    local tail_start = end_pos + delimiter_len + 1
    local tail_start_pos, tail_end_pos = line:find('[%w_][%w_]*', tail_start)
    if tail_start_pos ~= tail_start then
      break
    end
    end_pos = tail_end_pos
  end

  local token = line:sub(start_pos, end_pos)
  if not is_candidate(token) or is_path_segment(line, start_pos, end_pos) then
    return start_pos, end_pos, nil
  end
  return start_pos, end_pos, token
end

function M.at_col(line, col)
  local scan_from = 1
  while scan_from <= #line do
    local start_pos, end_pos, token = M.find(line, scan_from)
    if not start_pos then
      return nil
    end
    if col >= start_pos - 1 and col <= end_pos - 1 then
      return token
    end
    scan_from = end_pos + 1
  end
end

return M
