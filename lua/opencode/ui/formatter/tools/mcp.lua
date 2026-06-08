local icons = require('opencode.ui.icons')
local utils = require('opencode.ui.formatter.utils')
local config = require('opencode.config')

local M = {}

local CONTENT_FIELDS = { 'thought', 'content', 'text', 'query', 'url', 'input' }

---@param tool_name string
---@return string|nil server
---@return string|nil tool
local function parse_mcp_tool_name(tool_name)
  -- MCP tool names are formatted as {server}_{tool}
  -- Server name can contain hyphens, so we match the last underscore
  local last_underscore = tool_name:reverse():find('_')
  if not last_underscore then
    return nil, nil
  end
  local split_pos = #tool_name - last_underscore + 1
  local server = tool_name:sub(1, split_pos - 1)
  local tool = tool_name:sub(split_pos + 1)
  return server, tool
end

---@param input table
---@return string|nil field_name
---@return any field_value
local function find_content_field(input)
  for _, field in ipairs(CONTENT_FIELDS) do
    if input[field] and input[field] ~= '' then
      return field, input[field]
    end
  end
  return nil, nil
end

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  local tool_name = part.tool
  if not tool_name then
    return
  end

  local server, tool = parse_mcp_tool_name(tool_name)
  if not server or not tool then
    return
  end

  local input = part.state and part.state.input
  if type(input) ~= 'table' then
    input = {}
  end

  -- Title line (avoid **bold** markdown so highlight isn't overridden by RenderMarkdown)
  local title = string.format('%s %s: %s', icons.get('tool'), server, tool)
  local duration = utils.get_duration_text(part)
  if duration then
    title = title .. ' ' .. duration
  end
  local title_line = output:get_line_count() + 1
  output:add_line(title)

  -- Content rendering (input only, not output)
  local content_start = nil
  local _, content_value = find_content_field(input)
  if not content_value and next(input) ~= nil then
    local ok, json_str = pcall(vim.json.encode, input)
    if ok then
      content_value = json_str
    end
  end
  if content_value then
    content_start = output:get_line_count() + 1
    output:add_empty_line()

    if type(content_value) == 'string' then
      output:add_lines(vim.split(content_value, '\n'))
    else
      local ok, json_str = pcall(vim.json.encode, content_value)
      if ok then
        output:add_lines(vim.split(json_str, '\n'))
      end
    end

    output:add_empty_line()

    local show = config.ui.output.tools.show_output
    local use_folds = config.ui.output.tools.use_folds
    output:add_fold_with_threshold(content_start, show, use_folds)
  end

  -- Apply dimmed highlight to title and all content lines
  local end_line = output:get_line_count()
  for line = title_line, end_line do
    output:add_extmark(line - 1, { line_hl_group = 'OpencodeHint', priority = 5000 })
  end
end

---@param _ OpencodeMessagePart
---@param input table
---@return string, string, string
function M.summary(_, input)
  return icons.get('tool'), 'mcp', (input and (input.query or input.url)) or ''
end

return M
