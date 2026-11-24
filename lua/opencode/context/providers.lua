local state = require('opencode.state')
local util = require('opencode.util')

local M = {}

---@class OpencodeContextProviderItem
---@field id string Stable within the provider; used for deduplication and removal
---@field name string Attachment name shown to the user and the model
---@field text string Exact text sent as a text/plain attachment

---@class OpencodeContextProviderCollectContext
---@field prompt string Current draft text

---@class OpencodeContextProviderPreview
---@field text string
---@field filetype? string

---@class OpencodeContextProviderAttachment
---@field name string
---@field text string
---@field media_type string

---@class OpencodeContextProvider
---@field name string
---@field label string
---@field icon? string
---@field enabled? boolean Defaults to false; providers must be enabled explicitly
---@field reference? boolean Send an item only while `@<item.name>` is in the prompt
---@field collect fun(ctx: OpencodeContextProviderCollectContext): OpencodeContextProviderItem[]
---@field preview? fun(item: OpencodeContextProviderItem): string|OpencodeContextProviderPreview
---@field remove? fun(item: OpencodeContextProviderItem)
---@field on_sent? fun(items: OpencodeContextProviderItem[]) Called once the server accepts the prompt
---@field render? fun(attachment: OpencodeContextProviderAttachment): string|string[]|nil Output lines for a sent attachment; nil declines it

---@class OpencodeContextProviderRecord
---@field spec OpencodeContextProvider
---@field enabled boolean
---@field last_error? string
---@field last_render_error? string

---@class OpencodeContextProviderResult
---@field provider OpencodeContextProvider
---@field items OpencodeContextProviderItem[]
---@field error? string

---@type OpencodeContextProviderRecord[]
local records = {}

---@param name string
---@return OpencodeContextProviderRecord?
local function find(name)
  for _, record in ipairs(records) do
    if record.spec.name == name then
      return record
    end
  end
  return nil
end

---@param item OpencodeContextProviderItem
---@return string
function M.reference(item)
  return '@' .. item.name
end

---@param items any
---@param reference? boolean
---@return string? error
local function validate_items(items, reference)
  if type(items) ~= 'table' or not vim.islist(items) then
    return 'collect must return a list of items'
  end
  local seen = {}
  for index, item in ipairs(items) do
    if type(item) ~= 'table' then
      return ('item %d is not a table'):format(index)
    end
    if type(item.id) ~= 'string' or item.id == '' or seen[item.id] then
      return ('item %d needs a unique non-empty string id'):format(index)
    end
    if type(item.name) ~= 'string' or item.name == '' or item.name:find('%c') then
      return ('item %d needs a non-empty single-line name'):format(index)
    end
    if reference and (not item.name:match('^[%w_%-%./]+$') or seen['name:' .. item.name]) then
      return ('item %d needs a unique name of [%%w_-./] characters to be referenced'):format(index)
    end
    if type(item.text) ~= 'string' or item.text == '' or item.text:find('\0', 1, true) then
      return ('item %d needs non-empty text without NUL bytes'):format(index)
    end
    seen[item.id] = true
    seen['name:' .. item.name] = true
  end
  return nil
end

---@param provider OpencodeContextProvider
function M.register(provider)
  if not provider.name:match('^[%w_-]+$') then
    error('Context provider name must match [%w_-]+: ' .. provider.name)
  end
  if require('opencode.config').context[provider.name] ~= nil then
    error('Context provider name is reserved for built-in context: ' .. provider.name)
  end
  if find(provider.name) then
    error('Context provider already registered: ' .. provider.name)
  end
  if provider.label == '' then
    error('Context provider label must be non-empty: ' .. provider.name)
  end
  records[#records + 1] = { spec = provider, enabled = provider.enabled == true }
  M.refresh()
end

---@param name string
---@return boolean
function M.unregister(name)
  for index, record in ipairs(records) do
    if record.spec.name == name then
      table.remove(records, index)
      M.refresh()
      return true
    end
  end
  return false
end

---@return OpencodeContextProvider[]
function M.list()
  return vim.tbl_map(function(record)
    return record.spec
  end, records)
end

---@param name string
---@return boolean
function M.is_enabled(name)
  local record = find(name)
  return record ~= nil and record.enabled
end

---@param name string
---@param enabled boolean
function M.set_enabled(name, enabled)
  local record = find(name)
  if record then
    record.enabled = enabled
    M.refresh()
  end
end

---Redraw context surfaces after a provider's items changed.
function M.refresh()
  state.context.set_context_updated_at(vim.uv.now())
end

---@return string
local function input_prompt()
  local buf = state.windows and state.windows.input_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

---Collect items from every enabled provider. A failing provider yields an
---error result and never affects the others. Items of a `reference`
---provider are only returned while the prompt references them.
---@param prompt? string Defaults to the current input buffer text
---@return OpencodeContextProviderResult[]
function M.collect(prompt)
  prompt = prompt or input_prompt()
  local results = {}
  for _, record in ipairs(records) do
    if record.enabled then
      local provider = record.spec
      local ok, items = pcall(provider.collect, { prompt = prompt })
      local err = ok and validate_items(items, provider.reference) or (not ok and tostring(items) or nil)
      -- collect also runs on every context-bar redraw; log each distinct failure once.
      if err and err ~= record.last_error then
        require('opencode.log').error('Context provider "' .. provider.name .. '" failed: ' .. err)
      end
      record.last_error = err
      if err then
        results[#results + 1] = { provider = provider, items = {}, error = err }
      else
        if provider.reference then
          items = vim.tbl_filter(function(item)
            return util.has_reference(prompt, M.reference(item))
          end, items)
        end
        results[#results + 1] = { provider = provider, items = items }
      end
    end
  end
  return results
end

---Preview shown in the `#` picker; falls back to the exact text.
---@param provider OpencodeContextProvider
---@param item OpencodeContextProviderItem
---@return OpencodeContextProviderPreview
function M.preview(provider, item)
  if provider.preview then
    local ok, preview = pcall(provider.preview, item)
    if ok and type(preview) == 'string' then
      return { text = preview }
    elseif ok and type(preview) == 'table' and type(preview.text) == 'string' then
      return preview
    end
    require('opencode.log').error(
      'Context provider "'
        .. provider.name
        .. '" preview failed: '
        .. (ok and 'must return a string or { text }' or tostring(preview))
    )
  end
  return { text = item.text }
end

---@param provider_name string
---@param item OpencodeContextProviderItem
---@return string key
---@return string fingerprint
function M.fingerprint(provider_name, item)
  return 'provider:' .. provider_name .. ':' .. item.id, vim.fn.sha256(item.name .. '\0' .. item.text)
end

---Whether the item's exact payload was already sent in this session.
---@param provider_name string
---@param item OpencodeContextProviderItem
---@param last_sent? OpencodeContext
---@return boolean
function M.is_sent(provider_name, item, last_sent)
  local key, fingerprint = M.fingerprint(provider_name, item)
  return last_sent ~= nil and last_sent.automatic_context ~= nil and last_sent.automatic_context[key] == fingerprint
end

---@param provider_name string
---@param item OpencodeContextProviderItem
function M.remove(provider_name, item)
  local record = find(provider_name)
  if record and record.spec.remove then
    local ok, err = pcall(record.spec.remove, item)
    if not ok then
      require('opencode.log').error('Context provider "' .. provider_name .. '" remove failed: ' .. tostring(err))
    end
  end
  M.refresh()
end

---Output lines for an attachment from the first provider that renders it.
---Disabled providers render too: the attachment may come from history.
---@param attachment OpencodeContextProviderAttachment
---@return string[]? lines
---@return OpencodeContextProvider? provider
function M.render(attachment)
  for _, record in ipairs(records) do
    local provider = record.spec
    if provider.render then
      local ok, rendered = pcall(provider.render, attachment)
      local err
      if not ok then
        err = tostring(rendered)
      elseif
        rendered ~= nil
        and type(rendered) ~= 'string'
        and not (
          vim.islist(rendered)
          and vim.iter(rendered):all(function(line)
            return type(line) == 'string'
          end)
        )
      then
        err = 'render must return a string, a list of lines, or nil'
      end
      -- render runs on every redraw of the output; log each distinct failure once.
      if err and err ~= record.last_render_error then
        require('opencode.log').error('Context provider "' .. provider.name .. '" render failed: ' .. err)
      end
      record.last_render_error = err
      if not err and rendered ~= nil then
        ---@cast rendered string|string[]
        local lines = {}
        for _, chunk in ipairs(type(rendered) == 'string' and { rendered } or rendered) do
          vim.list_extend(lines, vim.split(chunk, '\n'))
        end
        return lines, provider
      end
    end
  end
  return nil
end

---@param sent table<string, OpencodeContextProviderItem[]>
function M.notify_sent(sent)
  for name, items in pairs(sent) do
    local record = find(name)
    if record and record.spec.on_sent then
      local ok, err = pcall(record.spec.on_sent, items)
      if not ok then
        require('opencode.log').error('Context provider "' .. name .. '" on_sent failed: ' .. tostring(err))
      end
    end
  end
  if next(sent) then
    M.refresh()
  end
end

---Test helper.
function M._reset()
  records = {}
end

return M
