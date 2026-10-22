local M = {}

---@param output Output
---@param part OpencodeQuestionToolPart
function M.format(output, part)
  if part.name ~= 'question' then
    return
  end

  local utils = require('opencode.ui.formatter.utils')

  -- question tool never shows duration
  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('question'), 'question', '', nil)
  output:add_empty_line()

  if part.state ~= 'completed' then
    return
  end

  local answers = part.answers or {}
  if #answers == 0 and part.answer_text then
    output:add_lines(require('opencode.util').sanitize_lines(vim.split(part.answer_text, '\n')))
    return
  end

  for i, answer_item in ipairs(answers) do
    local question_lines = vim.split(answer_item.question or '', '\n')
    if #question_lines > 1 then
      output:add_line(string.format('**Q%d:** %s', i, answer_item.header or ''))
      for _, line in ipairs(question_lines) do
        output:add_line(line)
      end
    else
      output:add_line(string.format('**Q%d:** %s', i, question_lines[1]))
    end

    local selected = answer_item.values
    local answer = #selected > 0 and table.concat(selected, ', ') or 'No answer'
    local answer_lines = vim.split(answer, '\n', { plain = true })
    output:add_line(string.format('**A%d:** %s', i, answer_lines[1]))
    for line_idx = 2, #answer_lines do
      output:add_line(answer_lines[line_idx])
    end

    if i < #answers then
      output:add_line('')
    end
  end
end

return M
