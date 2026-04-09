local core = require('opencode.core')
---@type OpencodeState
local state = require('opencode.state')
local session_store = require('opencode.session')
local Promise = require('opencode.promise')
local window_actions = require('opencode.commands.handlers.window').actions

local M = {
  actions = {},
}

local session_subcommands = { 'new', 'select', 'child', 'compact', 'share', 'unshare', 'agents_init', 'rename' }

---@param message string
local function invalid_arguments(message)
  error({
    code = 'invalid_arguments',
    message = message,
  }, 0)
end

---@param warning string
---@param callback fun(state_obj: OpencodeState): any
---@return any
local function with_active_session(warning, callback)
  local state_obj = state
  if not state_obj.active_session then
    vim.notify(warning, vim.log.levels.WARN)
    return
  end
  return callback(state_obj)
end

---@param promise Promise<any>
---@param success_cb fun(response: any)|nil
---@param error_prefix string
local function notify_promise(promise, success_cb, error_prefix)
  promise
    :and_then(function(response)
      if not success_cb then
        return
      end

      vim.schedule(function()
        success_cb(response)
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify(error_prefix .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

local function schedule_checktime()
  vim.schedule(function()
    vim.cmd('checktime')
  end)
end

---@param prefix string
---@param err any
local function notify_error(prefix, err)
  vim.schedule(function()
    vim.notify(prefix .. vim.inspect(err), vim.log.levels.ERROR)
  end)
end

---@param request_promise Promise<any>
---@param error_prefix string
local function run_api_action_with_checktime(request_promise, error_prefix)
  request_promise
    :and_then(schedule_checktime)
    :catch(function(err)
      notify_error(error_prefix, err)
    end)
end

function M.actions.open_input_new_session()
  return core.open({ new_session = true, focus = 'input', start_insert = true })
end

---@param title string
function M.actions.open_input_new_session_with_title(title)
  return Promise.async(function(session_title)
    local new_session = core.create_new_session(session_title):await()
    if not new_session then
      vim.notify('Failed to create new session', vim.log.levels.ERROR)
      return
    end

    state.session.set_active(new_session)
    return window_actions.open_input()
  end)(title)
end

---@param parent_id? string
function M.actions.select_session(parent_id)
  core.select_session(parent_id)
end

function M.actions.select_child_session()
  local active = state.active_session
  core.select_session(active and active.id or nil)
end

---@param current_session? Session
function M.actions.compact_session(current_session)
  local state_obj = state
  current_session = current_session or state_obj.active_session
  if not current_session then
    vim.notify('No active session to compact', vim.log.levels.WARN)
    return
  end

  local current_model = state_obj.current_model
  if not current_model then
    vim.notify('No model selected', vim.log.levels.ERROR)
    return
  end

  local providerId, modelId = current_model:match('^(.-)/(.+)$')
  if not providerId or not modelId then
    vim.notify('Invalid model format: ' .. tostring(current_model), vim.log.levels.ERROR)
    return
  end

  notify_promise(
    state_obj.api_client:summarize_session(current_session.id, {
      providerID = providerId,
      modelID = modelId,
    }),
    function()
      vim.notify('Session compacted successfully', vim.log.levels.INFO)
    end,
    'Failed to compact session: '
  )
end

function M.actions.share()
  return with_active_session('No active session to share', function(state_obj)
    notify_promise(state_obj.api_client:share_session(state_obj.active_session.id), function(response)
      if response and response.share and response.share.url then
        vim.fn.setreg('+', response.share.url)
        vim.notify('Session link copied to clipboard successfully: ' .. response.share.url, vim.log.levels.INFO)
        return
      end
      vim.notify('Session shared but no link received', vim.log.levels.WARN)
    end, 'Failed to share session: ')
  end)
end

function M.actions.unshare()
  return with_active_session('No active session to unshare', function(state_obj)
    notify_promise(state_obj.api_client:unshare_session(state_obj.active_session.id), function()
      vim.notify('Session unshared successfully', vim.log.levels.INFO)
    end, 'Failed to unshare session: ')
  end)
end

function M.actions.initialize()
  return Promise.async(function()
    local id = require('opencode.id')
    local state_obj = state
    local core_obj = core

    local new_session = core_obj.create_new_session('AGENTS.md Initialization'):await()
    if not new_session then
      vim.notify('Failed to create new session', vim.log.levels.ERROR)
      return
    end

    if not core_obj.initialize_current_model():await() or not state_obj.current_model then
      vim.notify('No model selected', vim.log.levels.ERROR)
      return
    end

    local providerId, modelId = state_obj.current_model:match('^(.-)/(.+)$')
    if not providerId or not modelId then
      vim.notify('Invalid model format: ' .. tostring(state_obj.current_model), vim.log.levels.ERROR)
      return
    end

    state_obj.session.set_active(new_session)
    window_actions.open_input()
    state_obj.api_client:init_session(state_obj.active_session.id, {
      providerID = providerId,
      modelID = modelId,
      messageID = id.ascending('message'),
    })
  end)()
end

---@param current_session? Session
---@param new_title? string
function M.actions.rename_session(current_session, new_title)
  return Promise.async(function(session_obj, requested_title)
    local promise = Promise.new()
    local state_obj = state
    session_obj = session_obj or (state_obj.active_session and vim.deepcopy(state_obj.active_session) or nil) --[[@as Session]]
    if not session_obj then
      vim.notify('No active session to rename', vim.log.levels.WARN)
      promise:resolve(nil)
      return promise
    end

    local function rename_session_with_title(title)
      state_obj.api_client
        :update_session(session_obj.id, { title = title })
        :catch(function(err)
          vim.schedule(function()
            vim.notify('Failed to rename session: ' .. vim.inspect(err), vim.log.levels.ERROR)
          end)
        end)
        :and_then(Promise.async(function()
          session_obj.title = title
          if state_obj.active_session and state_obj.active_session.id == session_obj.id then
            local persisted_session = session_store.get_by_id(session_obj.id):await()
            if persisted_session then
              persisted_session.title = title
              state_obj.session.set_active(vim.deepcopy(persisted_session))
            end
          end
          promise:resolve(session_obj)
        end))
    end

    if requested_title and requested_title ~= '' then
      rename_session_with_title(requested_title)
      return promise
    end

    vim.schedule(function()
      vim.ui.input({ prompt = 'New session name: ', default = session_obj.title or '' }, function(input)
        if input and input ~= '' then
          rename_session_with_title(input)
        else
          promise:resolve(nil)
        end
      end)
    end)

    return promise
  end)(current_session, new_title)
end

---@param messageId? string
function M.actions.undo(messageId)
  return with_active_session('No active session to undo', function(state_obj)
    local message_to_revert = messageId or (state_obj.last_user_message and state_obj.last_user_message.info.id)
    if not message_to_revert then
      vim.notify('No user message to undo', vim.log.levels.WARN)
      return
    end

    run_api_action_with_checktime(
      state_obj.api_client:revert_message(state_obj.active_session.id, {
        messageID = message_to_revert,
      }),
      'Failed to undo last message: '
    )
  end)
end

---@param state_obj OpencodeState
---@return string|nil
local function find_next_message_for_redo(state_obj)
  -- Redo anchor: find the revert timestamp first, then pick the first user message after that point.
  -- If no later user message exists, caller falls back to unrevert_messages.
  local active_session = state_obj.active_session
  if not active_session then
    return nil
  end

  local revert_time = 0
  local revert = active_session.revert
  if not revert then
    return nil
  end

  for _, message in ipairs(state_obj.messages or {}) do
    if message.info.id == revert.messageID then
      revert_time = math.floor(message.info.time.created)
      break
    end
    if revert.partID and revert.partID ~= '' then
      for _, part in ipairs(message.parts) do
        if part.id == revert.partID and part.state and part.state.time then
          revert_time = math.floor(part.state.time.start)
          break
        end
      end
    end
  end

  for _, msg in ipairs(state_obj.messages or {}) do
    if msg.info.role == 'user' and msg.info.time.created > revert_time then
      return msg.info.id
    end
  end

  return nil
end

function M.actions.redo()
  return with_active_session('No active session to redo', function(state_obj)
    local active_session = state_obj.active_session
    if not active_session.revert or active_session.revert.messageID == '' then
      vim.notify('Nothing to redo', vim.log.levels.WARN)
      return
    end

    if not state_obj.messages then
      return
    end

    local next_message_id = find_next_message_for_redo(state_obj)
    if not next_message_id then
      run_api_action_with_checktime(state_obj.api_client:unrevert_messages(active_session.id), 'Failed to redo message: ')
      return
    end

    run_api_action_with_checktime(
      state_obj.api_client:revert_message(active_session.id, {
        messageID = next_message_id,
      }),
      'Failed to redo message: '
    )
  end)
end

function M.actions.timeline()
  local user_messages = {}
  for _, msg in ipairs(state.messages or {}) do
    local parts = msg.parts or {}
    local is_summary = #parts == 1 and parts[1].synthetic == true
    if msg.info.role == 'user' and not is_summary then
      table.insert(user_messages, msg)
    end
  end

  if #user_messages == 0 then
    vim.notify('No user messages in the current session', vim.log.levels.WARN)
    return
  end

  local timeline_picker = require('opencode.ui.timeline_picker')
  timeline_picker.pick(user_messages, function(selected_msg)
    if selected_msg then
      require('opencode.ui.navigation').goto_message_by_id(selected_msg.info.id)
    end
  end)
end

---@param message_id? string
function M.actions.fork_session(message_id)
  return with_active_session('No active session to fork', function(state_obj)
    local message_to_fork = message_id or state_obj.last_user_message and state_obj.last_user_message.info.id
    if not message_to_fork then
      vim.notify('No user message to fork from', vim.log.levels.WARN)
      return
    end

    state_obj.api_client
      :fork_session(state_obj.active_session.id, {
        messageID = message_to_fork,
      })
      :and_then(function(response)
        vim.schedule(function()
          if response and response.id then
            vim.notify('Session forked successfully. New session ID: ' .. response.id, vim.log.levels.INFO)
            core.switch_session(response.id)
          else
            vim.notify('Session forked but no new session ID received', vim.log.levels.WARN)
          end
        end)
      end)
      :catch(function(err)
        notify_error('Failed to fork session: ', err)
      end)
  end)
end

---@param args string[]
---@param start_idx integer
---@return string|nil
local function parse_title(args, start_idx)
  local title = table.concat(vim.list_slice(args, start_idx), ' ')
  if title == '' then
    return nil
  end

  return title
end

---@type table<string, fun(args: string[]): any>
local session_subcommand_actions = {
  new = function(args)
    local title = parse_title(args, 2)
    if title then
      return M.actions.open_input_new_session_with_title(title)
    end
    return M.actions.open_input_new_session()
  end,
  rename = function(args)
    return M.actions.rename_session(nil, parse_title(args, 2))
  end,
  select = function()
    return M.actions.select_session()
  end,
  child = function()
    return M.actions.select_child_session()
  end,
  compact = function()
    return M.actions.compact_session()
  end,
  share = function()
    return M.actions.share()
  end,
  unshare = function()
    return M.actions.unshare()
  end,
  agents_init = function()
    return M.actions.initialize()
  end,
}

M.command_defs = {
  session = {
    desc = 'Manage sessions (new/select/child/compact/share/unshare/rename)',
    completions = session_subcommands,
    nested_subcommand = { allow_empty = false },
    execute = function(args)
      local subcommand = args[1]
      local action = session_subcommand_actions[subcommand]
      if not action then
        invalid_arguments('Invalid session subcommand. Use: ' .. table.concat(session_subcommands, ', '))
      end
      return action(args)
    end,
  },
  -- action name aliases for keymap compatibility
  open_input_new_session = { desc = 'Open input (new session)', execute = M.actions.open_input_new_session },
  select_session         = { desc = 'Select session',           execute = M.actions.select_session },
  select_child_session   = { desc = 'Select child session',     execute = M.actions.select_child_session },
  rename_session         = { desc = 'Rename session',           execute = function(args) return M.actions.rename_session(nil, args[1]) end },
  undo = {
    desc = 'Undo last action',
    execute = function(args)
      return M.actions.undo(args[1])
    end,
  },
  redo = {
    desc = 'Redo last action',
    execute = M.actions.redo,
  },
  timeline = {
    desc = 'Open timeline picker to navigate/undo/redo/fork to message',
    execute = M.actions.timeline,
  },
}

return M
