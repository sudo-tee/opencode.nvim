local icons = require('opencode.ui.icons')
local M = {}

local OUTPUT_LABEL = 'Output: '

---@param value any
---@return string
local function one_line(value)
  if type(value) ~= 'string' then
    return ''
  end
  return vim.trim(value:gsub('[\r\n]+', ' '))
end

---@param output Output
---@param part table
local function format_background_output_file(output, part)
  local utils = require('opencode.ui.formatter.utils')
  local file = utils.tool_result_text(part):match('Output is streaming to: ([^\n]+)')
  if not file then
    return
  end
  output:add_empty_line()
  local line = OUTPUT_LABEL .. file
  local line_idx = output:add_line(line)
  output:add_extmark(line_idx - 1, { start_col = 0, end_col = #OUTPUT_LABEL, hl_group = 'OpencodeHint' })
  output:add_target({
    kind = 'file',
    path = file,
    range = { line = line_idx, start_col = #OUTPUT_LABEL, end_col = #line },
  })
end

---@param output Output
---@param part table
---@param context? FormatterContext
function M.format(output, part, context)
  if part.name ~= 'bash' and part.name ~= 'shell' then
    return
  end

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local input = part.input or {}
  local command = part.command or input.command
  local description = part.description or input.description
  local background = part.background

  -- A backgrounded command returns immediately, so its tool duration is meaningless.
  local duration = not background and utils.get_duration_text(part) or nil
  utils.format_action(output, icons.get('run'), 'run', description or one_line(command), duration)

  local result
  if background then
    result = utils.format_background_badge(output, output:get_line_count(), part, context)
  end

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  -- Background tool text is model-facing instructions; the user sees the job outcome instead.
  local output_text
  if background then
    output_text = result and result.text or ''
  else
    output_text = utils.tool_result_text(part)
  end

  -- Without a description, the header already shows a single-line command.
  local lines = {}
  if command and (description or command:find('\n')) then
    lines = vim.split('> ' .. command, '\n')
  end
  if output_text ~= '' then
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    vim.list_extend(lines, vim.split(output_text, '\n'))
  end
  if #lines > 0 then
    utils.format_code(output, lines, 'bash')
  end

  if background and not result then
    format_background_output_file(output, part)
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('run'), 'run', one_line(part.command or part.description or '')
end

return M
