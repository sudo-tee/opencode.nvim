---In-process LSP server for opencode completion
---Provides completion for files, subagents, commands, and context items
---Works with any LSP-compatible completion plugin (blink.cmp, nvim-cmp, etc.)
local M = { _completion_done_handled = false }

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
      executeCommandProvider = {
        commands = { 'opencode.completion_done' },
      },
    },
    serverInfo = {
      name = 'opencode_ls',
      version = '1.0.0',
    },
  })
end

handlers[ms.workspace_executeCommand] = function(params, callback)
  if params.command == 'opencode.completion_done' then
    if M._completion_done_handled then
      callback(nil, nil)
      M._completion_done_handled = false
      return
    end
    local item = params.arguments and params.arguments[1]
    if item then
      require('opencode.ui.completion').on_completion_done(item)
    end
    callback(nil, nil)
  else
    callback({
      code = -32601,
      message = 'Method not found: ' .. tostring(params.command),
    }, nil)
  end
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

  local trigger_char = ''
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

function M.supports_kind_icons()
  return require('opencode.ui.completion').supports_kind_icons()
end

---Convert opencode CompletionItem to LSP CompletionItem
---@param item CompletionItem
---@param index integer
---@return OpencodeLspItem
local function to_lsp_item(item, index, params)
  local source = require('opencode.ui.completion').get_source_by_name(item.source_name)
  local kind = (source and source.custom_kind) or vim.lsp.protocol.CompletionItemKind.Function ---@type lsp.CompletionItemKind
  local priority = source and source.priority or 999
  local line = params.position.line
  local col = params.position.character

  ---@type OpencodeLspItem
  local lsp_item = {
    label = (M.supports_kind_icons() and '' or item.kind_icon .. ' ') .. item.label,
    kind = kind,
    kind_hl = item.kind_hl,
    kind_icon = M.supports_kind_icons() and item.kind_icon or '',
    detail = item.detail,
    documentation = item.documentation and {
      kind = 'plaintext',
      value = item.documentation,
    } or nil,
    insertText = item.insert_text and item.insert_text ~= '' and item.insert_text or item.label,
    filterText = item.label,
    sortText = string.format('%02d_%02d_%02d_%s', priority, item.priority or 999, index, item.label),
    textEdit = {
      range = {
        start = { line = line, character = col },
        ['end'] = { line = line, character = col },
      },
      newText = item.insert_text,
    },
    command = {
      title = 'opencode.completion_done',
      command = 'opencode.completion_done',
      arguments = { item },
    },
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
  ---@type CompletionContext
  local completion_context = {
    input = word,
    trigger_char = trigger_char,
    line = line,
    cursor_pos = params.position.character,
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
      ---@type OpencodeLspItem[]
      local all_items = {}
      local is_incomplete = false

      for _, items in ipairs(results) do
        for j, item in ipairs(items or {}) do
          local source = completion.get_source_by_name(item.source_name)
          if source and source.is_incomplete then
            is_incomplete = true
          end

          table.insert(all_items, to_lsp_item(item, j, params))
        end
      end

      callback(nil, { isIncomplete = is_incomplete, items = all_items })
    end)
    :catch(function(err)
      local log = require('opencode.log')
      log.error('Error in completion handler: ' .. tostring(err))
      callback(nil, { isIncomplete = false, items = {} })
    end)
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
            return
          end
          -- Ensure every request receives a response to avoid hanging the client.
          -- Use JSON-RPC "MethodNotFound" error code (-32601).
          callback({
            code = -32601,
            message = 'Method not found: ' .. tostring(method),
          }, nil)
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
  local augroup = vim.api.nvim_create_augroup('OpencodeLspCompletion_' .. bufnr, { clear = true })

  -- Handle completion done to trigger the action, some completion plugins do not trigger the command callback, so we use this as a fallback
  vim.api.nvim_create_autocmd('CompleteDonePre', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M._completion_done_handled = true
      local completed_item = vim.v.completed_item
      if completed_item and completed_item.user_data then
        local data = vim.tbl_get(completed_item, 'user_data', 'nvim', 'lsp', 'completion_item', 'data')
          or vim.tbl_get(completed_item, 'user_data', 'lsp', 'item', 'data')

        local item = data and data._opencode_item

        if item then
          require('opencode.ui.completion').on_completion_done(item)
        end
      end
    end,
  })
  return vim.lsp.start(config, { bufnr = bufnr, silent = false })
end

return M
