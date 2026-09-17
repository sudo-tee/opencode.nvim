local helpers = require('tests.helpers')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')
local config = require('opencode.config')

---Create a minimal message for testing lazy render.
---@param id string Message ID
---@param role string 'user' or 'assistant'
---@return table
local function make_message(id, role)
  return {
    id = id,
    session_id = 'ses_test',
    kind = role,
    time = { created = 1000 },
    content = {
      {
        id = id .. '_part',
        kind = 'text',
        text = 'Message ' .. id,
      },
    },
  }
end

---Create a list of N user/assistant message pairs.
---@param count integer Number of message pairs
---@return table[]
local function make_session_data(count)
  local messages = {}
  for i = 1, count do
    table.insert(messages, make_message('msg_u' .. i, 'user'))
    table.insert(messages, make_message('msg_a' .. i, 'assistant'))
  end
  return messages
end

---Count rendered real messages (excluding synthetic notices) in the render_state.
---@return integer
local function count_rendered_messages()
  local count = 0
  for _, msg in ipairs(ctx.entries) do
    local msg_id = msg.id or ''
    if msg_id:match('^__opencode_') then
      goto continue
    end
    local rendered = ctx.render_state:get_message(msg_id)
    if rendered and rendered.line_start and rendered.line_end then
      count = count + 1
    end
    ::continue::
  end
  return count
end

describe('lazy render', function()
  local renderer

  before_each(function()
    helpers.replay_setup()
    renderer = require('opencode.ui.renderer')
    state.session.set_active({ id = 'ses_test', location = { directory = helpers.MOCK_CWD } })
  end)

  after_each(function()
    ctx:reset()
    config.ui.output.max_messages = nil
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('renders V2 user text without turning internal records into extra user messages', function()
    local data = {
      {
        id = 'msg-user',
        session_id = 'ses_test',
        kind = 'user',
        time = { created = 1789387194873 },
        content = { { id = 'content-user', kind = 'text', text = '给我讲个笑话吧' } },
      },
    }
    renderer._render_full_session_data(data)
    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    assert.is_truthy(table.concat(lines, '\n'):find('给我讲个笑话吧', 1, true))
    assert.equals(1, count_rendered_messages())
    assert.is_nil(ctx.render_state:get_message('msg-switch'))
    assert.is_nil(ctx.render_state:get_message('msg-system'))
  end)

  it('truncates to lazy_render_count from the end', function()
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)

    assert.are.equal(10, count_rendered_messages())
    assert.are.equal(10, ctx.lazy_render_count)

    -- Verify it's the LAST 10 messages rendered (not the first)
    local last_msg = session_data[#session_data]
    local rendered = ctx.render_state:get_message(last_msg.id)
    assert.is_truthy(rendered and rendered.line_start, 'last message should be rendered')

    local first_msg = session_data[1]
    local not_rendered = ctx.render_state:get_message(first_msg.id)
    assert.is_falsy(not_rendered and not_rendered.line_start, 'first message should not be rendered')
  end)

  it('preserves lazy_render_count across render reset', function()
    local session_data = make_session_data(50) -- 100 messages total

    local initial_count = 10
    ctx.lazy_render_count = initial_count
    renderer._render_full_session_data(session_data)
    assert.are.equal(initial_count, count_rendered_messages())
    assert.are.equal(initial_count, ctx.lazy_render_count)

    -- Simulate load_more_messages: increment lazy_render_count
    local incremented = initial_count + 10
    ctx.lazy_render_count = incremented

    -- This render should preserve the incremented value across reset
    renderer._render_full_session_data(session_data)
    assert.are.equal(incremented, count_rendered_messages())
    assert.are.equal(
      incremented,
      ctx.lazy_render_count,
      'lazy_render_count should survive M.reset() — the original bug would clear it'
    )
  end)

  it('load_more_messages increments and re-renders', function()
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)
    assert.are.equal(10, count_rendered_messages())

    -- Simulate what load_more_messages does: increment count and re-render
    local current = ctx.lazy_render_count
    ctx.lazy_render_count = current + 10
    renderer._render_full_session_data(session_data)

    assert.are.equal(20, count_rendered_messages())
    assert.are.equal(20, ctx.lazy_render_count)

    -- When count exceeds total, all messages are rendered
    ctx.lazy_render_count = 200
    renderer._render_full_session_data(session_data)
    assert.are.equal(100, count_rendered_messages())

    -- load_more_messages returns false when all loaded
    assert.is_false(renderer.load_more_messages())
  end)

  it('load_more_messages places older messages above previously rendered ones', function()
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)

    -- Record the line position of the last message (most recent)
    local last_msg = session_data[#session_data]
    local rendered_before = ctx.render_state:get_message(last_msg.id)
    local line_end_before = rendered_before and rendered_before.line_end

    -- Simulate load_more: increment and re-render
    ctx.lazy_render_count = ctx.lazy_render_count + 10
    renderer._render_full_session_data(session_data)

    -- After loading more, the last message should have shifted down
    -- (older messages were inserted above it)
    local rendered_after = ctx.render_state:get_message(last_msg.id)
    local line_end_after = rendered_after and rendered_after.line_end

    assert.is_truthy(line_end_before, 'last message should be rendered before load')
    assert.is_truthy(line_end_after, 'last message should be rendered after load')
    assert.is_true(
      line_end_after > line_end_before,
      string.format(
        'loading more messages should shift existing messages down (was line %d, now line %d)',
        line_end_before,
        line_end_after
      )
    )
  end)

  it('load_more_messages returns false for empty session', function()
    renderer._render_full_session_data({})
    assert.is_false(renderer.load_more_messages())
  end)

  it('lazy-render does not exceed max_messages ceiling', function()
    config.ui.output.max_messages = 20
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 30
    renderer._render_full_session_data(session_data)

    -- max_messages=20 caps at 20 visible, lazy_render_count=30 can't exceed that
    local max_msgs_visible = 20
    assert.are.equal(max_msgs_visible, count_rendered_messages())
  end)

  it('unrendered messages are not in the buffer', function()
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)
    assert.are.equal(10, count_rendered_messages())

    local output_buf = state.windows and state.windows.output_buf
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
      local buf_text = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), '\n')

      -- Rendered (recent) message IS in the buffer
      assert.is_match('Message msg_u50', buf_text)

      -- Unrendered (old) message is NOT in the buffer
      assert.is_not_match('Message msg_u1', buf_text)
    end
  end)

  it('load_more_messages returns false when all messages already rendered', function()
    -- No lazy_render_count means all messages rendered — no unrendered content
    local session_data = make_session_data(50) -- 100 messages total
    renderer._render_full_session_data(session_data)

    -- lazy_render_count was set by _render_full_session_data; verify the guard
    -- After full render with a lazy limit that covers everything, load_more returns false
    ctx.lazy_render_count = 100
    assert.is_false(renderer.load_more_messages(), 'should return false when lazy_render_count covers all messages')

    -- nil means no lazy limit at all → nothing to load
    ctx.lazy_render_count = nil
    assert.is_false(renderer.load_more_messages(), 'should return false when lazy_render_count is nil')
  end)

  it('load_more_messages returns true only when unrendered messages exist', function()
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)

    -- Stub render_from_cache to avoid test-env dependency
    local stub = require('luassert.stub')
    local _rfc = stub(renderer, 'render_from_cache')

    -- 10 rendered out of 100 → has unrendered → load_more should work
    assert.is_true(renderer.load_more_messages(), 'should return true when unrendered messages exist')

    _rfc:revert()
  end)

  it('has_unrendered gates scroll-to-top load_more', function()
    -- When lazy_render_count covers all messages, scrolling to top
    -- should NOT trigger load_more. This tests the guard condition
    -- that prevents spurious loads when everything is already rendered.
    local session_data = make_session_data(50) -- 100 messages total

    -- Case 1: all rendered (lazy_render_count covers everything)
    ctx.lazy_render_count = 100
    renderer._render_full_session_data(session_data)
    assert.is_false(renderer.load_more_messages(), 'no load_more when lazy_render_count covers all messages')

    -- Case 2: partial render → load_more returns true
    local stub = require('luassert.stub')
    local _rfc = stub(renderer, 'render_from_cache')
    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)
    assert.is_true(renderer.load_more_messages(), 'load_more returns true when unrendered messages exist')
    _rfc:revert()

    -- Case 3: nil (never set) → load_more returns false
    ctx.lazy_render_count = nil
    assert.is_false(renderer.load_more_messages(), 'no load_more when lazy_render_count is nil')
  end)

  it('triggers scroll-to-top load_more from viewport top, not cursor line', function()
    local session_data = make_session_data(50) -- 100 messages total
    local output_window = require('opencode.ui.output_window')

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)

    local win = state.windows.output_win
    local buf = state.windows.output_buf
    vim.api.nvim_win_set_height(win, 15)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd('normal! zz')
    end)

    assert.are.equal(1, output_window.get_visible_top_line(win))
    assert.are.equal(5, vim.api.nvim_win_get_cursor(win)[1])

    local stub = require('luassert.stub')
    local load_more_stub = stub(renderer, 'load_more_messages').returns(false)

    vim.api.nvim_exec_autocmds('WinScrolled', {
      buffer = buf,
      modeline = false,
    })

    vim.wait(500, function()
      local ok = pcall(function()
        assert.stub(load_more_stub).was_called()
      end)
      return ok
    end)

    assert.stub(load_more_stub).was_called()
    load_more_stub:revert()
  end)

  it('restores the top viewport without moving the cursor', function()
    local session_data = make_session_data(50)

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)

    local win = state.windows.output_win
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd('normal! zz')
    end)

    local anchor = renderer.capture_top_anchor()
    vim.api.nvim_win_set_cursor(win, { 6, 0 })
    renderer.restore_top_anchor(anchor)

    assert.are.equal(6, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it('load_all_messages renders everything and makes it searchable', function()
    local session_data = make_session_data(50) -- 100 messages total

    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data)
    assert.are.equal(10, count_rendered_messages())

    -- Before load_all: old message is not in the buffer
    local output_buf = state.windows and state.windows.output_buf
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
      local buf_text = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), '\n')
      assert.is_not_match('Message msg_u1', buf_text)
    end

    -- Simulate load_all_messages (sets count to total and re-renders).
    ctx.lazy_render_count = 100
    renderer._render_full_session_data(session_data)
    assert.are.equal(100, count_rendered_messages())

    -- After load_all: old message IS in the buffer and searchable
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
      local buf_text = table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), '\n')
      assert.is_match(
        'Message msg_u1',
        buf_text,
        'after load_all_messages, all messages should be searchable in the output buffer'
      )
    end
  end)
end)

describe('renderer no debug logging', function()
  before_each(function()
    helpers.replay_setup()
    state.session.set_active({ id = 'ses_test', location = { directory = helpers.MOCK_CWD } })
  end)

  after_each(function()
    ctx:reset()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('does not emit INFO-level notifications during rendering', function()
    local mock = helpers.mock_notify()
    local renderer = require('opencode.ui.renderer')
    local session_data = make_session_data(5)

    renderer._render_full_session_data(session_data)

    vim.wait(100)

    local notifications = mock.get_notifications()
    mock.reset()

    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.INFO then
        assert.is_not_match(
          '%[render_full%]',
          n.msg,
          'DEBUG: [render_full] notification should not be emitted: ' .. n.msg
        )
        assert.is_not_match('%[e2e%]', n.msg, 'DEBUG: [e2e] notification should not be emitted: ' .. n.msg)
      end
    end
  end)
end)

describe('older history bridge', function()
  local renderer
  local session_state
  local Promise = require('opencode.promise')
  local stub = require('luassert.stub')

  before_each(function()
    helpers.replay_setup()
    renderer = require('opencode.ui.renderer')
    session_state = require('opencode.state.session')
    -- let on_session_changed from the previous test settle before stubbing
    vim.wait(100, function() return false end)
    stub(session_state, 'active_observation')
    state.session.set_active({ id = 'ses_test', location = { directory = helpers.MOCK_CWD } })
  end)

  after_each(function()
    session_state.active_observation:revert()
    ctx:reset()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  ---Observation mock mirroring the real protocol layer: the cached window
  ---lives inside the observation (entries_by_id/entry_order), and
  ---load_older merges an older page into it, the way reconcile would see.
  local function observation_with_older_page()
    local older, newer = make_session_data(5), make_session_data(20)
    local remaining_pages = 1
    local entries_by_id, entry_order = {}, {}
    local function set_entries(list)
      entries_by_id, entry_order = {}, {}
      for _, entry in ipairs(list) do
        entries_by_id[entry.id] = entry
        entry_order[#entry_order + 1] = entry.id
      end
    end
    set_entries(newer)
    local observation = {
      read = function()
        return {
          session = { id = 'ses_test' },
          sync = { session = { state = 'current' }, messages = { state = 'current' } },
          entries_by_id = entries_by_id,
          entry_order = entry_order,
          children = { order = {}, by_id = {} },
          permission_requests_by_id = {},
          question_requests_by_id = {},
          files = { revision = 0 },
        }
      end,
      watch = function()
        return function() end
      end,
      load_older = function()
        assert.is_true(remaining_pages > 0, 'load_older must not be called after history completes')
        remaining_pages = remaining_pages - 1
        local merged = {}
        vim.list_extend(merged, older)
        vim.list_extend(merged, newer)
        set_entries(merged)
        return Promise.new():resolve(nil)
      end,
      load_complete_history = function(self)
        local function pull()
          if remaining_pages <= 0 then
            return Promise.new():resolve(nil)
          end
          return self.load_older():and_then(pull)
        end
        return pull()
      end,
    }
    session_state.active_observation.returns(observation)
    return observation, older, newer, function()
      return remaining_pages
    end
  end

  it('load_all_messages pulls older protocol pages until the history is complete', function()
    local observation, older, newer, pages_left = observation_with_older_page()
    ctx.observation = observation
    ctx.entries = newer
    ctx.lazy_render_count = 5
    renderer._render_full_session_data(newer)
    assert.are.equal(5, count_rendered_messages())

    local started = renderer.load_all_messages()
    assert.is_true(started, 'load_all should start the older-page pull')
    -- the pull chain is asynchronous; drain the event loop
    assert.is_true(vim.wait(1000, function()
      return count_rendered_messages() >= #older + #newer
    end))

    assert.are.equal(0, pages_left(), 'history should be complete')
    local first = ctx.entries[1]
    assert.is_truthy(ctx.render_state:get_message(first.id).line_start, 'oldest message should be rendered')
    assert.are.equal(#older + #newer, count_rendered_messages())
  end)

  it('load_more_messages pulls an older page when the cached window is exhausted', function()
    local observation, older, newer, pages_left = observation_with_older_page()
    ctx.observation = observation
    ctx.entries = newer
    -- window already covers the whole cached page
    ctx.lazy_render_count = #newer
    renderer._render_full_session_data(newer)
    assert.are.equal(#newer, count_rendered_messages())

    local started = renderer.load_more_messages()
    assert.is_true(started, 'load_more should fall through to the protocol pull')
    assert.is_true(vim.wait(1000, function()
      return ctx.lazy_render_count > #newer
    end), 'window should grow past the exhausted cached page')

    assert.are.equal(0, pages_left(), 'history should be complete')
  end)

  it('does not grow the window when the protocol history is already complete', function()
    local newer = make_session_data(3)
    local observation = {
      read = function()
        local by_id, order = {}, {}
        for _, entry in ipairs(newer) do
          by_id[entry.id] = entry
          order[#order + 1] = entry.id
        end
        return {
          session = { id = 'ses_test' },
          sync = { session = { state = 'current' }, messages = { state = 'current' } },
          entries_by_id = by_id,
          entry_order = order,
          children = { order = {}, by_id = {} },
          permission_requests_by_id = {},
          question_requests_by_id = {},
          files = { revision = 0 },
        }
      end,
      watch = function()
        return function() end
      end,
      load_older = function()
        -- real protocols short-circuit to a no-op when history is complete
        return Promise.new():resolve(nil)
      end,
    }
    session_state.active_observation.returns(observation)
    ctx.observation = observation
    ctx.entries = newer
    ctx.lazy_render_count = #newer
    renderer._render_full_session_data(newer)

    -- no load_complete_history: the gg path never starts a protocol pull
    assert.is_false(renderer.load_all_messages())
    -- the scroll path issues the (no-op) pull; the window must not change
    assert.is_true(renderer.load_more_messages())
    assert.are.equal(#newer, ctx.lazy_render_count)
    assert.are.equal(#newer, count_rendered_messages())
    assert.is_true(vim.wait(100, function() return false end, 50) == false)
    assert.are.equal(#newer, count_rendered_messages(), 'no-op pull must not grow the window')
  end)
end)
