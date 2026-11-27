---@class OpencodeAttachment
---@field name string
---@field uri string `file://` or `data:` URI as sent to the server
---@field media_type? string
---@field path? string Local path for a `file://` URI, after `server.reverse_path_map`
---@field part_id? string Key for `get_rendered_part`; absent outside the output window

---@class OpencodeAttachmentFormatter
---@field format fun(output: Output, attachment: OpencodeAttachment) Write the attachment's lines; write none to decline

---@class OpencodeAttachmentFormatterRecord
---@field name string
---@field spec OpencodeAttachmentFormatter
---@field last_error? string

local M = {}

---@type OpencodeAttachmentFormatterRecord[]
local records = {}

---@param name string
---@param formatter OpencodeAttachmentFormatter
function M.register(name, formatter)
  if name == '' then
    error('Attachment formatter name must be a non-empty string')
  end
  for _, record in ipairs(records) do
    if record.name == name then
      error('Attachment formatter already registered: ' .. name)
    end
  end
  records[#records + 1] = { name = name, spec = formatter }
end

---@param name string
---@return boolean
function M.unregister(name)
  for i, record in ipairs(records) do
    if record.name == name then
      table.remove(records, i)
      return true
    end
  end
  return false
end

---Let the first formatter that writes lines render the attachment.
---A failing formatter's partial output is discarded and the next one is tried.
---@param output Output
---@param attachment OpencodeAttachment
---@return boolean formatted
function M.format(output, attachment)
  for _, record in ipairs(records) do
    local saved = output:snapshot()
    local ok, err = pcall(record.spec.format, output, vim.deepcopy(attachment))
    local message = not ok and tostring(err) or nil
    -- format runs on every redraw of the output; log each distinct failure once.
    if message and message ~= record.last_error then
      require('opencode.log').error('Attachment formatter "' .. record.name .. '" failed: ' .. message)
    end
    record.last_error = message
    if ok and output:get_line_count() > #saved.lines then
      return true
    end
    output:restore(saved)
  end
  return false
end

---Test helper.
function M._reset()
  records = {}
end

return M
