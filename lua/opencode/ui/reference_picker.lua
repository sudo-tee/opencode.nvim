local state = require('opencode.state')
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local icons = require('opencode.ui.icons')

---@class CodeReference
---@field file_path string
---@field line number|nil
---@field col number|nil
---@field match_start number
---@field match_end number

local M = {}

local PATTERNS = {
  { pat = '`([^`\n]+%.(%w+)):?(%d*):?(%d*)`', check_exists = false },
  { pat = 'file://([%S]+%.(%w+)):?(%d*):?(%d*)', check_exists = false },
  { pat = '([%w_./%-]+/[%w_./%-]*%.(%w+)):?(%d*):?(%d*)', check_exists = false },
  { pat = '([%w_%-]+%.(%w+)):?(%d*):?(%d*)', check_exists = true },
}

local OVERLAP = 128
local cache = {}
local exists_cache = {}

local function make_absolute_path(path)
  if not vim.startswith(path, '/') then
    return vim.fn.getcwd() .. '/' .. path
  end
  return path
end

local function file_exists(path)
  local abs = make_absolute_path(path)
  if exists_cache[abs] == nil then
    exists_cache[abs] = vim.fn.filereadable(abs) == 1
  end
  return exists_cache[abs]
end

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

---@param text string
---@param message_id string
---@return CodeReference[]
function M.parse_references(text, message_id)
  local c = cache[message_id]
  if not c then
    c = {
      parsed_upto = 0,
      refs = {},
      ranges = {},
      seen_paths = {},
    }
    cache[message_id] = c
  end

  local len = #text
  if len <= c.parsed_upto then
    return c.refs
  end

  local scan_from = math.max(1, c.parsed_upto - OVERLAP + 1)
  local chunk = text:sub(scan_from)
  local abs_offset = scan_from - 1

  for _, entry in ipairs(PATTERNS) do
    local pos = 1
    while pos <= #chunk do
      local ms, me, path, ext, l, col = chunk:find(entry.pat, pos)
      if not ms then
        break
      end

      if is_valid_ext(ext) then
        local abs_ms = ms + abs_offset
        local abs_me = me + abs_offset
        local path_key = path .. ':' .. (l or '') .. ':' .. (col or '')

        if
          not is_url_path(path, chunk, ms)
          and not c.seen_paths[path_key]
          and not overlaps(c.ranges, abs_ms, abs_me)
          and (not entry.check_exists or file_exists(path))
        then
          c.seen_paths[path_key] = true
          table.insert(c.ranges, { abs_ms, abs_me })
          table.insert(c.refs, make_ref(path, l or '', col or '', abs_ms, abs_me))
        end
      end

      pos = me + 1
    end
  end

  c.parsed_upto = len
  return c.refs
end

function M.clear(message_id)
  cache[message_id] = nil
end

function M.clear_all()
  cache = {}
  exists_cache = {}
end

local function format_reference_item(ref, width)
  local icon = icons.get('file')
  local location = ref.file_path
  if ref.line then
    location = location .. ':' .. ref.line
    if ref.col then
      location = location .. ':' .. ref.col
    end
  end
  return base_picker.create_time_picker_item(icon .. ' ' .. location, nil, nil, width)
end

local function collect_picker_refs()
  if not state.messages then
    return {}
  end

  local seen = {}
  local refs = {}

  for i = #state.messages, 1, -1 do
    local msg = state.messages[i]
    if msg.info and msg.info.role == 'assistant' then
      local message_id = msg.info.id

      local c = cache[message_id]
      if c then
        for _, ref in ipairs(c.refs) do
          local key = ref.file_path .. ':' .. (ref.line or 0)
          if not seen[key] then
            seen[key] = true
            table.insert(refs, ref)
          end
        end
      end

      if msg.parts then
        for _, part in ipairs(msg.parts) do
          if part.type == 'tool' then
            local file_path = vim.tbl_get(part, 'state', 'input', 'filePath')
            if file_path and vim.fn.filereadable(file_path) == 1 then
              local key = file_path .. ':0'
              if not seen[key] then
                seen[key] = true
                local rel = vim.fn.fnamemodify(file_path, ':~:.')
                table.insert(refs, make_ref(rel, '', '', 0, 0))
              end
            end
          end
        end
      end
    end
  end

  return refs
end

function M.pick()
  local refs = collect_picker_refs()
  if #refs == 0 then
    vim.notify('No code references found in the conversation', vim.log.levels.INFO)
    return
  end

  return base_picker.pick({
    items = refs,
    format_fn = format_reference_item,
    actions = {},
    callback = function(selected)
      if selected then
        M.navigate_to(selected)
      end
    end,
    title = 'Code References (' .. #refs .. ')',
    width = config.ui.picker_width or 100,
    preview = 'file',
    layout_opts = config.ui.picker,
  })
end

function M.navigate_to(ref)
  local file_path = make_absolute_path(ref.file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    vim.notify('File not found: ' .. file_path, vim.log.levels.WARN)
    return
  end

  vim.cmd('tabedit ' .. vim.fn.fnameescape(file_path))
  if ref.line then
    local line = math.max(1, ref.line)
    local col = ref.col and math.max(0, ref.col - 1) or 0
    local line_count = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(line, line_count), col })
    vim.cmd('normal! zz')
  end
end

---Setup reference picker event subscriptions
---Should be called once during plugin initialization
function M.setup()
  state.store.subscribe('messages', function()
    M.clear_all()
  end)
end

return M
