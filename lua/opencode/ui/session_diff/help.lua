local M = {}
local ns = vim.api.nvim_create_namespace('OpencodeSessionDiffHelp')

local action_order = {
  activate = 1,
  toggle_range = 2,
  mark_from = 3,
  mark_to = 4,
  show_message_preview = 5,
  toggle_view = 6,
  hide_message_preview = 7,
  close = 8,
  toggle_help = 9,
}

---@class OpencodeSessionDiffHelpSection
---@field title string
---@field entries {key: string, action: string, label: string}[]
---@field width integer

---@param title string
---@param mappings table<string, OpencodeKeymapEntry|false>
---@return OpencodeSessionDiffHelpSection
local function section(title, mappings)
  local entries = {}
  for key, entry in pairs(mappings) do
    if entry ~= false then
      entries[#entries + 1] = { key = key, action = entry[1], label = entry.desc or entry[1] }
    end
  end
  table.sort(entries, function(a, b)
    local left, right = action_order[a.action] or 10, action_order[b.action] or 10
    return left == right and a.key < b.key or left < right
  end)
  local width = vim.fn.strdisplaywidth('  ' .. title)
  for _, entry in ipairs(entries) do
    width = math.max(width, vim.fn.strdisplaywidth(('  %-8s  %s'):format(entry.key, entry.label)))
  end
  return { title = title, entries = entries, width = width }
end

---@param keymaps {list: table<string, OpencodeKeymapEntry|false>, messages: table<string, OpencodeKeymapEntry|false>, preview: table<string, OpencodeKeymapEntry|false>, message_preview: table<string, OpencodeKeymapEntry|false>, help: table<string, OpencodeKeymapEntry|false>}
---@return integer, integer, integer
function M.create(keymaps)
  local sections = {
    section('FILES', keymaps.list),
    section('MESSAGES', keymaps.messages),
    section('DIFF PREVIEW', keymaps.preview),
    section('MESSAGE PREVIEW', keymaps.message_preview),
  }
  local columns = math.max(sections[1].width, sections[3].width)
    + math.max(sections[2].width, sections[4].width) + 3 <= vim.o.columns - 8 and 2 or 1
  local lines = {}
  ---@type {row: integer, start: integer, finish: integer, group: string}[]
  local marks = {}
  local function mark(row, start, finish, group)
    marks[#marks + 1] = { row = row, start = start, finish = finish, group = group }
  end
  for group_index = 1, #sections, columns do
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    local left = sections[group_index] --[[@as OpencodeSessionDiffHelpSection]]
    local right = columns == 2 and sections[group_index + 1] or nil
    local left_width = columns == 2 and math.max(sections[1].width, sections[3].width) or left.width
    local count = math.max(#left.entries, right and #right.entries or 0)
    for row = 0, count do
      local function cell(current)
        if not current then
          return '', 0, nil
        end
        if row == 0 then
          return '  ' .. current.title, #current.title, 'Title'
        end
        local entry = current.entries[row]
        if not entry then
          return '', 0, nil
        end
        return ('  %-8s  %s'):format(entry.key, entry.label), #entry.key, 'Special'
      end
      local left_text, left_key, left_group = cell(left)
      local right_text, right_key, right_group = cell(right)
      local padding = right and string.rep(' ', left_width - vim.fn.strdisplaywidth(left_text) + 3) or ''
      lines[#lines + 1] = left_text .. padding .. right_text
      if left_group then
        mark(#lines - 1, 2, 2 + left_key, left_group)
      end
      if right_group then
        local start = #left_text + #padding + 2
        mark(#lines - 1, start, start + right_key, right_group)
      end
    end
  end
  local close_keys = {}
  for key, entry in pairs(keymaps.help) do
    if entry ~= false and entry[1] == 'toggle_help' then
      close_keys[#close_keys + 1] = key
    end
  end
  table.sort(close_keys)
  lines[#lines + 1] = ''
  local footer = '  ' .. table.concat(close_keys, '  ·  ') .. '   close'
  lines[#lines + 1] = footer
  mark(#lines - 1, 2, #footer, 'Comment')

  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, math.max(1, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, highlight in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, highlight.row, highlight.start, {
      end_col = highlight.finish,
      hl_group = highlight.group,
    })
  end
  return buf, width, height
end

return M
