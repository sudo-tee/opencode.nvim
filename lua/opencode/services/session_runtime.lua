local state = require('opencode.state')
local context = require('opencode.context')
local ui = require('opencode.ui.ui')
local server_job = require('opencode.server_job')
local input_window = require('opencode.ui.input_window')
local util = require('opencode.util')
local config = require('opencode.config')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local agent_model = require('opencode.services.agent_model')
local session_tabs = require('opencode.state.session_tabs')

local M = {}

local active_binding

local function release_active_observation()
  local previous = active_binding
  active_binding = nil
  if previous and previous.unsubscribe then
    previous.unsubscribe()
  end
end

local function observe_active_session()
  local observation = state.session.active_observation()
  local runtime = session_tabs.current()
  if active_binding and active_binding.observation == observation and active_binding.runtime == runtime then
    return
  end
  release_active_observation()
  -- Releasing the last watcher can remove the observation from the connection.
  observation = state.session.active_observation()
  if not observation then
    return
  end

  local binding = { observation = observation, runtime = runtime }
  active_binding = binding
  local session_id = observation:read().session.id
  local connection = state.opencode_server
  local tab_id = state.active_session_tab
  local function is_current()
    return active_binding == binding
      and state.opencode_server == connection
      and connection:is_ready()
      and state.active_session_tab == tab_id
      and state.active_session ~= nil
      and state.active_session.id == session_id
  end
  local function changed()
    if not is_current() then
      return
    end
    local observed = observation:read()
    local sync = observed.sync or {}
    if not (sync.session and sync.session.state == 'current') then
      return
    end
    state.session.update_active_metadata(observed.session)
    local owner = runtime or binding
    if
      sync.messages
      and sync.messages.state == 'current'
      and not binding.restoring_model
      and owner.model_restored_session_id ~= session_id
    then
      binding.restoring_model = true
      agent_model
        .initialize_current_model({ restore_from_messages = true, is_current = is_current })
        :and_then(function()
          if is_current() then
            owner.model_restored_session_id = session_id
          end
        end)
        :catch(function(err)
          log.debug('Failed to restore session model', { session_id = session_id, error = err })
        end)
        :finally(function()
          binding.restoring_model = false
        end)
    end
  end
  binding.unsubscribe = observation:watch({ 'session', 'messages' }, changed)
  changed()
end

---Keep active-session metadata and model selection current independently of rendering.
---Disabling releases the observation; enabling also adopts already-loaded facts.
---@param subscribe? boolean Defaults to true
function M.setup_subscriptions(subscribe)
  for _, key in ipairs({ 'active_session', 'active_session_tab', 'opencode_server' }) do
    if subscribe == false then
      state.store.unsubscribe(key, observe_active_session)
    else
      state.store.subscribe(key, observe_active_session)
    end
  end
  if subscribe == false then
    release_active_observation()
  else
    observe_active_session()
  end
end

local function current_location()
  return { directory = state.current_cwd or vim.fn.getcwd() }
end

local function session_directory(session_fact)
  return session_fact.location and session_fact.location.directory or session_fact.directory
end

local function sort_sessions(sessions)
  table.sort(sessions, function(a, b)
    if type(a.time) ~= 'table' or a.time.updated == nil or type(b.time) ~= 'table' or b.time.updated == nil then
      error('Session list entry requires time.updated')
    end
    return a.time.updated > b.time.updated
  end)
  return sessions
end

---@return boolean
function M.is_session_locked()
  local explicit = state.store.get('session_locked')
  if explicit ~= nil then
    return explicit
  end
  return config.lock_session_to_directory == true
end

---@param value boolean
---@return boolean
function M.set_session_lock(value)
  state.session.set_locked(value and true or false)
  return M.is_session_locked()
end

---@return boolean new_value
function M.toggle_session_lock()
  return M.set_session_lock(not M.is_session_locked())
end

---List sessions in the given scope. Always returns a non-nil array.
---@param scope? 'project' | 'global' defaults to project-scoped
---@return Promise<Session[]|GlobalSession[]>
M.list_sessions_by_scope = Promise.async(function(scope)
  local connection = server_job.ensure_server():await()
  local sessions
  if scope == 'global' then
    sessions = connection.operations.list_sessions_global(connection, util.apply_reverse_path_map):await()
  else
    sessions = connection.operations
      .list_sessions_project(connection, current_location(), util.apply_path_map, util.apply_reverse_path_map)
      :await()
  end
  if type(sessions) ~= 'table' then
    error('Session list operation returned an invalid response')
  end
  sort_sessions(sessions)
  if scope ~= 'global' and not util.is_git_project() then
    local cwd = vim.fn.getcwd()
    sessions = vim.tbl_filter(function(item)
      local directory = session_directory(item)
      return type(directory) == 'string' and vim.startswith(cwd, directory)
    end, sessions)
  end
  return sessions
end)

local last_workspace_session = Promise.async(function()
  for _, session_fact in ipairs(M.list_sessions_by_scope('project'):await()) do
    if session_fact.parentID == nil then
      return session_fact
    end
  end
  return nil
end)

---Keep only pickable sessions: non-empty title and matching parent_id.
---@param sessions Session[]|GlobalSession[]
---@param parent_id? string nil selects mainline (no parent), otherwise children of parent_id
---@return Session[]
function M.filter_pickable_sessions(sessions, parent_id)
  return vim.tbl_filter(function(s)
    return s ~= nil and s.title ~= '' and s.parentID == parent_id
  end, sessions)
end

---Activate a session and initialize its mode without changing panel visibility or focus.
---@param session_or_id Session|string
---@return Promise
M.switch_session = Promise.async(function(session_or_id)
  local selected_session = session_or_id
  if type(session_or_id) == 'string' then
    local active = state.session.active_observation()
    local active_fact = active and active:read().session or nil
    local location = (active_fact and active_fact.location) or (state.active_session and state.active_session.location)
      or current_location()
    local connection = server_job.ensure_server():await()
    selected_session = connection.operations
      .get_session(connection, session_or_id, location, util.apply_path_map, util.apply_reverse_path_map)
      :await()
  end
  if type(selected_session) ~= 'table' or type(selected_session.id) ~= 'string' then
    error('Session lookup returned an invalid response')
  end

  state.model.clear()
  state.session.set_active(selected_session)
  agent_model.ensure_current_mode():await()
end)

---@param opts? OpenOpts
M.open_if_closed = Promise.async(function(opts)
  if not state.ui.is_visible() then
    M.open(opts):await()
  end
end)

M.is_prompting_allowed = function()
  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)
  if not allowed then
    vim.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
  end
  return allowed
end

M.check_cwd = function()
  if state.current_cwd ~= vim.fn.getcwd() then
    log.debug(
      'CWD changed since last check, resetting session and context',
      { current_cwd = state.current_cwd, new_cwd = vim.fn.getcwd() }
    )
    state.context.set_current_cwd(vim.fn.getcwd())
    if M.is_session_locked() then
      return
    end
    state.session.clear_active()
    context.unload_attachments()
  end
end

---@param opts? OpenOpts
M.open = Promise.async(function(opts)
  opts = opts or { focus = 'input', new_session = false }

  session_tabs.ensure_current()
  session_tabs.set_context(context.snapshot())

  state.ui.set_opening(true)

  if not require('opencode.ui.ui').is_opencode_focused() then
    require('opencode.context').load()
  end

  local open_windows_action = opts.open_action or state.ui.resolve_open_windows_action()
  local are_windows_closed = open_windows_action ~= 'reuse_visible'
  local restoring_hidden = open_windows_action == 'restore_hidden'

  if are_windows_closed then
    if not ui.is_opencode_focused() then
      state.ui.set_code_context(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
    end

    M.is_prompting_allowed()

    if restoring_hidden then
      local restored = ui.restore_hidden_windows()
      if not restored then
        state.ui.clear_hidden_window_state()
        restoring_hidden = false
        state.ui.set_windows(ui.create_windows())
      end
    else
      state.ui.set_windows(ui.create_windows())
    end
  end

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed, start_insert = opts.start_insert == true })
  elseif opts.focus == 'output' then
    ui.focus_output({ restore_position = are_windows_closed })
  end

  local server_ok, server = pcall(function()
    return server_job.ensure_server():await()
  end)
  if not server_ok then
    state.ui.set_opening(false)
    return Promise.new():reject(server)
  end

  if not server then
    state.ui.set_opening(false)
    return Promise.new():reject('Server failed to start')
  end

  M.check_cwd()

  local ok, err = pcall(function()
    if opts.new_session then
      state.session.clear_active()
      context.unload_attachments()
      agent_model.ensure_current_mode():await()
      state.session.set_active(M.create_new_session():await())
      log.debug('Created new session on open', { session = state.active_session.id })
    else
      agent_model.ensure_current_mode():await()
      if not state.active_session then
        state.session.set_active(last_workspace_session():await())
        if not state.active_session then
          state.session.set_active(M.create_new_session():await())
        end
      elseif not state.display_route and are_windows_closed and not restoring_hidden and ui.is_output_empty() then
        ui.render_output()
      end
    end

    state.ui.set_panel_focused(true)
  end)

  state.ui.set_opening(false)

  if not ok then
    vim.notify('Error opening panel: ' .. tostring(err), vim.log.levels.ERROR)
    return Promise.new():reject(err)
  end
  return Promise.new():resolve('ok')
end)

---@param title_or_opts? string|boolean|table
---@return Session?
M.create_new_session = Promise.async(function(title_or_opts)
  local session_request = {}

  if type(title_or_opts) == 'string' then
    session_request = { title = title_or_opts }
  elseif type(title_or_opts) == 'table' and next(title_or_opts) ~= nil then
    session_request = title_or_opts
  end

  local connection = server_job.ensure_server():await()
  local location = current_location()
  local session_response = connection.operations
    .create_session(connection, location, session_request, util.apply_path_map, util.apply_reverse_path_map)
    :catch(function(err)
      vim.notify('Error creating new session: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
    :await()

  if session_response and session_response.id then
    return session_response
  end
end)

---Rename a session without mutating the supplied fact or prompting for input.
---@param session Session
---@param title string
---@return Promise<Session> Updated copy; rejects if disconnected or the operation fails.
M.rename_session = Promise.async(function(session, title)
  local connection = state.opencode_server
  if not connection or not connection:is_ready() then
    error('Connection is not ready')
  end
  local location = session.location or (session.directory and { directory = session.directory })
    or (state.active_session and state.active_session.location) or current_location()
  connection.operations
    .rename_session(connection, session.id, location, title, util.apply_path_map, util.apply_reverse_path_map)
    :await()
  local updated = vim.deepcopy(session)
  updated.title = title
  return updated
end)

---Check whether any session id in `delete_ids` is the session itself or an ancestor
---@param session_id string
---@param delete_ids table<string, boolean>
---@param all_sessions Session[]
---@return boolean
function M.is_session_or_ancestor_deleted(session_id, delete_ids, all_sessions)
  local session_map = {}
  for _, s in ipairs(all_sessions) do
    session_map[s.id] = s
  end

  local current_id = session_id
  while current_id do
    if delete_ids[current_id] then
      return true
    end
    local s = session_map[current_id]
    current_id = s and s.parentID or nil
  end
  return false
end

---@param sessions_to_delete Session[] Sessions to delete sequentially.
---@param candidates Session[] Ordered replacement candidates from the current selection.
---@param on_deleted? fun(session: Session) Called after each successful deletion.
---@return Promise Deletes after replacing an affected active session; rejects on operation failure.
M.delete_sessions = Promise.async(function(sessions_to_delete, candidates, on_deleted)
  local connection = state.opencode_server
  local to_delete_ids = {}
  for _, s in ipairs(sessions_to_delete) do
    to_delete_ids[s.id] = true
  end

  local deleting_current = false
  if state.active_session then
    local all_sessions = Promise.wrap(M.list_sessions_by_scope('project')):await()
    deleting_current = M.is_session_or_ancestor_deleted(state.active_session.id, to_delete_ids, all_sessions)
  end

  if deleting_current then
    local remaining = vim.tbl_filter(function(item)
      return not to_delete_ids[item.id]
    end, candidates)

    if #remaining > 0 then
      ui.switch_session(remaining[1]):await()
    else
      vim.notify('deleting current session, creating new session')
      state.model.clear()
      state.session.set_active(M.create_new_session():await())
      agent_model.ensure_current_mode():await()
    end
  end

  for _, session in ipairs(sessions_to_delete) do
    connection.operations
      .delete_session(
        connection,
        session.id,
        session.location or (session.directory and { directory = session.directory }),
        util.apply_path_map
      )
      :await()
    if on_deleted then
      on_deleted(session)
    end
  end
end)

---@param session Session
---@param message_id? string Omit to fork the complete session.
---@return Promise<Session|nil> Rejects on operation failure.
M.fork_session = Promise.async(function(session, message_id)
  local connection = state.opencode_server
  return connection.operations.fork_session(
    connection,
    session.id,
    session.location or (session.directory and { directory = session.directory }),
    message_id and { messageID = message_id } or {},
    util.apply_path_map,
    util.apply_reverse_path_map
  ):await()
end)

---Mount an existing session in a new logical panel tab.
---@param selected_session Session
---@return Promise<Session|nil>
M.open_session_in_tab = Promise.async(function(selected_session)
  if not selected_session or not selected_session.id then
    return nil
  end

  for _, runtime in ipairs(session_tabs.list()) do
    if runtime.active_session and runtime.active_session.id == selected_session.id then
      M.switch_session_tab(runtime.id):await()
      return selected_session
    end
  end

  session_tabs.set_context(context.snapshot())
  if state.ui.is_visible() then
    ui.prepare_session_tab_switch()
    ui.hide_visible_windows(state.windows, true)
  end
  session_tabs.sync()

  local runtime = session_tabs.create(selected_session)
  session_tabs.activate(runtime)
  context.restore(session_tabs.get_context())
  state.model.clear()

  M.open({
    focus = 'input',
    start_insert = true,
    new_session = false,
    open_action = 'create_fresh',
  }):await()

  return selected_session
end)

---@param session_id string
---@return Promise<Session|nil>
M.open_session_in_tab_by_id = Promise.async(function(session_id)
  local connection = server_job.ensure_server():await()
  local selected_session = connection.operations
    .get_session(connection, session_id, current_location(), util.apply_path_map, util.apply_reverse_path_map)
    :await()
  if not selected_session then
    return nil
  end
  return M.open_session_in_tab(selected_session):await()
end)

---Open a new session in a logical tab inside the Opencode panel.
---@param title? string
---@return Promise<Session|nil>
M.open_session_tab = Promise.async(function(title)
  local new_session = M.create_new_session(title):await()
  if not new_session then
    return nil
  end
  return M.open_session_in_tab(new_session):await()
end)

---Switch to a logical tab inside the Opencode panel.
---@param tab_id string
---@return Promise<Session|nil>
M.switch_session_tab = Promise.async(function(tab_id)
  local runtime = session_tabs.get(tab_id)
  if not runtime then
    return nil
  end

  if session_tabs.active_id() == tab_id then
    return runtime.active_session
  end

  session_tabs.set_context(context.snapshot())
  if state.ui.is_visible() then
    ui.prepare_session_tab_switch()
    ui.hide_visible_windows(state.windows, true)
  end
  session_tabs.sync()
  session_tabs.activate(runtime)
  context.restore(session_tabs.get_context())

  local focus = state.last_focused_opencode_window == 'output' and 'output' or 'input'
  M.open({
    focus = focus,
    new_session = false,
    open_action = 'restore_hidden',
  }):await()

  return runtime.active_session
end)

---Switch to a logical panel tab by its displayed index.
---@param index integer|string
---@return Promise<Session|nil>
M.switch_session_tab_by_index = Promise.async(function(index)
  index = tonumber(index)
  if not index or index < 1 or index % 1 ~= 0 then
    return nil
  end

  local runtime = session_tabs.list()[index]
  if not runtime then
    return nil
  end

  return M.switch_session_tab(runtime.id):await()
end)

---Switch to the next or previous logical panel tab.
---@param direction 1|-1
---@return Promise<Session|nil>
M.cycle_session_tab = Promise.async(function(direction)
  local tabs = session_tabs.list()
  if #tabs < 2 then
    return nil
  end

  local current_id = session_tabs.active_id()
  local current_index = 1
  for index, runtime in ipairs(tabs) do
    if runtime.id == current_id then
      current_index = index
      break
    end
  end

  local next_index = ((current_index - 1 + direction) % #tabs) + 1
  return M.switch_session_tab(tabs[next_index].id):await()
end)

---@param runtime OpencodeSessionTabRuntime
local function delete_runtime_buffers(runtime)
  local buffers = {}
  local seen = {}

  local function collect(source)
    for _, key in ipairs({ 'input_buf', 'output_buf', 'footer_buf', 'tab_strip_buf' }) do
      local bufnr = source and source[key]
      if bufnr and not seen[bufnr] then
        seen[bufnr] = true
        table.insert(buffers, bufnr)
      end
    end
  end

  collect(runtime.windows)
  collect(runtime._hidden_buffers)

  for _, bufnr in ipairs(buffers) do
    require('opencode.ui.session_tab_strip').clear_buffer(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---Close a logical panel tab.
---@param tab_id? string Close selected tab, or the active tab when omitted.
---@return boolean
function M.close_session_tab(tab_id)
  local runtime
  if tab_id then
    runtime = session_tabs.get(tab_id)
    if not runtime then
      return false
    end
  else
    runtime = session_tabs.current()
  end
  if not runtime then
    return false
  end

  local active_id = session_tabs.active_id()
  if tab_id and active_id ~= runtime.id then
    delete_runtime_buffers(runtime)
    session_tabs.remove(runtime)
    return true
  end

  local tabs = session_tabs.list()
  if #tabs == 1 then
    session_tabs.set_context(context.snapshot())
    ui.teardown_visible_windows(state.windows)
    session_tabs.remove(runtime)
    state.session.clear_active()
    return true
  end

  local next_runtime
  for _, candidate in ipairs(tabs) do
    if candidate.id ~= runtime.id then
      next_runtime = candidate
      break
    end
  end

  session_tabs.set_context(context.snapshot())
  if state.ui.is_visible() then
    ui.prepare_session_tab_switch()
    ui.hide_visible_windows(state.windows, true)
  end
  session_tabs.sync()
  delete_runtime_buffers(runtime)
  session_tabs.remove(runtime)
  session_tabs.activate(next_runtime)
  context.restore(session_tabs.get_context())

  M.open({
    focus = 'input',
    new_session = false,
    open_action = 'restore_hidden',
  })
  return true
end

---@param opts? SendMessageOpts
function M.before_run(opts)
  local is_new_session = opts and opts.new_session or not state.active_session
  M.open({
    new_session = is_new_session,
  })
end

---@param session_id? string
---@param tab_id? string
---@param opts? { count_abort?: boolean }
M.cancel = Promise.async(function(session_id, tab_id, opts)
  local target_runtime = tab_id and session_tabs.get(tab_id) or session_tabs.current()
  local target_session = target_runtime and target_runtime.active_session or (not tab_id and state.active_session)
  local observation = session_id and state.opencode_server and state.opencode_server:observe({ id = session_id })
    or state.session.active_observation()

  if observation then
    local pending_count = target_runtime
        and target_runtime.user_message_count
        and session_id
        and target_runtime.user_message_count[session_id]
      or nil
    local request_running = (tab_id and pending_count and pending_count > 0) or state.jobs.is_running()
    if request_running or (opts and opts.count_abort) then
      vim.g.opencode_abort_count = (vim.g.opencode_abort_count or 0) + 1
    end

    local observed = observation:read()
    for _, request in pairs(observed.permission_requests_by_id or {}) do
      if request.status == 'pending' and (not session_id or request.session_id == session_id) then
        pcall(function()
          observation:reply_permission(request.id, 'reject'):await()
        end)
      end
    end

    local ok, result = pcall(function()
      return observation:interrupt():await()
    end)

    if not ok then
      vim.notify('Abort error: ' .. vim.inspect(result), vim.log.levels.ERROR)
    end

    local connection = state.opencode_server
    if
      (vim.g.opencode_abort_count or 0) >= 3
      and connection
      and connection.can_release_process
      and connection:can_release_process()
    then
      vim.notify('Re-starting Opencode server', vim.log.levels.WARN)
      vim.g.opencode_abort_count = 0
      connection:close():await()
      state.jobs.clear_server()
      state.jobs.set_server(server_job.ensure_server():await() --[[@as OpencodeServer]])
    end
  end

  if
    target_session
    and target_session.id == (state.active_session and state.active_session.id)
    and state.ui.is_visible()
  then
    require('opencode.ui.footer').clear()
    input_window.set_content('')
    require('opencode.history').index = nil
    ui.focus_input()
  end
end)

M.opencode_ok = Promise.async(function()
  if vim.fn.executable(config.opencode_executable) == 0 then
    vim.notify(
      'opencode command not found - please install and configure opencode before using this plugin',
      vim.log.levels.ERROR
    )
    return false
  end

  if not state.opencode_cli_version then
    local promise = Promise.system({ config.opencode_executable, '--version' }):and_then(function(result)
      local out = (result and result.stdout or ''):gsub('%s+$', '')
      out = out:match('(%d+%%.%d+%%.%d+)') or out
      return Promise.new():resolve(out)
    end) ---@type Promise<string>
    state.jobs.set_opencode_cli_version(promise)
  end

  local required = state.required_version
  local current_version = state.opencode_cli_version:await()

  if not current_version or current_version == '' then
    vim.notify(string.format('Unable to detect opencode CLI version. Requires >= %s', required), vim.log.levels.ERROR)
    return false
  end

  if not util.is_version_greater_or_equal(current_version, required) then
    vim.notify(
      string.format('Unsupported opencode CLI version: %s. Requires >= %s', current_version, required),
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end)

---@param completed_session Session
local function notify_done_thinking(completed_session)
  local hook = config.hooks and config.hooks.on_done_thinking
  if not hook or not completed_session or not completed_session.id then
    return
  end
  pcall(hook, completed_session)
end

M._on_user_message_count_change = Promise.async(function()
  require('opencode.ui.renderer.flush').flush_pending_on_data_rendered()
end)

---Notify completion of the last outstanding local request for a session.
---@param session_id string
---@return Promise<nil>
M.on_session_request_completed = Promise.async(function(session_id)
  if not session_id or not (config.hooks and config.hooks.on_done_thinking) then
    return
  end

  local connection = state.opencode_server
  if not connection or not connection:is_ready() then
    return
  end
  local completed_session = connection.operations
    .get_session(connection, session_id, current_location(), util.apply_path_map, util.apply_reverse_path_map)
    :await()
  if completed_session then
    notify_done_thinking(completed_session)
  end
end)


M._on_current_permission_change = Promise.async(function(_, new, old)
  local permission_requested = #old < #new
  if config.hooks and config.hooks.on_permission_requested and permission_requested then
    local observation = state.session.active_observation()
    local local_session = observation and observation:read().session or {}
    pcall(config.hooks.on_permission_requested, local_session)
  end
end)

M.handle_directory_change = Promise.async(function()
  local cwd = vim.fn.getcwd()
  log.debug('Working directory change %s', vim.inspect({ cwd = cwd, locked = M.is_session_locked() }))

  if M.is_session_locked() and state.active_session then
    vim.notify(
      'Session locked, staying on [' .. state.active_session.id .. '] in new working dir [' .. cwd .. ']',
      vim.log.levels.INFO
    )
    return
  end

  vim.notify('Loading last session for new working dir [' .. cwd .. ']', vim.log.levels.INFO)

  state.session.clear_active()
  context.unload_attachments()

  state.session.set_active(last_workspace_session():await() or M.create_new_session():await())

  log.debug('Loaded session for new working dir ' .. vim.inspect({ session = state.active_session }))
end)

return M
