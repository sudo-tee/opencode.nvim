local icons = require('opencode.ui.icons')
local context = require('opencode.context')

local M = {}
local stats_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffStats')
local title_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffTitle')
local turns_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffTurns')
local comments_ns = vim.api.nvim_create_namespace('OpencodeSessionDiffComments')
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
  ---@type table<string, OpencodeContextReviewComment[]>
  local comments_by_file = {}
  for _, comment in ipairs(context.get_review_comments()) do
    local comments = comments_by_file[comment.file]
    if not comments then
      comments = {}
      comments_by_file[comment.file] = comments
    end
    comments[#comments + 1] = comment
  end
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
        local prefix = '  ' .. file.status:sub(1, 1):upper() .. ' ' .. indent .. '  '
        local comments = comments_by_file[file.file] or {}
        lines[#lines + 1] = ('%s%s %s  +%d -%d%s'):format(
          prefix, icon, child.name, file.additions, file.deletions,
          #comments > 0 and ('  %s%d%s'):format(icons.get('review_comment'), #comments,
            #vim.tbl_filter(function(comment)
              return comment.session_id ~= view.session.id or comment.from ~= view.from or comment.to ~= view.to
            end, comments) > 0 and '*' or '') or ''
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
        local prefix = '  ' .. '  ' .. indent .. (child.expanded and '▾ ' or '▸ ')
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
      local stats = '+' .. file.additions .. ' -' .. file.deletions
      local add_start = assert(line:find(stats, 1, true)) - 1
      local del_start = add_start + #('+' .. file.additions .. ' ')
      vim.api.nvim_buf_set_extmark(view.list_buf, stats_ns, row - 1, add_start, {
        end_col = del_start - 1,
        hl_group = 'Added',
      })
      vim.api.nvim_buf_set_extmark(view.list_buf, stats_ns, row - 1, del_start, {
        end_col = del_start + #('-' .. file.deletions),
        hl_group = 'Removed',
      })
      if comments_by_file[file.file] then
        vim.api.nvim_buf_set_extmark(view.list_buf, stats_ns, row - 1, del_start + #('-' .. file.deletions), {
          end_col = #line,
          hl_group = 'OpencodeContextReviewComment',
        })
      end
    end
  end
end

---@param view OpencodeSessionDiffView
function M.comments(view)
  local file = assert(view.files[view.index])
  local map = view.mode == 'patch' and view.patch_map or nil
  for _, win in ipairs(view.right_win and { view.preview_win, view.right_win } or { view.preview_win }) do
    local buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_clear_namespace(buf, comments_ns, 0, -1)
    local count = vim.api.nvim_buf_line_count(buf)
    for _, comment in ipairs(context.get_review_comments(file.file)) do
      local same_range = comment.session_id == view.session.id and comment.from == view.from and comment.to == view.to
      local start_line, end_line = comment.start_line, comment.end_line
      local found = same_range
      if not same_range and comment.session_id == view.session.id then
        local side_lines
        if map then
          side_lines = comment.side == 'after' and view.after_lines or view.before_lines
        elseif (win == view.preview_win and comment.side == 'before') or (win == view.right_win and comment.side == 'after') then
          side_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
        if side_lines then
          local code = vim.split(comment.code, '\n', { plain = true })
          for index = 1, #side_lines - #code + 1 do
            if table.concat(vim.list_slice(side_lines, index, index + #code - 1), '\n') == comment.code then
              start_line, end_line = index, index + #code - 1
              found = true
              break
            end
          end
        end
      end
      local rows = {}
      if found then
        if map then
          for row, entry in ipairs(map) do
            local number = comment.side == 'after' and entry.new or nil
            if comment.side == 'before' then
              number = entry.old
            end
            if number and number >= start_line and number <= end_line then
              rows[#rows + 1] = row
            end
          end
        elseif (win == view.preview_win and comment.side == 'before') or (win == view.right_win and comment.side == 'after') then
          for row = start_line, end_line do
            rows[#rows + 1] = row
          end
        end
      end
      if #rows > 0 then
        for _, row in ipairs(rows) do
          if row <= count then
            vim.api.nvim_buf_set_extmark(buf, comments_ns, row - 1, 0, {
              sign_text = icons.get('review_comment'),
              sign_hl_group = same_range and 'OpencodeReviewCommentSign' or 'Comment',
            })
          end
        end
        local last = rows[#rows]
        if last and last <= count then
          local parts = vim.split(comment.comment, '\n', { plain = true })
          local label = parts[1]:sub(1, 72) .. (#parts > 1 and (' (+%d lines)'):format(#parts - 1) or '')
          local resolution = comment.resolution
          local status = resolution and resolution.status
          local badge = not same_range and ' from another turn' or status == 'moved' and (' moved → L' .. resolution.start_line)
            or status == 'modified' and ' changed since review'
            or status == 'removed' and ' code removed'
            or status == 'missing_file' and ' file missing' or ''
          vim.api.nvim_buf_set_extmark(buf, comments_ns, last - 1, 0, {
            virt_lines = { { { '  ' .. label, same_range and 'OpencodeReviewComment' or 'Comment' },
              { badge, same_range and 'OpencodeReviewCommentStale' or 'Comment' } } },
          })
        end
      end
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
  if view.range_key then
    local message_count = view.range_mode and view.turn_to - view.turn_from + 1 or view.message_count
    local message_label = message_count == 1 and '1 message' or message_count and (message_count .. ' messages') or 'Message range'
    lines[#lines + 1] = {
      { '  ' .. message_label .. ' · ', 'Comment' },
      { '<' .. view.range_key .. '>', 'OpencodeInputLegend' },
      { ' choose range', 'Comment' },
    }
  end
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
