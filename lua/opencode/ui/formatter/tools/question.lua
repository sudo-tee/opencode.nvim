local M = {}

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  -- question tool never shows duration
  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('question'), 'question', '', nil)
  output:add_empty_line()
  if not config.ui.output.tools.show_output or (part.state and part.state.status) ~= 'completed' then
    return
  end

  local questions = input.questions or {}
  local answers = metadata.answers or {}

  for i, question in ipairs(questions) do
    local question_lines = vim.split(question.question, '\n')
    if #question_lines > 1 then
      output:add_line(string.format('**Q%d:** %s', i, question.header))
      for _, line in ipairs(question_lines) do
        output:add_line(line)
      end
    else
      output:add_line(string.format('**Q%d:** %s', i, question_lines[1]))
    end

    local answer = answers[i] and answers[i][1] or 'No answer'
    local answer_lines = vim.split(answer, '\n', { plain = true })
    output:add_line(string.format('**A%d:** %s', i, answer_lines[1]))
    for line_idx = 2, #answer_lines do
      output:add_line(answer_lines[line_idx])
    end

    if i < #questions then
      output:add_line('')
    end
  end
end

return M
