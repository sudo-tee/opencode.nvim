local M = {}
local icons = require('opencode.ui.icons')

---@param part table
---@param status string
---@param utils table
---@param tool_formatters table registry of tool formatters (passed in by the
--- dispatch site; requiring the registry module here would form a cycle)
---@return string
function M.tool_action_line(part, status, utils, tool_formatters)
  local tool = part.name
  local formatter = tool_formatters[tool] or tool_formatters.tool
  local summary = formatter.summary or tool_formatters.tool.summary
  local icon, tool_label, tool_value = summary(part)

  if status ~= 'completed' then
    icon = icons.get(status)
  end

  return utils.build_action_line(icon, tool_label or tool or 'tool', tool_value)
end

---@param output Output
---@param part table
---@param context? FormatterContext
---@param tool_formatters? table registry passed in by the dispatch site
function M.format(output, part, context, tool_formatters)
  if part.name ~= 'task' then
    return
  end

  local tool_output = require('opencode.ui.formatter.utils').tool_result_text(part)

  local start_line = output:get_line_count() + 1

  local description = part.description or ''
  local agent_type = part.input and part.input.subagent_type
  if agent_type then
    description = string.format('%s (@%s)', description, agent_type)
  end

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  utils.format_action(output, icons.get('task'), 'task', description, utils.get_duration_text(part))

  local output_start_line = output:get_line_count() + 1
  if config.ui.output.tools.show_output or config.ui.output.tools.use_folds then
    local child_session_id = part.child_session and part.child_session.id
    local child_parts = child_session_id
      and context
      and context.get_child_parts
      and context.get_child_parts(child_session_id)

    if child_parts and #child_parts > 0 then
      output:add_empty_line()

      for _, item in ipairs(child_parts) do
        if item.kind == 'tool' then
          local status = item.state or 'pending'
          output:add_line(' ' .. M.tool_action_line(item, status, utils, tool_formatters))
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

    output:add_fold_with_threshold(
      output_start_line,
      config.ui.output.tools.show_output,
      config.ui.output.tools.use_folds
    )
  end

  local end_line = output:get_line_count()
  if part.child_session then
    output:add_action({
      text = '[S] Open this Session',
      type = 'navigate_session_tree',
      args = utils.get_session_action_args(part.child_session.id),
      key = 'S',
      display_line = start_line,
      range = { from = start_line + 1, to = end_line + 1 },
    })
  end
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('task'), 'task', part.description or ''
end

return M
