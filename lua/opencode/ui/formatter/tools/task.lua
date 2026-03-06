local M = {}

---@param part OpencodeMessagePart
---@param status string
---@param build_action_line fun(icon_name: string, tool_type: string, value: string, duration_text?: string): string
---@param handlers table<string, fun(part: OpencodeMessagePart, input: table, metadata?: table): string, string, string>
---@return string
function M.tool_action_line(part, status, build_action_line, handlers)
  local tool = part.tool
  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}
  local handler = handlers[tool] or handlers.tool
  local icon_name, tool_label, tool_value = handler(part, input, metadata)
  if status ~= 'completed' then
    icon_name = status
  end

  return build_action_line(icon_name, tool_label or tool or 'tool', tool_value)
end

---@param ctx table
function M.format(ctx)
  local input = ctx.input or {}
  local metadata = ctx.metadata or {}

  local start_line = ctx.output:get_line_count() + 1

  local description = input.description or ''
  local agent_type = input.subagent_type
  if agent_type then
    description = string.format('%s (@%s)', description, agent_type)
  end

  ctx.format_action(ctx.output, 'task', 'task', description, ctx.duration_text)

  if ctx.config.ui.output.tools.show_output then
    local child_session_id = metadata.sessionId
    local child_parts = child_session_id and ctx.get_child_parts and ctx.get_child_parts(child_session_id)

    if child_parts and #child_parts > 0 then
      ctx.output:add_empty_line()

      for _, item in ipairs(child_parts) do
        if item.tool then
          local status = item.state and item.state.status or 'pending'
          ctx.output:add_line(' ' .. M.tool_action_line(item, status, ctx.build_action_line, ctx.tool_summary_handlers))
        end
      end

      ctx.output:add_empty_line()
    end

    if ctx.tool_output and ctx.tool_output ~= '' then
      local clean_output = ctx.tool_output:gsub('<task_result>', ''):gsub('</task_result>', '')
      if clean_output ~= '' then
        ctx.output:add_empty_line()
        ctx.output:add_lines(vim.split(clean_output, '\n'))
        ctx.output:add_empty_line()
      end
    end
  end

  local end_line = ctx.output:get_line_count()
  ctx.output:add_action({
    text = '[S]elect Child Session',
    type = 'select_child_session',
    args = {},
    key = 'S',
    display_line = start_line - 1,
    range = { from = start_line, to = end_line },
  })
end

---@param _ OpencodeMessagePart
---@param input TaskToolInput
---@return string, string, string
function M.summary(_, input)
  return 'task', 'task', input.description or ''
end

return M
