local icons = require('opencode.ui.icons')

local M = {}
local stats_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffStats')
local title_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffTitle')
local turns_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffTurns')
local status_highlights = { added = 'Added', modified = 'DiagnosticWarn', deleted = 'Removed' }

---@class OpencodeSessionDiffNode
---@field name string
---@field path string
---@field children OpencodeSessionDiffNode[]
---@field by_name table<string, OpencodeSessionDiffNode>
---@field expanded boolean
---@field file_index? integer

---@param files OpencodeV2FileDiff[]
---@return OpencodeSessionDiffNode
function M.build_tree(files)
  ---@type OpencodeSessionDiffNode
  local root = { name = '', path = '', children = {}, by_name = {}, expanded = true }
  local cwd = vim.fn.getcwd():gsub('/$', '') .. '/'
  for index, file in ipairs(files) do
    local path = file.file:sub(1, #cwd) == cwd and file.file:sub(#cwd + 1) or file.file
    local parent = root
    local parts = vim.split(path, '/', { plain = true, trimempty = true })
    for part_index, name in ipairs(parts) do
      local node = parent.by_name[name]
      if not node then
        node = {
          name = name,
          path = parent.path .. '/' .. name,
          children = {},
          by_name = {},
          expanded = true,
        }
        parent.by_name[name] = node
        parent.children[#parent.children + 1] = node
      end
      if part_index == #parts then
        node.file_index = index
      end
      parent = node
    end
  end
  return root
end

---@param view OpencodeSessionDiffView
---@param file_icon fun(name: string): string, string?
function M.tree(view, file_icon)
  local lines = { '' }
  local rows = { view.tree }
  ---@type {row: integer, start: integer, finish: integer, group: string}[]
  local marks = {}
  ---@param node OpencodeSessionDiffNode
  ---@param depth integer
  local function walk(node, depth)
    table.sort(node.children, function(a, b)
      if (a.file_index == nil) ~= (b.file_index == nil) then
        return a.file_index == nil
      end
      return a.name < b.name
    end)
    for _, child in ipairs(node.children) do
      local indent = string.rep('  ', depth)
      if child.file_index then
        local file = assert(view.files[child.file_index])
        local icon, highlight = file_icon(child.name)
        local prefix = '  ' .. file.status:sub(1, 1):upper() .. '     ' .. indent
        lines[#lines + 1] = ('%s%s %s  +%d -%d'):format(
          prefix, icon, child.name, file.additions, file.deletions
        )
        marks[#marks + 1] = { row = #lines, start = 2, finish = 3, group = status_highlights[file.status] }
        if highlight then
          marks[#marks + 1] = { row = #lines, start = #prefix, finish = #prefix + #icon, group = highlight }
        end
        rows[#rows + 1] = child
      else
        local last = child
        local name = child.name
        while last.expanded and #last.children == 1 and last.children[1].file_index == nil and last.children[1].expanded do
          last = last.children[1]
          name = name .. '/' .. last.name
        end
        local prefix = '    ' .. indent .. (child.expanded and '▾ ' or '▸ ')
        lines[#lines + 1] = prefix .. icons.get('folder') .. name .. '/'
        marks[#marks + 1] = { row = #lines, start = #prefix, finish = #lines[#lines], group = 'Directory' }
        rows[#rows + 1] = child
        if last.expanded then
          walk(last, depth + 1)
        end
      end
    end
  end
  walk(view.tree, 0)
  view.rows = rows
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, lines)
  vim.bo[view.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.list_buf, stats_ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(view.list_buf, stats_ns, mark.row - 1, mark.start, {
      end_col = mark.finish,
      hl_group = mark.group,
    })
  end
  for row, node in ipairs(rows) do
    if node.file_index then
      local file = view.files[node.file_index] --[[@as OpencodeV2FileDiff]]
      local line = assert(lines[row])
      local add_start = #line - #('+' .. file.additions .. ' -' .. file.deletions)
      local del_start = #line - #('-' .. file.deletions)
      vim.api.nvim_buf_set_extmark(view.list_buf, stats_ns, row - 1, add_start, {
        end_col = del_start - 1,
        hl_group = 'Added',
      })
      vim.api.nvim_buf_set_extmark(view.list_buf, stats_ns, row - 1, del_start, {
        end_col = #line,
        hl_group = 'Removed',
      })
    end
  end
end

---@param view OpencodeSessionDiffView
function M.title(view)
  local title = 'Session: ' .. (view.session.title or view.session.id)
  local width = vim.api.nvim_win_get_width(view.list_win) - 4
  local lines = {}
  local line = ''
  for index = 0, vim.fn.strchars(title) - 1 do
    local character = vim.fn.strcharpart(title, index, 1)
    if vim.fn.strdisplaywidth(line .. character) > width then
      lines[#lines + 1] = { { '  ' .. line, 'Title' } }
      line = ''
    end
    line = line .. character
  end
  lines[#lines + 1] = { { '  ' .. line, 'Title' } }
  lines[#lines + 1] = { { ' ' } }
  lines[#lines + 1] = { { ('  Changes (%d)'):format(#view.files), 'Normal' } }
  if view.from then
    local last = view.to or view.from
    local label = view.from == last and view.from:sub(-12) or view.from:sub(-8) .. ' → ' .. last:sub(-8)
    lines[#lines + 1] = { { '  Range: ' .. label, 'Comment' } }
  end
  vim.api.nvim_buf_clear_namespace(view.list_buf, title_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(view.list_buf, title_ns, 0, 0, {
    virt_lines = lines,
  })
end

---@param text string
---@param limit integer
---@return string
local function truncate(text, limit)
  local result = ''
  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(result .. character) > limit then
      return result .. '…'
    end
    result = result .. character
  end
  return result
end

---@param view OpencodeSessionDiffView
function M.turns(view)
  local lines = {}
  local turn_win = assert(view.turn_win)
  local turn_buf = assert(view.turn_buf)
  ---@type table<integer, {from?: boolean, to?: boolean, date?: string, inactive?: boolean}>
  local marks = {}
  local width = vim.api.nvim_win_get_width(turn_win) - 3
  for index, turn in ipairs(view.turns) do
    local from = index == view.turn_from and 'F' or ' '
    local to = index == view.turn_to and 'T' or ' '
    local date = ''
    if turn.created then
      local timestamp = math.floor(turn.created / 1000)
      date = os.date('%Y-%m-%d', timestamp) == os.date('%Y-%m-%d')
          and os.date('%H:%M', timestamp)
        or os.date('%Y-%m-%d %H:%M', timestamp)
    end
    local text = turn.text:gsub('%s+', ' ')
    local prefix = ('  %s%s  '):format(from, to)
    local date_width = vim.fn.strdisplaywidth(date)
    local date_padding = date ~= '' and date_width + 2 or 0
    lines[#lines + 1] = prefix .. truncate(text, math.max(1, width - vim.fn.strdisplaywidth(prefix) - date_padding))
    marks[#lines] = {
      from = from ~= ' ',
      to = to ~= ' ',
      date = date,
      inactive = index < view.turn_from or index > view.turn_to,
    }
  end
  vim.bo[turn_buf].modifiable = true
  vim.api.nvim_buf_set_lines(turn_buf, 0, -1, false, lines)
  vim.bo[turn_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(turn_buf, turns_ns, 0, -1)
  for row, mark in pairs(marks) do
    local line = assert(lines[row])
    if mark.from then
      vim.api.nvim_buf_set_extmark(turn_buf, turns_ns, row - 1, 2, { end_col = 3, hl_group = 'DiagnosticInfo' })
    end
    if mark.to then
      vim.api.nvim_buf_set_extmark(turn_buf, turns_ns, row - 1, 3, { end_col = 4, hl_group = 'DiagnosticWarn' })
    end
    if mark.date ~= '' then
      vim.api.nvim_buf_set_extmark(turn_buf, turns_ns, row - 1, 0, {
        virt_text = { { mark.date, 'Comment' } },
        virt_text_pos = 'right_align',
      })
    end
    if mark.inactive and #line > 6 then
      vim.api.nvim_buf_set_extmark(turn_buf, turns_ns, row - 1, 6, {
        end_col = #line,
        hl_group = 'Comment',
      })
    end
  end
end

return M
