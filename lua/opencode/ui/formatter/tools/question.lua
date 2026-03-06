local M = {}

---@param ctx table
function M.format(ctx)
  local input = ctx.input or {}
  local metadata = ctx.metadata or {}

  ctx.format_action(ctx.output, 'question', 'question', '', ctx.duration_text)
  ctx.output:add_empty_line()
  if not ctx.config.ui.output.tools.show_output or ctx.status ~= 'completed' then
    return
  end

  local questions = input.questions or {}
  local answers = metadata.answers or {}

  for i, question in ipairs(questions) do
    local question_lines = vim.split(question.question, '\n')
    if #question_lines > 1 then
      ctx.output:add_line(string.format('**Q%d:** %s', i, question.header))
      for _, line in ipairs(question_lines) do
        ctx.output:add_line(line)
      end
    else
      ctx.output:add_line(string.format('**Q%d:** %s', i, question_lines[1]))
    end

    local answer = answers[i] and answers[i][1] or 'No answer'
    local answer_lines = vim.split(answer, '\n', { plain = true })
    ctx.output:add_line(string.format('**A%d:** %s', i, answer_lines[1]))
    for line_idx = 2, #answer_lines do
      ctx.output:add_line(answer_lines[line_idx])
    end

    if i < #questions then
      ctx.output:add_line('')
    end
  end
end

return M
