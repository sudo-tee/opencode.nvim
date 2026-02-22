---In-process LSP server for opencode completion
---Provides completion for files, subagents, commands, and context items
---Works with any LSP-compatible completion plugin (blink.cmp, nvim-cmp, etc.)

local M = {}
---@type table<vim.lsp.protocol.Method, fun(params: table, callback:fun(err: lsp.ResponseError?, result: any))>
local handlers = {}
local ms = vim.lsp.protocol.Methods

---Initialize handler - negotiates capabilities with the client
---@param params lsp.InitializeParams
---@param callback fun(err?: lsp.ResponseError, result: lsp.InitializeResult)
handlers[ms.initialize] = function(params, callback)
  local completion = require('opencode.ui.completion')
  local triggers = completion.get_trigger_characters()

  callback(nil, {
    capabilities = {
      completionProvider = {
        resolveProvider = false,
        triggerCharacters = triggers,
      },
    },
    serverInfo = {
      name = 'opencode_completion_ls',
      version = '1.0.0',
    },
  })
end

---Get word to complete from cursor position
---@param params lsp.CompletionParams
---@return string word_to_complete
---@return string trigger_char
---@return string full_line
local function get_completion_context(params)
  local completion = require('opencode.ui.completion')
  local bufnr = vim.api.nvim_get_current_buf()
  local line_num = params.position.line + 1 -- LSP is 0-indexed
  local col = params.position.character

  local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
  local line = lines[1] or ''
  local line_to_cursor = line:sub(1, col)

  local triggers = completion.get_trigger_characters()
  for _, t in ipairs(triggers) do
    if t and line_to_cursor:match(vim.pesc(t) .. '[^%s]*$') then
      trigger_char = t
      break
    end
  end

  -- Extract word after trigger
  local word = ''
  if trigger_char ~= '' then
    word = line_to_cursor:match(vim.pesc(trigger_char) .. '([^%s]*)$') or ''
  end

  return word, trigger_char, line
end

local function supports_kind_icons()
  -- only blink.cmp supports kind icons currently, so we check for its presence
  local has_blink_cmp = pcall(require, 'blink.cmp')
  return has_blink_cmp
end

---Convert opencode CompletionItem to LSP CompletionItem
---@param item CompletionItem
---@param index integer
---@return lsp.CompletionItem
local function to_lsp_item(item, index)
  local source = require('opencode.ui.completion').get_source_by_name(item.source_name)

  local lsp_item = {
    label = (supports_kind_icons() and '' or (item.kind_icon .. ' ')) .. item.label,
    kind = vim.lsp.protocol.CompletionItemKind.Text,
    kind_icon = supports_kind_icons() and item.kind_icon or nil, -- Only include kind_icon if supported
    kind_hl = item.kind_hl,
    detail = item.detail,
    documentation = item.documentation and {
      kind = 'plaintext',
      value = item.documentation,
    } or nil,
    insertText = item.insert_text or item.label,
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    filterText = item.label,
    sortText = string.format('%02d_%02d_%02d_%s', source.priority or 999, item.priority or 999, index, item.label),
    data = {
      source_name = item.source_name,
      original_data = item.data,
      _opencode_item = item,
    },
  }

  return lsp_item
end

---Completion handler - provides completion items
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result: lsp.CompletionItem[] | lsp.CompletionList)
handlers[ms.textDocument_completion] = function(params, callback)
  local word, trigger_char, line = get_completion_context(params)

  -- Build completion context
  local completion_context = {
    input = word,
    trigger_char = trigger_char,
    line = line,
  }

  local completion = require('opencode.ui.completion')
  local sources = completion.get_sources()

  local Promise = require('opencode.promise')
  local promises = {}

  for _, source in ipairs(sources) do
    table.insert(promises, source.complete(completion_context))
  end

  Promise.all(promises)
    :and_then(function(results)
      local all_items = {}
      local is_incomplete = false

      for i, items in ipairs(results) do
        for _, item in ipairs(items or {}) do
          local source = completion.get_source_by_name(item.source_name)
          if source and source.is_incomplete then
            is_incomplete = true
          end

          table.insert(all_items, to_lsp_item(item, i))
        end
      end

      callback(nil, { isIncomplete = is_incomplete, items = all_items })
      completion.store_completion_items(all_items)
    end)
    :catch(function(err)
      local log = require('opencode.log')
      log.error('Error in completion handler: ' .. tostring(err))
      callback(nil, {})
    end)
end

---Create the LSP server configuration
---@return vim.lsp.ClientConfig
function M.create_config()
  return {
    name = 'opencode_completion_ls',
    cmd = function(dispatchers, config)
      return {
        request = function(method, params, callback)
          if handlers[method] then
            handlers[method](params, callback)
          end
        end,
        notify = function() end,
        is_closing = function()
          return false
        end,
        terminate = function() end,
      }
    end,
    root_dir = vim.fn.getcwd(),
  }
end

---Start the LSP server for a buffer
---@param bufnr integer
---@return integer? client_id
function M.start(bufnr)
  local config = M.create_config()
  return vim.lsp.start(config, { bufnr = bufnr, silent = false })
end

return M
