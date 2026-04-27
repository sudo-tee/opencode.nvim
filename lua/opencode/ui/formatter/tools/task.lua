local M = {}
local icons = require('opencode.ui.icons')

---@param part OpencodeMessagePart
---@param status string
---@param utils table
---@return string
function M.tool_action_line(part, status, utils)
  local tool_formatters = require('opencode.ui.formatter.tools')
  local tool = part.tool
  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}
  local formatter = tool_formatters[tool] or tool_formatters.tool
  local summary = formatter.summary or tool_formatters.tool.summary
  local icon, tool_label, tool_value = summary(part, input, metadata)

  if status ~= 'completed' then
    icon = icons.get(status)
  end

  return utils.build_action_line(icon, tool_label or tool or 'tool', tool_value)
end

---@param output Output
---@param part OpencodeMessagePart
---@param get_child_parts? fun(session_id: string): OpencodeMessagePart[]?
function M.format(output, part, get_child_parts)
  if part.tool ~= 'task' then
    return
  end

  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}
  local tool_output = part.state and part.state.output or ''

  local start_line = output:get_line_count() + 1

  local description = input.description or ''
  local agent_type = input.subagent_type
  if agent_type then
    description = string.format('%s (@%s)', description, agent_type)
  end

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  utils.format_action(output, icons.get('task'), 'task', description, utils.get_duration_text(part))

  local output_start_line = output:get_line_count() + 1
  if config.ui.output.tools.show_output or config.ui.output.tools.use_folds then
    local child_session_id = metadata.sessionId
    local child_parts = child_session_id and get_child_parts and get_child_parts(child_session_id)

    if child_parts and #child_parts > 0 then
      output:add_empty_line()

      for _, item in ipairs(child_parts) do
        if item.tool then
          local status = item.state and item.state.status or 'pending'
          output:add_line(' ' .. M.tool_action_line(item, status, utils))
        end
      end

      output:add_empty_line()
    end

    if tool_output ~= '' then
      local clean_output = tool_output:gsub('<task_result>', ''):gsub('</task_result>', '')
      if clean_output ~= '' then
        output:add_empty_line()
        output:add_lines(vim.split(clean_output, '\n'))
        output:add_empty_line()
      end
    end

    output:add_fold_with_threshold(output_start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
  end

  local end_line = output:get_line_count()
  output:add_action({
    text = '[S]elect Child Session',
    type = 'select_child_session',
    args = {},
    key = 'S',
    display_line = start_line,
    range = { from = start_line + 1, to = end_line + 1 },
  })
end

---@param _ OpencodeMessagePart
---@param input TaskToolInput
---@return string, string, string
function M.summary(_, input)
  return icons.get('task'), 'task', input.description or ''
end

return M
