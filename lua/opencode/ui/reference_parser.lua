---@class ParsedCodeReference
---@field file_path string
---@field line number|nil
---@field col number|nil
---@field match_start number
---@field match_end number

local M = {}

local PATTERNS = {
  { pat = '`([^`\n]+%.(%w+)):?(%d*):?(%d*)`' },
  { pat = 'file://([%S]+%.(%w+)):?(%d*):?(%d*)' },
  { pat = '([%w_./%-]+/[%w_./%-]*%.(%w+)):?(%d*):?(%d*)' },
  { pat = '([%w_%-]+%.(%w+)):?(%d*):?(%d*)' },
}

local OVERLAP = 128
local cache = {}

local function is_valid_ext(ext)
  return #ext >= 1 and #ext <= 5 and ext:match('^%a+$') ~= nil
end

local function is_url_path(path, chunk, ms)
  local context = chunk:sub(math.max(1, ms - 64), ms - 1)
  return context:match('https?://[%S]*$')
    or context:match('www%.[%S]*$')
    or path:match('^//')
    or path:match('^www%.')
    or path:match('^[%w%-]+%.[%w%-]+/')
end

local function current_line_start_before(text, offset)
  return text:sub(1, offset - 1):match('.*\n()') or 1
end

local function unclosed_inline_backtick_before(text, offset)
  local line_start = current_line_start_before(text, offset)
  local line_prefix = text:sub(line_start, offset - 1):gsub('```', '   ')
  local _, backticks_before_offset = line_prefix:gsub('`', '')
  if backticks_before_offset % 2 == 0 then
    return nil
  end
  local relative_offset = line_prefix:match('^.*()`')
  return relative_offset and (line_start + relative_offset - 1) or nil
end

local function is_inside_unclosed_inline_backticks(text, offset)
  if not unclosed_inline_backtick_before(text, offset) then
    return false
  end
  local line_end = text:find('\n', offset, true) or (#text + 1)
  local closing_backtick = text:find('`', offset, true)
  return not (closing_backtick and closing_backtick < line_end)
end

local function fenced_code_ranges(text)
  local ranges = {}
  local fence_start = nil
  local line_start = 1

  while line_start <= #text do
    local newline = text:find('\n', line_start, true)
    local line_end = newline and (newline - 1) or #text
    local line = text:sub(line_start, line_end)

    if line:match('^%s*```') then
      if fence_start then
        ranges[#ranges + 1] = { fence_start, newline or line_end }
        fence_start = nil
      else
        fence_start = line_start
      end
    end

    if not newline then
      break
    end
    line_start = newline + 1
  end

  if fence_start then
    ranges[#ranges + 1] = { fence_start, #text }
  end

  return ranges
end

local function inside_range(ranges, offset)
  for _, range in ipairs(ranges) do
    if offset >= range[1] and offset <= range[2] then
      return true
    end
  end
  return false
end

local function overlaps(ranges, abs_ms, abs_me)
  for _, r in ipairs(ranges) do
    if abs_ms <= r[2] and abs_me >= r[1] then
      return true
    end
  end
  return false
end

local function make_ref(path, line_str, col_str, abs_start, abs_end)
  return {
    file_path = path,
    line = line_str ~= '' and tonumber(line_str) or nil,
    col = col_str ~= '' and tonumber(col_str) or nil,
    match_start = abs_start,
    match_end = abs_end,
  }
end

local function parse_references_into(text, c, scan_from)
  local chunk = text:sub(scan_from)
  local abs_offset = scan_from - 1
  local fenced_ranges = fenced_code_ranges(text)

  for pattern_index, entry in ipairs(PATTERNS) do
    local pos = 1
    while pos <= #chunk do
      local ms, me, path, ext, l, col = chunk:find(entry.pat, pos)
      if not ms then
        break
      end

      if is_valid_ext(ext) then
        local abs_ms = ms + abs_offset
        local abs_me = me + abs_offset
        if
          not inside_range(fenced_ranges, abs_ms)
          and not is_url_path(path, chunk, ms)
          and (pattern_index == 1 or not is_inside_unclosed_inline_backticks(text, abs_ms))
          and not overlaps(c.ranges, abs_ms, abs_me)
        then
          table.insert(c.ranges, { abs_ms, abs_me })
          table.insert(c.refs, make_ref(path, l or '', col or '', abs_ms, abs_me))
        end
      end

      pos = me + 1
    end
  end
end

local function append_scan_from(text, parsed_upto)
  local scan_from = math.max(1, parsed_upto - OVERLAP + 1)
  return unclosed_inline_backtick_before(text, scan_from) or scan_from
end

---@param text string
---@param key string
---@return ParsedCodeReference[]
function M.parse_references(text, key)
  local c = cache[key]
  if c and text == c.text then
    return c.refs
  end

  local scan_from = 1
  if c and vim.startswith(text, c.text) then
    scan_from = append_scan_from(text, c.parsed_upto)
  else
    c = {
      text = '',
      parsed_upto = 0,
      refs = {},
      ranges = {},
    }
    cache[key] = c
  end

  local len = #text
  parse_references_into(text, c, scan_from)

  c.text = text
  c.parsed_upto = len
  return c.refs
end

---@param key string
function M.clear(key)
  cache[key] = nil
end

function M.clear_all()
  cache = {}
end

return M
