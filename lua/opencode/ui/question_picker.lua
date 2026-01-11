-- Question picker UI for handling question tool requests
local state = require('opencode.state')
local icons = require('opencode.ui.icons')

local M = {}

-- Track current question being displayed
M.current_question = nil

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

  -- Show the full question as a notification so user can see it without truncation
  local question_icon = icons.get('question') or '?'
  local progress = #questions > 1 and string.format(' (%d/%d)', index, #questions) or ''
  vim.notify(question_icon .. ' ' .. q.question, vim.log.levels.INFO, { title = 'OpenCode Question' })

  -- Use the short header as the prompt (won't get cut off)
  local prompt = q.header .. progress .. ': '

  if q.multiple then
    M._show_multiselect(request, index, collected_answers, q, items, prompt)
  else
    M._show_single_select(request, index, collected_answers, q, items, prompt)
  end
end

--- Show single-select picker
--- @param request OpencodeQuestionRequest
--- @param index number
--- @param collected_answers string[][]
--- @param q OpencodeQuestionInfo
--- @param items table[]
--- @param prompt string
function M._show_single_select(request, index, collected_answers, q, items, prompt)
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
      -- User cancelled - reject the question
      M._send_reject(request.id)
      return
    end

    if choice.is_other then
      -- Get custom input
      vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
        if input and input ~= '' then
          table.insert(collected_answers, { input })
          M._show_question(request, index + 1, collected_answers)
        else
          M._send_reject(request.id)
        end
      end)
    else
      -- Reply with selected option
      table.insert(collected_answers, { choice.label })
      M._show_question(request, index + 1, collected_answers)
    end
  end)
end

--- Show multi-select picker using checkboxes
--- @param request OpencodeQuestionRequest
--- @param index number
--- @param collected_answers string[][]
--- @param q OpencodeQuestionInfo
--- @param items table[]
--- @param prompt string
function M._show_multiselect(request, index, collected_answers, q, items, prompt)
  -- For multiselect, we use a simple approach: show items with instructions
  -- User can select multiple by choosing "Done" when finished
  local selected = {}

  local function show_picker()
    local display_items = {}

    for _, item in ipairs(items) do
      if not item.is_other then
        local prefix = selected[item.label] and '[x] ' or '[ ] '
        table.insert(display_items, {
          label = item.label,
          description = item.description,
          display = prefix .. item.label,
          is_other = false,
        })
      end
    end

    -- Add done and other options
    table.insert(display_items, {
      label = '-- Done --',
      description = 'Confirm selection',
      display = '-- Done --',
      is_done = true,
    })
    table.insert(display_items, {
      label = 'Other',
      description = 'Provide custom response',
      display = 'Other',
      is_other = true,
    })

    vim.ui.select(display_items, {
      prompt = prompt .. '(multi): ',
      format_item = function(item)
        if item.description and item.description ~= '' and not item.is_done then
          return item.display .. ' - ' .. item.description
        end
        return item.display
      end,
    }, function(choice)
      if not choice then
        M._send_reject(request.id)
        return
      end

      if choice.is_done then
        -- Collect selected items
        local answers = {}
        for label, _ in pairs(selected) do
          table.insert(answers, label)
        end
        if #answers == 0 then
          vim.notify('Please select at least one option', vim.log.levels.WARN)
          show_picker()
          return
        end
        table.insert(collected_answers, answers)
        M._show_question(request, index + 1, collected_answers)
      elseif choice.is_other then
        vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
          if input and input ~= '' then
            table.insert(collected_answers, { input })
            M._show_question(request, index + 1, collected_answers)
          else
            show_picker()
          end
        end)
      else
        -- Toggle selection
        if selected[choice.label] then
          selected[choice.label] = nil
        else
          selected[choice.label] = true
        end
        show_picker()
      end
    end)
  end

  show_picker()
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
