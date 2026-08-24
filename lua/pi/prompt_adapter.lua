local M = {}

local function read_json(text)
  local ok, value = pcall(vim.json.decode, text or '')
  if ok and type(value) == 'table' then
    return value
  end
end

local function file_path_from_part(part)
  if part.source and part.source.path then
    return part.source.path
  end
  if part.url and part.url:match('^file://') then
    return part.url:gsub('^file://', '')
  end
  return part.filename
end

local function format_text_context(part)
  local metadata = part.metadata or {}
  local context_type = metadata.context_type

  if context_type == 'selection' then
    local data = read_json(part.text)
    if not data then
      return part.text
    end
    local file = data.file or {}
    local path = file.path or file.name or 'unknown file'
    local lines = data.lines and (' lines ' .. data.lines) or ''
    return string.format('Selected text from %s%s:\n%s', path, lines, data.content or '')
  end

  if context_type == 'diagnostics' then
    local data = read_json(part.text)
    if not data or type(data.content) ~= 'table' or #data.content == 0 then
      return nil
    end
    local lines = { 'Diagnostics:' }
    for _, diag in ipairs(data.content) do
      table.insert(lines, string.format('- %s %s', diag.pos or '', diag.msg or ''))
    end
    return table.concat(lines, '\n')
  end

  if context_type == 'cursor-data' then
    local data = read_json(part.text)
    if not data then
      return part.text
    end
    return string.format(
      'Cursor context at line %s, column %s:\n%s',
      tostring(data.line or '?'),
      tostring(data.column or '?'),
      data.line_content or ''
    )
  end

  if context_type == 'file-content' then
    local filename = metadata.filename or 'buffer'
    return string.format('Open buffer %s:\n```\n%s\n```', filename, part.text or '')
  end

  if context_type == 'git-diff' then
    return 'Current git diff:\n```diff\n' .. (part.text or '') .. '\n```'
  end

  return part.text
end

function M.parts_to_prompt(parts)
  local prompt = nil
  local context_blocks = {}
  local referenced_files = {}

  for _, part in ipairs(parts or {}) do
    if part.type == 'file' then
      local path = file_path_from_part(part)
      if path and path ~= '' then
        table.insert(referenced_files, path)
      end
    elseif part.type == 'text' then
      if part.synthetic or part.metadata then
        local text = format_text_context(part)
        if text and text ~= '' then
          table.insert(context_blocks, text)
        end
      elseif part.text and part.text ~= '' then
        prompt = part.text
      end
    elseif part.type == 'agent' and part.name then
      table.insert(context_blocks, 'Requested skill/agent context: ' .. tostring(part.name))
    end
  end

  if #referenced_files > 0 then
    local lines = { 'Referenced files:' }
    for _, path in ipairs(referenced_files) do
      table.insert(lines, '- ' .. path)
    end
    table.insert(context_blocks, 1, table.concat(lines, '\n'))
  end

  if #context_blocks == 0 then
    return prompt or ''
  end

  return table.concat({
    '<context>',
    table.concat(context_blocks, '\n\n'),
    '</context>',
    '',
    prompt or '',
  }, '\n')
end

return M
