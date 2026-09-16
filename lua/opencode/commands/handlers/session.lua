---@type OpencodeState
local state = require('opencode.state')
local Promise = require('opencode.promise')
local util = require('opencode.util')
local window_actions = require('opencode.commands.handlers.window').actions
local session_runtime = require('opencode.services.session_runtime')
local agent_model = require('opencode.services.agent_model')

local M = {
  actions = {},
}

local session_subcommands = {
  'new',
  'tab',
  'tabs',
  'next_tab',
  'prev_tab',
  'close_tab',
  'select',
  'navigate',
  'compact',
  'share',
  'unshare',
  'agents_init',
  'rename',
  'toggle_lock',
}

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
  local connection = state_obj.opencode_server
  local observation = state_obj.session.active_observation()
  if not state_obj.active_session or not connection or not connection:is_ready() or not observation then
    vim.notify(warning, vim.log.levels.WARN)
    return
  end
  local session_fact = observation:read().session
  if type(session_fact) ~= 'table' or type(session_fact.id) ~= 'string' then
    error('Active Observation has no session fact')
  end
  local location = session_fact.location or state_obj.active_session.location
    or { directory = state_obj.current_cwd or vim.fn.getcwd() }
  return callback(state_obj, observation, session_fact, connection, location)
end

local function active_session_fact()
  local observation = state.session.active_observation()
  return observation and observation:read().session or nil
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
---@param on_success? fun(...)
local function run_api_action_with_checktime(request_promise, error_prefix, on_success)
  request_promise
    :and_then(function(...)
      schedule_checktime()
      if on_success then
        on_success(...)
      end
    end)
    :catch(function(err)
      notify_error(error_prefix, err)
    end)
end

function M.actions.open_input_new_session()
  return session_runtime.open({ new_session = true, focus = 'input', start_insert = true })
end

---@param title string
function M.actions.open_input_new_session_with_title(title)
  return Promise.async(function(session_title)
    local new_session = session_runtime.create_new_session(session_title):await()
    if not new_session then
      vim.notify('Failed to create new session', vim.log.levels.ERROR)
      return
    end

    state.session.set_active(new_session)
    return window_actions.open_input()
  end)(title)
end

---@param title? string
function M.actions.open_session_tab(title)
  return session_runtime.open_session_tab(title)
end

---@param index? string|number
function M.actions.select_session_tab(index)
  if index ~= nil then
    return session_runtime.switch_session_tab_by_index(index)
  end
  return require('opencode.ui.session_tab_picker').select()
end

function M.actions.next_session_tab()
  return session_runtime.cycle_session_tab(1)
end

function M.actions.prev_session_tab()
  return session_runtime.cycle_session_tab(-1)
end

function M.actions.close_session_tab()
  return session_runtime.close_session_tab()
end

---@param parent_id? string
---@param scope? 'project' | 'global' defaults to global when session is locked, project otherwise
function M.actions.select_session(parent_id, scope)
  if scope == nil then
    scope = session_runtime.is_session_locked() and 'global' or 'project'
  end
  session_runtime.select_session(parent_id, scope)
end

---@param value? boolean if nil toggle, otherwise set to value
function M.actions.toggle_session_lock(value)
  local new_value
  if value == nil then
    new_value = session_runtime.toggle_session_lock()
  else
    new_value = session_runtime.set_session_lock(value and true or false)
  end
  vim.notify(
    'Session lock ' .. (new_value and 'enabled (session preserved across cwd changes)' or 'disabled'),
    vim.log.levels.INFO
  )
  return new_value
end

local NAV_DIRECTIONS = { parent = true, child = true, sibling = true, forward = true, backward = true }
local NAV_INTERACTION_DEFAULTS =
  { parent = 'direct', child = 'picker', sibling = 'picker', forward = 'direct', backward = 'direct' }

---@return string direction, string interaction, boolean wrap, string empty_policy
---@diagnostic disable-next-line: missing-return-value
local function normalize_navigate_args(direction, interaction, wrap, empty_policy)
  if not NAV_DIRECTIONS[direction] then
    invalid_arguments('Invalid direction: ' .. tostring(direction))
  end

  interaction = interaction or NAV_INTERACTION_DEFAULTS[direction]
  if interaction ~= 'direct' and interaction ~= 'picker' then
    invalid_arguments('Invalid interaction: ' .. tostring(interaction))
  end

  if wrap == nil then
    wrap = false
  end
  if type(wrap) == 'string' then
    local coerced = ({ ['true'] = true, ['false'] = false })[wrap]
    if coerced == nil then
      invalid_arguments('Invalid wrap: ' .. tostring(wrap))
    end
    wrap = coerced
  elseif type(wrap) ~= 'boolean' then
    invalid_arguments('Invalid wrap: ' .. tostring(wrap))
  end

  empty_policy = empty_policy or 'notify'
  if empty_policy ~= 'notify' and empty_policy ~= 'noop' then
    invalid_arguments('Invalid empty_policy: ' .. tostring(empty_policy))
  end

  return direction, interaction, wrap, empty_policy
end

-- parent: direct switch to parentID; child/sibling: target_id is filter, always picker
local tree_directions = {
  parent = {
    get_target = function(a)
      return a.parentID
    end,
    allow_direct = true,
  },
  child = {
    get_target = function(a)
      return a.id
    end,
    allow_direct = false,
  },
  sibling = {
    get_target = function(a)
      return a.parentID
    end,
    allow_direct = false,
  },
}

local function find_session_index(sessions, session_id)
  for i, s in ipairs(sessions) do
    if s.id == session_id then
      return i
    end
  end
  return nil
end

local function compute_target_index(current_idx, total, direction, wrap)
  local step = direction == 'forward' and -1 or 1
  local target = current_idx + step

  if target >= 1 and target <= total then
    return target
  end
  if wrap then
    return direction == 'forward' and total or 1
  end
  return nil
end

function M.actions.navigate_session_tree(direction, interaction, wrap, empty_policy)
  if direction and not tree_directions[direction] and direction ~= 'forward' and direction ~= 'backward' then
    empty_policy = empty_policy or 'notify'
    if not state.active_session then
      if empty_policy == 'notify' then
        vim.notify('No active session to navigate from', vim.log.levels.WARN)
      end
      return
    end
    if interaction == 'tab' then
      return session_runtime.open_session_in_tab_by_id(direction)
    end
    if interaction == 'picker' then
      return session_runtime.select_session(direction, 'project')
    end
    return session_runtime.switch_session(direction)
  end

  local active = active_session_fact()
  if not active then
    if empty_policy == 'notify' then
      vim.notify('No active session', vim.log.levels.WARN)
    end
    return
  end

  local dir = tree_directions[direction]
  if dir then
    local target_id = dir.get_target(active)
    if not target_id then
      if direction == 'sibling' then
        return session_runtime.select_session(nil, 'project')
      end
      if empty_policy == 'notify' then
        vim.notify('No ' .. direction, vim.log.levels.INFO)
      end
      return
    end
    if interaction == 'picker' or not dir.allow_direct then
      return session_runtime.select_session(target_id, 'project')
    end
    return session_runtime.switch_session(target_id)
  end

  -- forward / backward: flat navigation by time.updated
  return Promise.async(function()
    local all_sessions = Promise.wrap(session_runtime.list_sessions_by_scope('project')):await()
    if not all_sessions or #all_sessions == 0 then
      if empty_policy == 'notify' then
        vim.notify('No sessions', vim.log.levels.INFO)
      end
      return
    end

    local current_idx = find_session_index(all_sessions, active.id)
    if not current_idx then
      if empty_policy == 'notify' then
        vim.notify('Session not in list', vim.log.levels.INFO)
      end
      return
    end

    local target_idx = compute_target_index(current_idx, #all_sessions, direction, wrap)
    if not target_idx then
      if empty_policy == 'notify' then
        vim.notify('At ' .. (direction == 'forward' and 'newest' or 'oldest') .. ' session', vim.log.levels.INFO)
      end
      return
    end

    return session_runtime.switch_session(all_sessions[target_idx].id)
  end)()
end

---@param current_session? Session
function M.actions.compact_session(current_session)
  return with_active_session('No active session to compact', function(state_obj, _, active, connection, location)
    local target = current_session or active
    local current_model = state_obj.current_model
    if not current_model then
      vim.notify('No model selected', vim.log.levels.ERROR)
      return
    end

    local provider_id, model_id = current_model:match('^(.-)/(.+)$')
    if not provider_id or not model_id then
      vim.notify('Invalid model format: ' .. tostring(current_model), vim.log.levels.ERROR)
      return
    end

    notify_promise(
      connection.operations.summarize_session(connection, target.id, target.location or location, {
        providerID = provider_id,
        modelID = model_id,
      }, util.apply_path_map),
      function()
        vim.notify('Session compacted successfully', vim.log.levels.INFO)
      end,
      'Failed to compact session: '
    )
  end)
end

function M.actions.share()
  return with_active_session('No active session to share', function(_, _, session_fact, connection, location)
    notify_promise(connection.operations.share_session(
      connection,
      session_fact.id,
      location,
      util.apply_path_map,
      util.apply_reverse_path_map
    ), function(response)
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
  return with_active_session('No active session to unshare', function(_, _, session_fact, connection, location)
    notify_promise(connection.operations.unshare_session(
      connection,
      session_fact.id,
      location,
      util.apply_path_map,
      util.apply_reverse_path_map
    ), function()
      vim.notify('Session unshared successfully', vim.log.levels.INFO)
    end, 'Failed to unshare session: ')
  end)
end

function M.actions.initialize()
  return Promise.async(function()
    local id = require('opencode.id')
    local state_obj = state

    local new_session = session_runtime.create_new_session('AGENTS.md Initialization'):await()
    if not new_session then
      vim.notify('Failed to create new session', vim.log.levels.ERROR)
      return
    end

    if not agent_model.initialize_current_model():await() or not state_obj.current_model then
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
    local connection = state_obj.opencode_server
    connection.operations.init_session(connection, state_obj.active_session.id, state_obj.active_session.location or {
      directory = state_obj.current_cwd or vim.fn.getcwd(),
    }, {
      providerID = providerId,
      modelID = modelId,
      messageID = id.ascending('message'),
    }, util.apply_path_map)
  end)()
end

---@param current_session? Session
---@param new_title? string
function M.actions.rename_session(current_session, new_title)
  return Promise.async(function(session_obj, requested_title)
    local promise = Promise.new()
    local state_obj = state
    local connection = state_obj.opencode_server
    local active = active_session_fact()
    session_obj = session_obj or (active and vim.deepcopy(active) or nil) --[[@as Session]]
    if not session_obj then
      vim.notify('No active session to rename', vim.log.levels.WARN)
      promise:resolve(nil)
      return promise
    end
    if not connection or not connection:is_ready() then
      error('Connection is not ready')
    end

    local function rename_session_with_title(title)
      local location = session_obj.location or (state_obj.active_session and state_obj.active_session.location)
        or { directory = state_obj.current_cwd or vim.fn.getcwd() }
      connection.operations
        .rename_session(connection, session_obj.id, location, title, util.apply_path_map, util.apply_reverse_path_map)
        :catch(function(err)
          vim.schedule(function()
            vim.notify('Failed to rename session: ' .. vim.inspect(err), vim.log.levels.ERROR)
          end)
        end)
        :and_then(function()
          session_obj.title = title
          promise:resolve(session_obj)
        end)
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

local function find_entry(observation, target_id)
  return observation:read().entries_by_id[target_id]
end

local function entry_index(observation, target_id)
  for index, id in ipairs(observation:read().entry_order) do
    if id == target_id then
      return index
    end
  end
end

local function find_last_user_entry(observation, session_fact)
  local observed = observation:read()
  local stop = #observed.entry_order
  if session_fact.revert then
    local index = entry_index(observation, session_fact.revert.messageID)
    if not index then
      return nil
    end
    stop = index - 1
  end
  for index = stop, 1, -1 do
    local entry = observed.entries_by_id[observed.entry_order[index]]
    if entry and entry.kind == 'user' then
      return entry
    end
  end
end

---@param message_id? string
function M.actions.undo(message_id)
  return with_active_session('No active session to undo', function(_, observation, session_fact, connection, location)
    local target = message_id and find_entry(observation, message_id)
      or find_last_user_entry(observation, session_fact)
    if not target or target.kind ~= 'user' then
      vim.notify('No user message to undo', vim.log.levels.WARN)
      return
    end

    run_api_action_with_checktime(
      connection.operations.revert_message(
        connection,
        session_fact.id,
        location,
        { messageID = target.id },
        util.apply_path_map,
        util.apply_reverse_path_map
      ),
      'Failed to undo last message: ',
      function()
        require('opencode.ui.input_window').refill_prompt_from_message(target)
      end
    )
  end)
end

---@param message_id string
function M.actions.copy_message(message_id)
  return with_active_session('No active session to copy', function(_, observation)
    local target = find_entry(observation, message_id)
    if not target or target.kind ~= 'user' then
      vim.notify('No user message to copy', vim.log.levels.WARN)
      return
    end

    local text_parts = {}
    for _, part in ipairs(target.content or {}) do
      if
        part.kind == 'text'
        and part.synthetic ~= true
        and part.ignored ~= true
        and type(part.text) == 'string'
        and vim.trim(part.text) ~= ''
      then
        text_parts[#text_parts + 1] = part.text
      end
    end

    if #text_parts == 0 then
      vim.notify('No message text to copy', vim.log.levels.WARN)
      return
    end

    vim.fn.setreg('+', table.concat(text_parts, '\n\n'))
  end)
end

local function find_next_user_entry(observation, revert_message_id)
  local observed = observation:read()
  local index = entry_index(observation, revert_message_id)
  if not index then
    return nil, false
  end
  for next_index = index + 1, #observed.entry_order do
    local entry = observed.entries_by_id[observed.entry_order[next_index]]
    if entry and entry.kind == 'user' then
      return entry.id, true
    end
  end
  return nil, true
end

function M.actions.redo()
  return with_active_session('No active session to redo', function(_, observation, session_fact, connection, location)
    if not session_fact.revert or session_fact.revert.messageID == '' then
      vim.notify('Nothing to redo', vim.log.levels.WARN)
      return
    end

    local next_message_id, found_boundary = find_next_user_entry(observation, session_fact.revert.messageID)
    if not found_boundary then
      vim.notify('Redo boundary is not loaded', vim.log.levels.WARN)
      return
    end
    if not next_message_id then
      run_api_action_with_checktime(
        connection.operations.unrevert_messages(
          connection,
          session_fact.id,
          location,
          util.apply_path_map,
          util.apply_reverse_path_map
        ),
        'Failed to redo message: '
      )
      return
    end

    run_api_action_with_checktime(
      connection.operations.revert_message(
        connection,
        session_fact.id,
        location,
        { messageID = next_message_id },
        util.apply_path_map,
        util.apply_reverse_path_map
      ),
      'Failed to redo message: '
    )
  end)
end

function M.actions.timeline()
  local observation = state.session.active_observation()
  if not observation then
    vim.notify('No active session', vim.log.levels.WARN)
    return
  end
  local observed = observation:read()
  local user_entries = {}
  for _, id in ipairs(observed.entry_order) do
    local entry = observed.entries_by_id[id]
    local content = entry and entry.content or {}
    local is_summary = #content == 1 and content[1].synthetic == true
    if entry and entry.kind == 'user' and not is_summary then
      table.insert(user_entries, entry)
    end
  end

  if #user_entries == 0 then
    vim.notify('No user messages in the current session', vim.log.levels.WARN)
    return
  end

  local timeline_picker = require('opencode.ui.timeline_picker')
  timeline_picker.pick(user_entries, function(selected_entry)
    if selected_entry then
      require('opencode.ui.navigation').goto_message_by_id(selected_entry.id)
    end
  end)
end

---@param message_id? string
---@param open_in_new_tab? boolean|string
function M.actions.fork_session(message_id, open_in_new_tab)
  return with_active_session('No active session to fork', function(_, observation, session_fact, connection, location)
    local target = message_id and find_entry(observation, message_id)
      or find_last_user_entry(observation, session_fact)
    if not target or target.kind ~= 'user' then
      vim.notify('No user message to fork from', vim.log.levels.WARN)
      return
    end

    connection.operations
      .fork_session(
        connection,
        session_fact.id,
        location,
        { messageID = target.id },
        util.apply_path_map,
        util.apply_reverse_path_map
      )
      :and_then(function(response)
        vim.schedule(function()
          if response and response.id then
            vim.notify('Session forked successfully. New session ID: ' .. response.id, vim.log.levels.INFO)
            if open_in_new_tab == true or open_in_new_tab == 'tab' then
              session_runtime.open_session_in_tab(response)
            else
              session_runtime.switch_session(response.id)
            end
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
  tab = function(args)
    return M.actions.open_session_tab(parse_title(args, 2))
  end,
  tabs = function(args)
    return M.actions.select_session_tab(args[2])
  end,
  next_tab = function()
    return M.actions.next_session_tab()
  end,
  prev_tab = function()
    return M.actions.prev_session_tab()
  end,
  close_tab = function()
    return M.actions.close_session_tab()
  end,
  rename = function(args)
    return M.actions.rename_session(nil, parse_title(args, 2))
  end,
  select = function()
    return M.actions.select_session()
  end,
  navigate = function(args)
    local direction, interaction, wrap, empty_policy = normalize_navigate_args(args[2], args[3], args[4], args[5])
    return M.actions.navigate_session_tree(direction, interaction, wrap, empty_policy)
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
  toggle_lock = function(args)
    local raw = args[2]
    local value
    if raw == nil or raw == '' then
      value = nil
    elseif raw == 'true' or raw == 'on' or raw == '1' then
      value = true
    elseif raw == 'false' or raw == 'off' or raw == '0' then
      value = false
    else
      invalid_arguments('Invalid toggle_lock argument: ' .. tostring(raw))
    end
    return M.actions.toggle_session_lock(value)
  end,
}

local tab_subcommands = { 'next', 'new', 'previous', 'select', 'close' }

---@type table<string, fun(args: string[]): any>
local tab_subcommand_actions = {
  next = function()
    return M.actions.next_session_tab()
  end,
  new = function(args)
    return M.actions.open_session_tab(parse_title(args, 2))
  end,
  previous = function()
    return M.actions.prev_session_tab()
  end,
  select = function(args)
    return M.actions.select_session_tab(args[2])
  end,
  close = function()
    return M.actions.close_session_tab()
  end,
}

M.command_defs = {
  tab = {
    desc = 'Manage Opencode panel tabs',
    completions = tab_subcommands,
    nested_subcommand = { allow_empty = false },
    execute = function(args)
      local subcommand = args[1]
      local action = tab_subcommand_actions[subcommand]
      if not action then
        invalid_arguments('Invalid tab subcommand. Use: ' .. table.concat(tab_subcommands, ', '))
      end
      return action(args)
    end,
  },
  session = {
    desc = 'Manage sessions and Opencode panel tabs',
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
  open_session_tab = {
    desc = 'Open a new session in an Opencode panel tab',
    execute = function(args)
      return M.actions.open_session_tab(parse_title(args, 1))
    end,
  },
  select_session_tab = {
    desc = 'Select an Opencode panel tab',
    execute = function(args)
      return M.actions.select_session_tab(args[1])
    end,
  },
  next_session_tab = {
    desc = 'Switch to the next Opencode panel tab',
    execute = M.actions.next_session_tab,
  },
  prev_session_tab = {
    desc = 'Switch to the previous Opencode panel tab',
    execute = M.actions.prev_session_tab,
  },
  close_session_tab = {
    desc = 'Close the current Opencode panel tab',
    execute = M.actions.close_session_tab,
  },
  toggle_session_lock = {
    desc = 'Toggle session lock (preserve active session across cwd changes)',
    execute = function(args)
      return M.actions.toggle_session_lock(args[1])
    end,
  },
  select_session = {
    desc = 'Select session',
    execute = function()
      return M.actions.select_session()
    end,
  },
  navigate_session_tree = {
    desc = 'Navigate session tree (parent/child/sibling/forward/backward) or switch to a session by ID',
    execute = function(args)
      if args[1] and not NAV_DIRECTIONS[args[1]] then
        return M.actions.navigate_session_tree(args[1], args[2], args[3], args[4])
      end
      local direction, interaction, wrap, empty_policy = normalize_navigate_args(args[1], args[2], args[3], args[4])
      return M.actions.navigate_session_tree(direction, interaction, wrap, empty_policy)
    end,
  },
  rename_session = {
    desc = 'Rename session',
    execute = function(args)
      return M.actions.rename_session(nil, args[1])
    end,
  },
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
