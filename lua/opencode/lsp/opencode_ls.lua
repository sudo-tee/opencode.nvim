---In-process LSP server for opencode completion
---Provides completion for files, subagents, commands, and context items
---Works with any LSP-compatible completion plugin (blink.cmp, nvim-cmp, etc.)

local M = {}
---@type table<vim.lsp.protocol.Method, fun(params: table, callback:fun(err: lsp.ResponseError?, result: any))>
local handlers = {}
local ms = vim.lsp.protocol.Methods

---Parse trigger characters from all registered completion sources
---@return string[]
local function get_trigger_characters()
  local chars = {}
  local config = require('opencode.config')

  -- Get trigger characters from keymaps
  local triggers = {
    config.get_key_for_function('input_window', 'mention'), -- @ for subagents
    config.get_key_for_function('input_window', 'slash_commands'), -- / for commands
    config.get_key_for_function('input_window', 'context_items'), -- # for context
  }

  for _, trigger in ipairs(triggers) do
    if trigger and not vim.tbl_contains(chars, trigger) then
      table.insert(chars, trigger)
    end
  end

  return chars
end

---Initialize handler - negotiates capabilities with the client
---@param params lsp.InitializeParams
---@param callback fun(err?: lsp.ResponseError, result: lsp.InitializeResult)
handlers[ms.initialize] = function(params, callback)
  local trigger_chars = get_trigger_characters()

  callback(nil, {
    capabilities = {
      completionProvider = {
        resolveProvider = true,
        triggerCharacters = trigger_chars,
      },
    },
    serverInfo = {
      name = 'opencode_ls',
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
  local bufnr = vim.api.nvim_get_current_buf()
  local line_num = params.position.line + 1 -- LSP is 0-indexed
  local col = params.position.character

  local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
  local line = lines[1] or ''
  local line_to_cursor = line:sub(1, col)

  -- Find the trigger character
  local trigger_char = ''
  local config = require('opencode.config')
  local triggers = {
    config.get_key_for_function('input_window', 'mention'),
    config.get_key_for_function('input_window', 'slash_commands'),
    config.get_key_for_function('input_window', 'context_items'),
  }

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

---Convert opencode CompletionItem to LSP CompletionItem
---@param item CompletionItem
---@param index integer
---@return lsp.CompletionItem
local function to_lsp_item(item, index)
  -- Map opencode kinds to LSP kinds
  local kind_map = {
    file = vim.lsp.protocol.CompletionItemKind.File,
    subagent = vim.lsp.protocol.CompletionItemKind.Class,
    command = vim.lsp.protocol.CompletionItemKind.Function,
    context = vim.lsp.protocol.CompletionItemKind.Variable,
  }
  local source = require('opencode.ui.completion').get_source_by_name(item.source_name)

  local lsp_item = {
    label = item.kind_icon .. item.label,
    kind = 0,
    kind_icon = '',
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
---@param callback fun(err?: lsp.ResponseError, result: lsp.CompletionItem[])
handlers[ms.textDocument_completion] = function(params, callback)
  local word, trigger_char, line = get_completion_context(params)

  -- Build completion context
  local completion_context = {
    input = word,
    trigger_char = trigger_char,
    line = line,
  }

  -- Get all registered sources
  local completion = require('opencode.ui.completion')
  local sources = completion.get_sources()

  -- Collect promises from all sources
  local Promise = require('opencode.promise')
  local promises = {}

  for _, source in ipairs(sources) do
    if source.complete then
      table.insert(promises, source.complete(completion_context))
    end
  end

  -- Wait for all sources to complete in parallel
  Promise.all(promises)
    :and_then(function(results)
      local all_items = {}

      -- Flatten results from all sources
      for i, items in ipairs(results) do
        if type(items) == 'table' then
          for _, item in ipairs(items) do
            table.insert(all_items, to_lsp_item(item, i))
          end
        end
      end

      callback(nil, all_items)
      completion.store_completion_items(all_items)
    end)
    :catch(function(err)
      vim.notify('Opencode LSP completion error: ' .. tostring(err), vim.log.levels.ERROR)
      callback(nil, {})
    end)
end

---Resolve handler - provides additional documentation for completion items
---@param params lsp.CompletionItem
---@param callback fun(err?: lsp.ResponseError, result: lsp.CompletionItem)
handlers[ms.completionItem_resolve] = function(params, callback)
  local item = vim.deepcopy(params)

  -- Additional resolution can be done here if needed
  -- For now, documentation is already attached in textDocument_completion

  callback(nil, item)
end

---Create the LSP server configuration
---@return vim.lsp.ClientConfig
function M.create_config()
  return {
    name = 'opencode_ls',
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

---Hook into completion item selection to trigger on_complete callbacks
---This is called when a completion item is confirmed/selected
---@param item lsp.CompletionItem
function M.on_completion_done(item)
  if not item or not item.data or not item.data._opencode_item then
    return
  end

  local completion = require('opencode.ui.completion')
  local original_item = item.data._opencode_item

  -- Call the source's on_complete callback
  completion.on_complete(original_item)
end

return M
