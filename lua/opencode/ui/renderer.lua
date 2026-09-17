local state = require('opencode.state')
local config = require('opencode.config')
local output_window = require('opencode.ui.output_window')
local reference_facts = require('opencode.ui.reference_facts')
local ctx = require('opencode.ui.renderer.ctx')
local RenderSession = require('opencode.ui.renderer.session')
local flush = require('opencode.ui.renderer.flush')
local rendered_entries = require('opencode.ui.renderer.entries')
local symbol_refresh = require('opencode.ui.renderer.symbol_refresh')
local scroll = require('opencode.ui.renderer.scroll')
local session_tabs = require('opencode.state.session_tabs')

local M = {}
local HIDDEN_MESSAGES_NOTICE_MESSAGE_ID = '__opencode_hidden_messages_notice__'
local HIDDEN_MESSAGES_NOTICE_PART_ID = '__opencode_hidden_messages_notice_part__'
local PERMISSION_DISPLAY_MESSAGE_ID = 'permission-display-message'
local QUESTION_DISPLAY_MESSAGE_ID = 'question-display-message'

local LAZYRENDER_EST_LINES_PER_MSG = 5
local LAZYRENDER_VIEWPORT_BUFFER = 1.5
local rendered_session_tab = nil

---@param tab_id string|nil
local function save_tab_context(tab_id)
  if not tab_id then
    return
  end

  local runtime = session_tabs.get(tab_id)
  if runtime then
    local snapshot = ctx:snapshot()
    local windows = tab_id == state.active_session_tab and state.windows or runtime.windows
    snapshot.output_buf = windows and windows.output_buf or nil
    runtime.renderer_context = snapshot
  end
end

---@param tab_id string|nil
---@return boolean
local function restore_tab_context(tab_id)
  local runtime = tab_id and session_tabs.get(tab_id)
  if not runtime or not runtime.renderer_context then
    ctx:restore(nil)
    reference_facts.clear()
    return false
  end

  local output_buf = state.windows and state.windows.output_buf
  if runtime.renderer_context.output_buf and runtime.renderer_context.output_buf ~= output_buf then
    ctx:restore(nil)
    reference_facts.clear()
    return false
  end

  ctx:restore(runtime.renderer_context)
  if state.active_session then
    reference_facts.rebuild(state.active_session.id, ctx.entries or {})
  else
    reference_facts.clear()
  end
  return true
end

local function save_active_tab_context()
  save_tab_context(state.active_session_tab)
end

---@type OpencodeRenderSession|nil
local render_session

local function detach_render_session()
  if render_session then
    render_session:close()
    render_session = nil
  end
  ctx.observation = nil
end

---Calculate how many messages to render initially based on window height.
---@return integer
local function get_initial_render_count()
  local win = state.windows and state.windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return math.huge -- no window: render all (tests, headless)
  end
  local ok, height = pcall(vim.api.nvim_win_get_height, win)
  if not ok or not height or height <= 0 then
    return math.huge
  end
  return math.ceil(height / LAZYRENDER_EST_LINES_PER_MSG * LAZYRENDER_VIEWPORT_BUFFER)
end

---@return integer|nil
local function get_max_rendered_messages()
  local limit = config.ui and config.ui.output and config.ui.output.max_messages
  if type(limit) ~= 'number' or limit <= 0 then
    return nil
  end
  return math.floor(limit)
end

---@param message table|nil
---@return boolean
local function is_renderer_synthetic_message(message)
  local message_id = message and message.id
  return message_id == '__opencode_revert_message__'
    or message_id == HIDDEN_MESSAGES_NOTICE_MESSAGE_ID
    or message_id == PERMISSION_DISPLAY_MESSAGE_ID
    or message_id == QUESTION_DISPLAY_MESSAGE_ID
end

---@param message table|nil
---@return boolean
local function is_active_session_message(message)
  local session_id = message and message.session_id
  return session_id ~= nil and state.active_session and state.active_session.id == session_id
end

---@param messages table[]|nil
---@return table[]
local function get_real_session_messages(messages)
  return vim.tbl_filter(function(message)
    return is_active_session_message(message) and not is_renderer_synthetic_message(message)
  end, messages or {})
end

---@param messages table[]|nil
---@param session table|nil
---@return integer|nil
local function get_revert_index(messages, session)
  local revert = session and session.revert
  local revert_message_id = revert and revert.messageID
  if not revert_message_id then
    return nil
  end

  local real_messages = get_real_session_messages(messages)
  for i, message in ipairs(real_messages) do
    if message.id == revert_message_id then
      return i
    end
  end

  return nil
end

---@param messages table[]|nil
---@param session table|nil
---@return table[] visible_messages
---@return integer hidden_count
local function get_visible_session_messages(messages, session)
  local real_messages = get_real_session_messages(messages)
  local revert_index = get_revert_index(messages, session)
  if revert_index then
    real_messages = vim.list_slice(real_messages, 1, revert_index - 1)
  end

  local limit = get_max_rendered_messages()
  if not limit or #real_messages <= limit then
    return real_messages, 0
  end

  local start_index = #real_messages - limit + 1
  return vim.list_slice(real_messages, start_index, #real_messages), start_index - 1
end

---@return table session The observed session, or the active session's id alone
---when no observation is bound yet.
local function current_session()
  return ctx.observation and ctx.observation:read().session
    or { id = state.active_session and state.active_session.id }
end

---@return integer Messages the current session would show at full window size.
local function visible_message_count()
  return #get_visible_session_messages(ctx.entries, current_session())
end

---@param hidden_count integer
---@return table
local function build_hidden_messages_notice(hidden_count)
  local session_id = state.active_session and state.active_session.id or ''
  return {
    id = HIDDEN_MESSAGES_NOTICE_MESSAGE_ID,
    session_id = session_id,
    kind = 'synthetic',
    content = {
      {
        id = HIDDEN_MESSAGES_NOTICE_PART_ID,
        kind = 'hidden_messages_display',
        hidden_count = hidden_count,
      },
    },
  }
end

---@param message table
local function ensure_message_rendered(message)
  local message_id = message.id
  if not message_id or ctx.render_state:get_message(message_id) then
    return
  end

  ctx.render_state:set_message(message)
  flush.mark_message_dirty(message_id)

  for index, part in ipairs(message.content or {}) do
    if part.kind ~= 'step_start' and part.kind ~= 'step_finish' then
      local part_id = ctx.content_key(message, index)
      ctx.render_state:set_part(part, message_id, part_id)
      flush.mark_part_dirty(part_id, message_id)
    end
  end
end

---@param message_id string
local function hide_rendered_message(message_id)
  local rendered_message = ctx.render_state:get_message(message_id)
  local message = rendered_message and rendered_message.message
  if not message then
    return
  end

  for part_id, part in pairs(ctx.render_state._parts) do
    if part.message_id == message_id then
      flush.queue_part_removal(part_id)
    end
  end
  flush.queue_message_removal(message_id)
end

---@param hidden_count integer
local function upsert_hidden_messages_notice(hidden_count)
  local existing_message = ctx.render_state:get_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID)
  local notice_message = build_hidden_messages_notice(hidden_count)

  if not existing_message then
    ensure_message_rendered(notice_message)
  else
    local existing_part = ctx.render_state:get_part(HIDDEN_MESSAGES_NOTICE_PART_ID)
    if not existing_part or not existing_part.part then
      hide_rendered_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID)
      ensure_message_rendered(notice_message)
    else
      ctx.render_state:set_message(notice_message, existing_message.line_start, existing_message.line_end)
      ctx.render_state:set_part(
        notice_message.content[1],
        notice_message.id,
        HIDDEN_MESSAGES_NOTICE_PART_ID,
        existing_part.line_start,
        existing_part.line_end
      )
    end
  end

  local part_data = ctx.render_state:get_part(HIDDEN_MESSAGES_NOTICE_PART_ID)
  if part_data then
    ctx.render_state:add_actions(HIDDEN_MESSAGES_NOTICE_PART_ID, {
      {
        text = 'Toggle Max Messages',
        type = 'toggle_max_messages',
        args = {},
        key = 'm',
        range = { from = part_data.line_start, to = part_data.line_end },
        display_line = part_data.line_start,
      },
    })
    flush.mark_part_dirty(HIDDEN_MESSAGES_NOTICE_PART_ID, HIDDEN_MESSAGES_NOTICE_MESSAGE_ID)
  end
end

local function reconcile_rendered_message_limit()
  if not ctx.observation then
    return
  end

  local limit = get_max_rendered_messages()
  if not limit then
    if ctx.render_state:get_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID) then
      hide_rendered_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID)
    end
    return
  end

  local observation_state = ctx.observation:read()
  local visible_messages, hidden_count = get_visible_session_messages(ctx.entries, observation_state.session)
  local visible_ids = {}
  for _, message in ipairs(visible_messages) do
    local message_id = message.id
    if message_id then
      visible_ids[message_id] = true
      ensure_message_rendered(message)
    end
  end

  for _, message in ipairs(get_real_session_messages(ctx.entries)) do
    local message_id = message.id
    if message_id and not visible_ids[message_id] and ctx.render_state:get_message(message_id) then
      hide_rendered_message(message_id)
    end
  end

  if hidden_count > 0 then
    upsert_hidden_messages_notice(hidden_count)
  elseif ctx.render_state:get_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID) then
    hide_rendered_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID)
  end
end

---@param message_id string|nil
---@return boolean
local function is_message_visible(message_id)
  if not message_id then
    return false
  end

  for _, message in ipairs(get_visible_session_messages(ctx.entries, current_session())) do
    if message.id == message_id then
      return true
    end
  end

  return false
end

local function ordered_entries(observation)
  local observed = observation:read()
  local entries = {}
  for _, id in ipairs(observed.entry_order or {}) do
    local entry = observed.entries_by_id and observed.entries_by_id[id]
    if entry then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

local function total_tokens(tokens)
  return (tokens.input or 0)
    + (tokens.output or 0)
    + (tokens.reasoning or 0)
    + (tokens.cache and tokens.cache.read or 0)
    + (tokens.cache and tokens.cache.write or 0)
end

local function update_stats(tokens, cost)
  local count = total_tokens(tokens)
  if count > 0 then
    if type(cost) == 'number' then
      state.renderer.set_stats(count, cost)
    else
      state.renderer.set_tokens_count(count)
    end
    return true
  elseif type(cost) == 'number' and cost > 0 then
    state.renderer.set_cost(cost)
    return true
  end
  return false
end

local function update_observation_stats(observation)
  local observed = observation:read()
  local session = observed.sync
      and observed.sync.session
      and observed.sync.session.state == 'current'
      and observed.session
    or nil
  if session and session.cost ~= nil and session.tokens and update_stats(session.tokens, session.cost) then
    return
  end

  for index = #(observed.entry_order or {}), 1, -1 do
    local entry = observed.entries_by_id and observed.entries_by_id[observed.entry_order[index]]
    if entry and entry.cost ~= nil and entry.tokens ~= nil and update_stats(entry.tokens, entry.cost) then
      return
    end
  end
end

ctx.get_child_parts = function(session_id)
  local observation = render_session and render_session:child(session_id)
  if not observation then
    return nil
  end
  local parts = {}
  for _, entry in ipairs(ordered_entries(observation)) do
    for _, content in ipairs(entry.content or {}) do
      if content.kind == 'tool' then
        parts[#parts + 1] = content
      end
    end
  end
  return parts
end

local function reconcile_prompt_display(message_id, part_id, kind, visible)
  if not visible then
    if ctx.render_state:get_message(message_id) then
      hide_rendered_message(message_id)
    end
    return
  end
  local session_id = state.active_session and state.active_session.id or ''
  local content = { id = part_id, kind = kind }
  local entry = { id = message_id, session_id = session_id, kind = 'system', content = { content } }
  local rendered_message = ctx.render_state:get_message(message_id)
  local rendered_part = ctx.render_state:get_part(part_id)
  ctx.render_state:set_message(
    entry,
    rendered_message and rendered_message.line_start,
    rendered_message and rendered_message.line_end
  )
  ctx.render_state:set_part(
    content,
    message_id,
    part_id,
    rendered_part and rendered_part.line_start,
    rendered_part and rendered_part.line_end
  )
  flush.mark_message_dirty(message_id)
  flush.mark_part_dirty(part_id, message_id)
end

function M.refresh_prompts()
  local permission = ctx.prompt_controllers.permission
  local question = ctx.prompt_controllers.question
  reconcile_prompt_display(
    PERMISSION_DISPLAY_MESSAGE_ID,
    'permission-display-part',
    'permissions-display',
    permission and #permission.get_all_permissions() > 0
  )
  local request = question and question.get_current_request()
  reconcile_prompt_display(
    QUESTION_DISPLAY_MESSAGE_ID,
    'question-display-part',
    'questions-display',
    question and question.has_question() and not question.uses_vim_ui_select(request)
  )
  flush.schedule()
end

local function sync_prompt_controllers(observations)
  local permission = ctx.prompt_controllers.permission
  if permission and permission.sync then
    permission.sync(observations)
  end
  local question = ctx.prompt_controllers.question
  if question and question.sync then
    question.sync(observations)
  end
  M.refresh_prompts()
end

local function apply_file_changes(observed)
  local files = observed.files
  if not files or files.revision <= ctx.file_revision then
    return false
  end
  ctx.file_revision = files.revision
  vim.cmd('checktime')
  if config.hooks and config.hooks.on_file_edited and files.last then
    pcall(config.hooks.on_file_edited, files.last.path)
  end
  reference_facts.refresh_current_files()
  return true
end

local function invalidate_text_references()
  for part_id, rendered in pairs(ctx.render_state._parts) do
    if rendered.part.kind == 'text' then
      flush.mark_part_dirty(part_id, rendered.message_id)
    end
  end
end

---Adopt an observation's state as the displayed session state. Metadata and the
---restored model follow the displayed root only, and only from a current snapshot.
---@param observation table
---@param is_root_change boolean The changed observation is the displayed root
---@return table session
---@return table[] entries
local function adopt_session_state(observation, is_root_change)
  local observed = observation:read()
  local sync = observed.sync or {}
  local synced_session = sync.session and sync.session.state == 'current' and observed.session or nil
  if is_root_change and synced_session then
    state.session.update_active_metadata(synced_session)
  end
  local entries = ordered_entries(observation)
  ctx.entries = entries
  local session_id = synced_session and synced_session.id
  local messages_current = sync.messages and sync.messages.state == 'current'
  if is_root_change and session_id and messages_current and ctx.model_restored_session_id ~= session_id then
    ctx.model_restored_session_id = session_id
    require('opencode.services.agent_model').initialize_current_model({ restore_from_messages = true })
  end
  update_observation_stats(observation)
  return synced_session or { id = state.active_session and state.active_session.id }, entries
end

local function reconcile_conversation(session, entries, files_changed)
  local previous_refs = reference_facts.current_refs()
  reference_facts.rebuild(session.id, entries, session.location)
  local references_changed = not vim.deep_equal(previous_refs, reference_facts.current_refs())
  local visible, hidden_count = get_visible_session_messages(entries, session)
  if ctx.lazy_render_count == nil then
    local initial = get_initial_render_count()
    if #visible > initial then
      ctx.lazy_render_count = initial
    end
  end
  if ctx.lazy_render_count and #visible > ctx.lazy_render_count then
    visible = vim.list_slice(visible, #visible - ctx.lazy_render_count + 1)
  end
  local desired = {}
  for _, entry in ipairs(visible) do
    desired[entry.id] = true
  end
  for message_id in pairs(ctx.render_state._messages) do
    if not desired[message_id] and not is_renderer_synthetic_message({ id = message_id }) then
      hide_rendered_message(message_id)
    end
  end
  local initial_render = #visible > 0
    and next(ctx.render_state._messages) == nil
    and output_window.mounted()
    and state.ui.is_window_in_current_tab(state.windows.output_win)
    and not ctx.bulk_mode
  if initial_render then
    flush.begin_bulk_mode()
  end
  if hidden_count > 0 then
    upsert_hidden_messages_notice(hidden_count)
  elseif ctx.render_state:get_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID) then
    hide_rendered_message(HIDDEN_MESSAGES_NOTICE_MESSAGE_ID)
  end
  rendered_entries.reconcile(visible, references_changed or files_changed)
  return initial_render
end

---Which areas of the display a set of changed resources affects. `activity` names
---no area: execution and inbox render nothing, they only release held-back writes.
---@param resources? table<string, boolean> Omitted for an explicit full refresh
---@return {conversation: boolean, prompts: boolean, files: boolean, activity: boolean}
local function affected_areas(resources)
  if not resources then
    return { conversation = true, prompts = false, files = false, activity = false }
  end
  return {
    conversation = resources.messages or resources.session or resources.children or false,
    prompts = resources.permissions or resources.questions or false,
    files = resources.files or false,
    activity = resources.execution or resources.inbox or false,
  }
end

---A child's conversation is visible only through its task part in the root.
---@param observation table
---@return boolean rendered Whether the child still has somewhere to render
local function mark_child_task_dirty(observation)
  local session_id = render_session and render_session:child_id(observation)
  if not session_id then
    return false
  end
  local task_part_id = ctx.render_state:get_task_part_by_child_session(session_id)
  if task_part_id then
    flush.mark_part_dirty(task_part_id)
  end
  return true
end

---@param observation table The observation that changed, root or descendant
---@param resources? table<string, boolean> Omitted for an explicit full refresh
local function reconcile_observation(observation, resources)
  local root = ctx.observation
  if not root then
    return
  end
  local affected = affected_areas(resources)

  -- Nothing on screen depends on this change; only held-back writes need releasing.
  if not (affected.conversation or affected.prompts or affected.files) then
    flush.flush_pending_on_data_rendered()
    return
  end

  if affected.conversation and observation ~= root and not mark_child_task_dirty(observation) then
    return
  end

  local observations = render_session and render_session:sync_children() or { root }
  local files_changed = (affected.conversation or affected.files) and apply_file_changes(root:read()) or false

  if affected.conversation or affected.prompts or files_changed then
    local initial_render = false
    if affected.conversation then
      local session, entries = adopt_session_state(root, observation == root)
      initial_render = reconcile_conversation(session, entries, files_changed)
    elseif files_changed then
      invalidate_text_references()
    end
    if affected.conversation or affected.prompts then
      sync_prompt_controllers(observations)
    end
    flush.flush({ resolve_symbol_targets = initial_render })
    if initial_render then
      flush.end_bulk_mode()
      M.scroll_to_bottom(true)
    end
  end

  if affected.activity then
    flush.flush_pending_on_data_rendered()
  end
end

---Effective size of the rendered window: `lazy_render_count` capped by the
---cached total (nil means everything cached is rendered).
---@return number
local function window_size()
  local total = visible_message_count()
  return math.min(ctx.lazy_render_count or total, total)
end

---Grow the rendered window to `target` messages (capped at the cached
---total) and re-render. Single write primitive for the lazy window.
---@param target number desired window size
---@return boolean Whether the window grew
local function apply_window_growth(target)
  local total = visible_message_count()
  target = math.min(target, total)
  local current = math.min(ctx.lazy_render_count or total, total)
  if target <= current then
    return false
  end
  ctx.lazy_render_count = target
  M.render_from_cache()
  return true
end

---Capture the top visible line as a message anchor so the view survives a
---re-render that prepends older history.
---@return table|nil { id: string, offset: number }
function M.capture_top_anchor()
  local win = state.windows and state.windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local top_line = output_window.get_visible_top_line(win)
  if not top_line then
    return nil
  end
  for _, entry in ipairs(ctx.entries) do
    local rendered = ctx.render_state:get_message(entry.id)
    if rendered and rendered.line_start and rendered.line_end and rendered.line_end >= top_line then
      return { id = entry.id, offset = math.max(0, top_line - rendered.line_start) }
    end
  end
  return nil
end

---Restore a view captured by `capture_top_anchor` after a re-render.
---@param anchor table|nil
function M.restore_top_anchor(anchor)
  if not anchor then
    return
  end
  local win = state.windows and state.windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local rendered = ctx.render_state:get_message(anchor.id)
  if rendered and rendered.line_start then
    local restored = math.max(1, rendered.line_start + anchor.offset)
    pcall(vim.api.nvim_win_set_cursor, win, { restored, 0 })
    pcall(output_window.restore_view_topline, win, restored)
  end
end

local function notify_history_failure(err)
  local message = type(err) == 'table' and (err.message or err.cause) or err
  vim.notify('Failed to load older messages: ' .. tostring(message), vim.log.levels.WARN)
end

---The cached window is exhausted but the protocol may still hold older
---pages: pull one page, grow the rendered window by one viewport past the
---merge, and keep the view anchored where it was. The protocol short-circuits
---to a no-op when the history is already complete, so no pre-check is needed.
---@return boolean Whether a page load was started
local function grow_window_with_older_page()
  local observation = ctx.observation
  if not observation or type(observation.load_older) ~= 'function' then
    return false
  end
  local window_before = window_size()
  local entries_before = #ordered_entries(observation)
  local anchor = M.capture_top_anchor()
  local ok, request = pcall(function()
    return observation:load_older()
  end)
  if not ok then
    return false
  end
  request:and_then(function()
    -- nothing merged (complete history or a concurrent pull elsewhere):
    -- leave the window alone
    if #ordered_entries(observation) <= entries_before then
      return
    end
    if not apply_window_growth(window_before + get_initial_render_count()) then
      -- the window already covered everything cached: drop the window limit
      -- so the merged prefix renders, without pulling more pages
      ctx.lazy_render_count = nil
      M.render_from_cache()
    end
    M.restore_top_anchor(anchor)
  end, notify_history_failure)
  return true
end

---Pull the complete remaining history, render all of it, and land the
---cursor at the true top of the session.
---@return boolean Whether a history load was started
local function load_complete_history_to_top()
  local observation = ctx.observation
  if not observation or type(observation.load_complete_history) ~= 'function' then
    return false
  end
  local win = state.windows and state.windows.output_win
  local ok, request = pcall(function()
    return observation:load_complete_history()
  end)
  if not ok then
    return false
  end
  request:and_then(function()
    -- grow to the merged total only; the rendering primitive does not
    -- touch the protocol, so this callback cannot re-enter the pull
    apply_window_growth(math.huge)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
      pcall(output_window.restore_view_topline, win, 1)
    end
  end, notify_history_failure)
  return true
end

---Reset all renderer state and clear the output buffer
function M.reset()
  ctx:reset()
  reference_facts.clear()
  output_window.clear()
  if ctx.prompt_controllers.permission then
    ctx.prompt_controllers.permission.clear_all()
  end
  if ctx.prompt_controllers.question then
    ctx.prompt_controllers.question.clear_all()
  end
  state.renderer.reset()
  flush.trigger_on_data_rendered()
end

---Unsubscribe from all events and reset
function M.teardown()
  M.setup_subscriptions(false)
  detach_render_session()
  M.reset()
end

---Subscribe to (or unsubscribe from) all renderer events
---@param subscribe? boolean  false to unsubscribe (default true)
function M.setup_subscriptions(subscribe)
  subscribe = subscribe == nil and true or subscribe

  if subscribe then
    rendered_session_tab = state.active_session_tab
    state.store.subscribe('is_opencode_focused', M.on_focus_changed)
    state.store.subscribe('last_focused_opencode_window', M.on_focus_changed)
    state.store.subscribe('active_session', M.on_session_changed)
    state.store.subscribe('active_session_tab', M.on_session_tab_changed)
  else
    rendered_session_tab = nil
    state.store.unsubscribe('is_opencode_focused', M.on_focus_changed)
    state.store.unsubscribe('last_focused_opencode_window', M.on_focus_changed)
    state.store.unsubscribe('active_session', M.on_session_changed)
    state.store.unsubscribe('active_session_tab', M.on_session_tab_changed)
  end
  if subscribe and state.active_session then
    M.on_session_changed(nil, state.active_session, nil)
  end
end

---@param entries table[]
---@param session? table
function M._render_full_session_data(entries, session)
  local lazy_limit = ctx.lazy_render_count
  M.reset()
  if ctx.observation then
    update_observation_stats(ctx.observation)
  end
  ctx.entries = entries or {}
  session = session or current_session()
  reference_facts.rebuild(session.id, ctx.entries, session.location)
  local visible_messages, hidden_count = get_visible_session_messages(ctx.entries, session)

  if lazy_limit == nil then
    local initial = get_initial_render_count()
    if #visible_messages > initial then
      lazy_limit = initial
    end
  end
  ctx.lazy_render_count = lazy_limit
  if lazy_limit and #visible_messages > lazy_limit then
    visible_messages = vim.list_slice(visible_messages, #visible_messages - lazy_limit + 1)
  end

  flush.begin_bulk_mode()

  if hidden_count > 0 then
    ensure_message_rendered(build_hidden_messages_notice(hidden_count))
  end

  for _, entry in ipairs(visible_messages) do
    ensure_message_rendered(entry)
  end
  flush.flush()
  flush.end_bulk_mode()
  M.scroll_to_bottom(true)

  if config.hooks and config.hooks.on_session_loaded then
    pcall(config.hooks.on_session_loaded, session)
  end

  save_active_tab_context()
end

function M.render_from_cache()
  if not output_window.mounted() or #ctx.entries == 0 then
    return
  end
  local entries = ctx.observation and ordered_entries(ctx.observation) or ctx.entries
  M._render_full_session_data(entries, current_session())
end

---Load more older messages into the output buffer.
---Called when user scrolls to the top of the output window.
---@return boolean Whether more messages were loaded
function M.load_more_messages()
  if #ctx.entries == 0 then
    return false
  end
  local total = visible_message_count()
  if total == 0 then
    return false
  end

  -- Grow within the cached window; when it is exhausted, fall through to the
  -- protocol's older page
  if apply_window_growth(window_size() + get_initial_render_count()) then
    return true
  end
  return grow_window_with_older_page()
end

---Load all remaining messages and re-render.
---Used when user explicitly navigates to the top (gg) to ensure
---the full history is available for navigation and search.
---@return boolean Whether any messages were loaded
function M.load_all_messages()
  if #ctx.entries == 0 then
    return false
  end
  local total = visible_message_count()
  if total == 0 then
    return false
  end
  -- Expand to everything cached; when the cache itself is a protocol page,
  -- the complete history is pulled and this path re-runs on the merge
  local expanded = apply_window_growth(total)
  return load_complete_history_to_top() or expanded
end

---Render the currently observed state synchronously; this does not load history.
---@return boolean rendered Whether an observation and mounted output were available
function M.render_full_session()
  if not output_window.mounted() or not ctx.observation then
    return false
  end
  reconcile_observation(ctx.observation)
  return true
end

---Flush the active tab before its window and renderer context are detached.
function M.prepare_session_tab_switch()
  if render_session then
    render_session:drain()
  end
  if ctx.bulk_mode then
    flush.end_bulk_mode()
  end
  flush.flush()
  save_active_tab_context()
end

---Replace the entire output buffer with the given lines
---@param lines string[]
function M.render_lines(lines)
  local output = require('opencode.ui.output'):new()
  output.lines = lines
  M.write_output(output)
end

---Replace the entire output buffer with formatted output data
---@param output_data Output
function M.write_output(output_data)
  if not output_window.mounted() then
    return
  end
  output_window.set_lines(output_data.lines or {})
  output_window.clear_extmarks()
  output_window.set_extmarks(output_data.extmarks)
  output_window.set_folds(output_data.fold_ranges)
  flush.trigger_on_data_rendered()
  M.scroll_to_bottom()
end

---Scroll the output window to the bottom.
---Respects the user's scroll position unless force=true or conditions allow it.
---@param force? boolean
function M.scroll_to_bottom(force)
  local windows = state.windows
  local output_win = windows and windows.output_win
  local output_buf = windows and windows.output_buf

  if not output_buf or not output_win then
    return
  end
  if not vim.api.nvim_win_is_valid(output_win) then
    return
  end
  if not state.ui.is_window_in_current_tab(output_win) then
    return
  end

  if force or config.ui.output.always_scroll_to_bottom or output_window.is_at_bottom(output_win) then
    scroll.scroll_win_to_bottom(output_win, output_buf)
  end
end

---Re-render the permission display when focus changes (updates shortcut hints)
function M.on_focus_changed()
  if ctx.observation then
    update_observation_stats(ctx.observation)
  end
  local permissions = ctx.prompt_controllers.permission
  if not permissions or not permissions.get_all_permissions()[1] then
    return
  end
  flush.mark_part_dirty('permission-display-part', 'permission-display-message')
  flush.flush()
end

---Re-render when the active session changes
function M.on_session_changed(_, new, _old)
  if state.active_session_tab ~= rendered_session_tab then
    return
  end
  local observed_session = ctx.observation and ctx.observation:read().session
  local active_observation = ctx.observation and state.session.active_observation()
  if
    render_session
    and active_observation == ctx.observation
    and observed_session
    and type(new) == 'table'
    and observed_session.id == new.id
  then
    return
  end
  detach_render_session()
  M.reset()
  if not new then
    return
  end
  local observation = state.session.active_observation()
  if not observation then
    return
  end
  ctx.observation = observation
  render_session = RenderSession.new(observation, reconcile_observation)
  render_session:attach()
  reconcile_observation(observation)
end

function M.invalidate_reference_targets_for_file_change()
  if ctx.observation then
    reconcile_observation(ctx.observation)
  end
end

---@param tab_id string
---@param runtime OpencodeSessionTabRuntime|nil
local function refresh_tab(tab_id, runtime)
  if not state.active_session then
    return
  end
  if not output_window.mounted() or not ctx.observation then
    if runtime then
      runtime.renderer_dirty = true
    end
    return
  end

  if not M.render_full_session() then
    if runtime then
      runtime.renderer_dirty = true
    end
    return
  end
  M.scroll_to_bottom(true)
  if runtime then
    runtime.renderer_dirty = false
  end
  save_tab_context(tab_id)
end

---Rebind renderer state when the selected logical panel tab changes.
function M.on_session_tab_changed(_, new, old)
  if new == old then
    return
  end
  save_tab_context(old)
  rendered_session_tab = new
  local runtime = session_tabs.get(new)
  if not output_window.mounted() then
    if runtime then
      runtime.renderer_dirty = true
    end
    return
  end
  local restored = restore_tab_context(new)
  local prompts = ctx.prompt_controllers
  if prompts.question then
    prompts.question.clear_question()
  end
  if prompts.permission then
    prompts.permission.clear_all()
  end
  require('opencode.ui.renderer.flush').flush_pending_on_data_rendered()
  M.refresh_prompts()

  if restored and not (runtime and runtime.renderer_dirty) then
    M.scroll_to_bottom(true)
    if ctx:has_pending_work() and output_window.mounted() then
      flush.schedule()
    end
    return
  end

  refresh_tab(new, runtime)
end

---Refresh a tab whose windows were mounted after the tab-change event.
function M.on_windows_mounted()
  local tab_id = state.active_session_tab
  local runtime = tab_id and session_tabs.get(tab_id)
  if not tab_id or rendered_session_tab ~= tab_id or not runtime or not state.active_session then
    return
  end

  if runtime.renderer_dirty then
    refresh_tab(tab_id, runtime)
  end
end

---Apply renderer work deferred while the output window was in another tab.
function M.resume_deferred_rendering()
  flush.flush()
  if ctx.bulk_mode then
    flush.end_bulk_mode()
    symbol_refresh.refresh()
  end
  flush.flush_pending_on_data_rendered()
end

M.reconcile_rendered_message_limit = reconcile_rendered_message_limit
M.is_message_visible = is_message_visible

---Return all actions available at a given (0-indexed) line
---@param line integer
---@return table[]
function M.get_actions_for_line(line)
  return ctx.render_state:get_actions_at_line(line)
end

---@param line integer 1-indexed
---@param col integer 0-indexed
---@param filter? fun(target: RenderedTarget): boolean
---@return RenderedTarget|nil
function M.get_target_at_position(line, col, filter)
  return ctx.render_state:get_target_at_position(line, col, filter)
end

---@param part_id string
---@param message_id string
function M.mark_part_dirty(part_id, message_id)
  flush.mark_part_dirty(part_id, message_id)
end

---Return the rendered message record for a given message ID
---@param message_id string
---@return RenderedMessage|nil
function M.get_rendered_message(message_id)
  return ctx.render_state:get_message(message_id) or nil
end

---@param message_id string
---@return integer?
local function first_jump_line(message_id)
  local best
  for _, p in pairs(ctx.render_state._parts) do
    if p.message_id == message_id and p.line_start and p.part then
      local t = p.part.kind
      if t ~= 'reasoning' and t ~= 'step_start' and t ~= 'step_finish' and p.part.synthetic ~= true then
        if not best or p.line_start < best.line_start then
          best = p
        end
      end
    end
  end
  return best and best.line_start or nil
end

-- Return a copy of `rendered` whose `line_start` points at the first content
-- part of the message (skipping reasoning/step markers/synthetic). Falls back
-- to the message header when no content part exists.
---@param rendered RenderedMessage
---@return RenderedMessage
local function with_jump_line(rendered)
  if not rendered or not rendered.message then
    return rendered
  end
  local jump_line = first_jump_line(rendered.message.id) or rendered.line_start
  return {
    message = rendered.message,
    line_start = jump_line,
    line_end = rendered.line_end,
    actions = rendered.actions,
  }
end

---@param current_line integer
---@return RenderedMessage|nil
function M.get_next_rendered_message(current_line)
  for _, message in ipairs(ctx.entries) do
    if not is_renderer_synthetic_message(message) then
      local rendered = ctx.render_state:get_message(message.id)
      if rendered and rendered.line_start then
        local jump_line = first_jump_line(message.id) or rendered.line_start
        if jump_line + 1 > current_line then
          return with_jump_line(rendered)
        end
      end
    end
  end

  return nil
end

---@param current_line integer
---@return RenderedMessage|nil
function M.get_prev_rendered_message(current_line)
  for i = #ctx.entries, 1, -1 do
    local message = ctx.entries[i]
    if message and not is_renderer_synthetic_message(message) then
      local rendered = ctx.render_state:get_message(message.id)
      if rendered and rendered.line_start then
        local jump_line = first_jump_line(message.id) or rendered.line_start
        if jump_line + 1 < current_line then
          return with_jump_line(rendered)
        end
      end
    end
  end

  return nil
end

---@param current_line integer
---@return RenderedMessage|nil
function M.get_next_user_message(current_line)
  for _, message in ipairs(ctx.entries) do
    if message.kind == 'user' then
      local rendered = ctx.render_state:get_message(message.id)
      if rendered and rendered.line_start and rendered.line_start + 1 > current_line then
        return rendered
      end
    end
  end

  return nil
end

---@param current_line integer
---@return RenderedMessage|nil
function M.get_prev_user_message(current_line)
  for i = #ctx.entries, 1, -1 do
    local message = ctx.entries[i]
    if message and message.kind == 'user' then
      local rendered = ctx.render_state:get_message(message.id)
      if rendered and rendered.line_start and rendered.line_start + 1 < current_line then
        return rendered
      end
    end
  end

  return nil
end

return M
