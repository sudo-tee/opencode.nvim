-- Question picker UI for handling question tool requests
local state = require('opencode.state')
local icons = require('opencode.ui.icons')
local base_picker = require('opencode.ui.base_picker')
local config = require('opencode.config')

local M = {}

-- Track current question being displayed
M.current_question = nil

--- Format a question option for the picker
---@param item table Question option item
---@param width? number Optional width
---@return PickerItem
local function format_option(item, width)
  local text = item.label
  if item.description and item.description ~= '' then
    text = text .. ' - ' .. item.description
  end
  return base_picker.create_picker_item(text, nil, nil, width)
end

--- Show a question picker for the user to answer
--- @param question OpencodeQuestionRequest
function M.show(question)
  if not question or not question.questions or #question.questions == 0 then
    return
  end

  M.current_question = question

  -- Process questions sequentially
  M._show_question(question, 1, {})
end

--- Show a single question from the request
--- @param request OpencodeQuestionRequest
--- @param index number Current question index (1-based)
--- @param collected_answers string[][] Answers collected so far
function M._show_question(request, index, collected_answers)
  local questions = request.questions
  if index > #questions then
    -- All questions answered, send reply
    M._send_reply(request.id, collected_answers)
    return
  end

  local q = questions[index]
  local items = {}

  for _, opt in ipairs(q.options or {}) do
    table.insert(items, {
      label = opt.label,
      description = opt.description or '',
    })
  end

  -- Add "Other" option for custom input
  table.insert(items, {
    label = 'Other',
    description = 'Provide custom response',
    is_other = true,
  })

  -- Build title with question
  local question_icon = icons.get('question') or '?'
  local progress = #questions > 1 and string.format(' (%d/%d)', index, #questions) or ''
  local title = question_icon .. ' ' .. q.header .. progress

  -- Define actions
  local actions = {}

  if q.multiple then
    -- For multi-select, add a confirm action that collects all selections
    actions.confirm_multi = {
      key = { '<CR>', mode = { 'i', 'n' } },
      label = 'confirm',
      multi_selection = true,
      fn = function(selected, opts)
        -- Handle the selection
        local selections = type(selected) == 'table' and selected.label == nil and selected or { selected }

        -- Check for "Other" option
        local has_other = false
        local answers = {}
        for _, item in ipairs(selections) do
          if item.is_other then
            has_other = true
          else
            table.insert(answers, item.label)
          end
        end

        if has_other and #answers == 0 then
          -- Only "Other" selected, prompt for input
          vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
            if input and input ~= '' then
              table.insert(collected_answers, { input })
              M._show_question(request, index + 1, collected_answers)
            else
              M._send_reject(request.id)
            end
          end)
        elseif #answers > 0 then
          table.insert(collected_answers, answers)
          M._show_question(request, index + 1, collected_answers)
        else
          vim.notify('Please select at least one option', vim.log.levels.WARN)
        end

        return nil -- Don't reload
      end,
    }
  end

  -- Show full question as notification for context
  vim.notify(question_icon .. ' ' .. q.question, vim.log.levels.INFO, { title = 'OpenCode Question' })

  -- Use base_picker
  local success = base_picker.pick({
    items = items,
    format_fn = format_option,
    title = title,
    actions = actions,
    width = config.ui.picker_width or 80,
    callback = function(selected)
      if not selected then
        -- User cancelled
        M._send_reject(request.id)
        return
      end

      -- For single-select (no multi action defined), handle here
      if not q.multiple then
        if selected.is_other then
          vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
            if input and input ~= '' then
              table.insert(collected_answers, { input })
              M._show_question(request, index + 1, collected_answers)
            else
              M._send_reject(request.id)
            end
          end)
        else
          table.insert(collected_answers, { selected.label })
          M._show_question(request, index + 1, collected_answers)
        end
      end
      -- Multi-select is handled by the confirm_multi action
    end,
  })

  -- Fallback to vim.ui.select if no picker available
  if not success then
    M._fallback_picker(request, index, collected_answers, q, items)
  end
end

--- Fallback to vim.ui.select when no picker is available
--- @param request OpencodeQuestionRequest
--- @param index number
--- @param collected_answers string[][]
--- @param q OpencodeQuestionInfo
--- @param items table[]
function M._fallback_picker(request, index, collected_answers, q, items)
  local question_icon = icons.get('question') or '?'
  local progress = #request.questions > 1 and string.format(' (%d/%d)', index, #request.questions) or ''
  local prompt = q.header .. progress .. ': '

  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      if item.description and item.description ~= '' then
        return item.label .. ' - ' .. item.description
      end
      return item.label
    end,
  }, function(choice)
    if not choice then
      M._send_reject(request.id)
      return
    end

    if choice.is_other then
      vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
        if input and input ~= '' then
          table.insert(collected_answers, { input })
          M._show_question(request, index + 1, collected_answers)
        else
          M._send_reject(request.id)
        end
      end)
    else
      table.insert(collected_answers, { choice.label })
      M._show_question(request, index + 1, collected_answers)
    end
  end)
end

--- Send reply to the question
--- @param request_id string
--- @param answers string[][]
function M._send_reply(request_id, answers)
  M.current_question = nil
  if state.api_client then
    state.api_client:reply_question(request_id, answers):catch(function(err)
      vim.notify('Failed to reply to question: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
  end
end

--- Send reject to the question
--- @param request_id string
function M._send_reject(request_id)
  M.current_question = nil
  if state.api_client then
    state.api_client:reject_question(request_id):catch(function(err)
      vim.notify('Failed to reject question: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
  end
end

--- Check if there's a pending question for the given session
--- @param session_id string
--- @return boolean
function M.has_pending_question(session_id)
  return M.current_question ~= nil and M.current_question.sessionID == session_id
end

return M
