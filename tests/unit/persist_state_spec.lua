local state = require('opencode.state')
local store = require('opencode.state.store')
local config = require('opencode.config')
local api = require('opencode.api')
local ui = require('opencode.ui.ui')
local input_window = require('opencode.ui.input_window')
local renderer = require('opencode.ui.renderer')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

-- persist_state coverage matrix
-- +------------------+------------------------------------+-----------------------------------------------+-------------------------------+
-- | Area             | Scenario                           | Expected behavior                              | Note                          |
-- +------------------+------------------------------------+-----------------------------------------------+-------------------------------+
-- | Config default   | no user override                   | ui.persist_state defaults to true              |                               |
-- | Config opt-out   | ui.persist_state = false           | toggle fully closes; no hidden state retained  | compatibility path            |
-- | Preserve close   | close_windows(..., true)           | input/output buffers remain valid              |                               |
-- | Reopen restore   | create_windows() after hidden      | same buffer ids reused; input text unchanged   |                               |
-- | State machine    | closed -> visible -> hidden        | status/visible/hidden flags are consistent     |                               |
-- | Getter semantics | get_window_state() visible/cross-tab | side-effect free + copy + cross-tab closed   | merged case                    |
-- | Toggle E2E       | open -> hide -> reopen             | transitions valid; buffer content preserved    |                               |
-- | Output-only view | input auto-hidden, output visible  | still treated as visible for toggle decisions  | prevents false-closed path    |
-- | Non-preserve E2E | persist_state = false, then toggle | final status is closed; hidden buffers absent  | prevents snapshot leakage     |
-- | Rapid toggle     | repeated hide/restore cycles       | no state corruption; no autocmd leaks          | stress test                   |
-- | Scroll intent    | viewport scroll (trackpad/mouse)   | WinScrolled moves cursor; is_at_bottom reflects intent | PR #265 enhancement |
-- | Renderer teardown| hide then restore                  | renderer subscriptions cleaned and restored    | prevents event leaks          |
-- | Autocmd cleanup  | hide then resize window            | no "invalid window" errors from callbacks      | prevents dangling callbacks   |
-- | Config switch    | true->false->true toggle sequence  | each mode works independently                  | mode switching works          |
-- | Buffer invalid   | buffer deleted while hidden        | graceful fallback to recreate                  | defensive coding              |
-- | Multi-cycle      | 5x hide->restore cycles            | state remains consistent                       | long-term stability           |
-- | Cross-client msg | hidden state + external message    | buffer updated even when hidden                | critical bug scenario         |
-- | Promise contract | return value type check            | must be valid Promise with wait/and_then       | prevents hang                 |
-- | Non-blocking     | rapid calls without wait()         | state remains consistent                       | real user behavior            |
-- | Footer buffer    | hide and restore                   | footer buffer preserved and restored           |                               |
-- | Cursor position  | hide at line 10, restore           | cursor returns to line 10                      |                               |
-- | Topbar handling  | hide then restore                  | topbar properly hidden/shown                   | pending stronger assertion    |
-- | API function     | has_hidden_buffers exists          | function is callable and returns boolean       |                               |
-- +------------------+------------------------------------+-----------------------------------------------+-------------------------------+

describe('persist_state', function()
  local windows
  local original_config
  local code_buf
  local code_win
  local tmpfile
  local original_opencode_server_new

  local function setup_ui(opts)
    local ui_opts = vim.tbl_deep_extend('force', {
      position = 'right',
      persist_state = true,
    }, opts or {})
    config.setup({ ui = ui_opts })
    require('opencode.keymap').setup(config.keymap)
  end

  local function create_code_file(lines)
    tmpfile = vim.fn.tempname() .. '.lua'
    vim.fn.writefile(lines or { 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, tmpfile)

    code_buf = vim.fn.bufadd(tmpfile)
    vim.bo[code_buf].swapfile = false
    vim.fn.bufload(code_buf)
    vim.bo[code_buf].buflisted = true

    code_win = vim.api.nvim_open_win(code_buf, true, {
      relative = 'editor',
      width = 80,
      height = 20,
      row = 0,
      col = 0,
    })

    return code_win, code_buf
  end

  local function write_lines(buf, lines)
    pcall(vim.api.nvim_set_option_value, 'modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = buf })
  end

  local function cleanup_hidden_buffers()
    local hb = state.ui.inspect_hidden_buffers()
    if not hb then
      return
    end

    for _, buf in ipairs({ hb.input_buf, hb.output_buf, hb.footer_buf, hb.tab_strip_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    state.ui.clear_hidden_window_state()
  end

  local function cleanup_windows()
    if state.windows then
      ui.close_windows(state.windows, false)
      state.ui.set_windows(nil)
    end
  end

  local function toggle_wait(expected_status)
    local result = api.toggle(false)
    assert.is_table(result)
    assert.is_function(result.wait)
    result:wait(5000)

    if expected_status then
      assert.equals(expected_status, api.get_window_state().status)
    end

    return result
  end

  before_each(function()
    original_config = vim.deepcopy(config.values)
    state.ui.set_windows(nil)
    state.ui.clear_hidden_window_state()
    store.set('current_code_view', nil)
    store.set('current_code_buf', nil)
    store.set('last_code_win_before_opencode', nil)
    state.session.set_active(nil)

    -- Mock opencode_server to prevent spawning real process in CI
    local opencode_server = require('opencode.opencode_server')
    local observation_state = require('opencode.protocols.observation')
    original_opencode_server_new = opencode_server.new
    local mock_server = {
      url = 'http://127.0.0.1:4000',
      observations = {},
      operations = {
        list_sessions_project = function()
          return Promise.new():resolve({})
        end,
        list_sessions_global = function()
          return Promise.new():resolve({})
        end,
        create_session = function()
          return Promise.new():resolve({ id = 'persist-test-session', title = 'Persist test', time = { updated = 1 } })
        end,
        list_primary_agents = function()
          return Promise.new():resolve({ 'build' })
        end,
        get_config = function()
          return Promise.new():resolve({})
        end,
      },
      is_ready = function()
        return true
      end,
      check_health = function()
        return Promise.new():resolve(true)
      end,
      spawn = function() end,
      shutdown = function()
        return Promise.new():resolve(true)
      end,
      observe = function(self, ref)
        if self.observations[ref.id] then
          return self.observations[ref.id]
        end
        local observed = observation_state.new_state({ id = ref.id, location = ref.location })
        for resource in pairs(observed.sync) do
          observed.sync[resource] = { state = 'current' }
        end
        local observation = {
          read = function()
            return observed
          end,
          watch = function()
            return function() end
          end,
        }
        self.observations[ref.id] = observation
        return observation
      end,
      get_shutdown_promise = function()
        return Promise.new():resolve(true)
      end,
    }
    opencode_server.new = function()
      return mock_server
    end
    -- Pre-set the server to skip ensure_server
    store.set('opencode_server', mock_server)
  end)

  after_each(function()
    require('opencode.keymap').teardown()
    renderer.setup_subscriptions(false)
    cleanup_windows()
    cleanup_hidden_buffers()

    if code_win and vim.api.nvim_win_is_valid(code_win) then
      pcall(vim.api.nvim_win_close, code_win, true)
    end
    if code_buf and vim.api.nvim_buf_is_valid(code_buf) then
      pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    end
    if tmpfile then
      vim.fn.delete(tmpfile)
      tmpfile = nil
    end

    config.values = original_config
    store.set('current_code_view', nil)
    store.set('current_code_buf', nil)
    store.set('last_code_win_before_opencode', nil)
    state.ui.clear_hidden_window_state()

    -- Restore mocked opencode_server
    if original_opencode_server_new then
      local opencode_server = require('opencode.opencode_server')
      opencode_server.new = original_opencode_server_new
    end
  end)

  describe('configuration', function()
    it('applies persist_state defaults and overrides', function()
      local cases = {
        { setup = {}, expected = true },
        { setup = { ui = { persist_state = false } }, expected = false },
      }

      for _, tc in ipairs(cases) do
        config.setup(tc.setup)
        assert.equals(tc.expected, config.values.ui.persist_state)
      end
    end)
  end)

  describe('hidden buffer lifecycle', function()
    it('restores the code buffer when a current window closes after position changes', function()
      setup_ui({ position = 'current' })
      create_code_file()

      windows = ui.create_windows()
      state.ui.set_windows(windows)
      config.values.ui.position = 'right'

      ui.teardown_visible_windows(windows)

      assert.is_true(vim.api.nvim_win_is_valid(code_win))
      assert.equals(code_buf, vim.api.nvim_win_get_buf(code_win))
    end)

    it('records the mounted window position in a hidden snapshot', function()
      setup_ui({ position = 'current' })
      create_code_file()

      windows = ui.create_windows()
      state.ui.set_windows(windows)
      config.values.ui.position = 'right'

      ui.hide_visible_windows(windows)

      local hidden = state.ui.inspect_hidden_buffers()
      assert.equals('current', hidden.position)
    end)

    it('reports the hidden snapshot position after the next config position changes', function()
      setup_ui({ position = 'current' })
      create_code_file()

      windows = ui.create_windows()
      state.ui.set_windows(windows)
      ui.hide_visible_windows(windows)
      config.values.ui.position = 'right'

      local window_state = api.get_window_state()
      assert.equals('hidden', window_state.status)
      assert.equals('current', window_state.position)
    end)

    it('uses the current config position when restoring hidden buffers into new windows', function()
      setup_ui({ position = 'current' })
      create_code_file()

      windows = ui.create_windows()
      state.ui.set_windows(windows)
      config.values.ui.position = 'right'
      ui.hide_visible_windows(windows)

      assert.is_true(ui.restore_hidden_windows())
      assert.equals('right', state.windows.position)
    end)

    it('preserves and restores buffers/content, including footer', function()
      setup_ui()
      create_code_file()

      windows = ui.create_windows()
      local input_buf = windows.input_buf
      local footer_buf = windows.footer_buf
      local tab_strip_buf = windows.tab_strip_buf

      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'preserved content' })
      ui.close_windows(windows, true)

      assert.is_function(ui.has_hidden_buffers)
      assert.is_true(ui.has_hidden_buffers())
      local hidden = state.ui.inspect_hidden_buffers()
      assert.is_not_nil(hidden)
      assert.equals(footer_buf, hidden.footer_buf)
      assert.equals(tab_strip_buf, hidden.tab_strip_buf)
      assert.is_true(vim.api.nvim_buf_is_valid(input_buf))

      local restored = ui.restore_hidden_windows()
      assert.is_true(restored)
      assert.equals(input_buf, state.windows.input_buf)
      assert.equals(footer_buf, state.windows.footer_buf)
      assert.equals(tab_strip_buf, state.windows.tab_strip_buf)
      assert.is_false(ui.has_hidden_buffers())

      local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
      assert.equals('preserved content', lines[1])
    end)

    it('falls back gracefully when hidden buffer becomes invalid', function()
      setup_ui()
      create_code_file()

      windows = ui.create_windows()
      ui.close_windows(windows, true)
      assert.is_true(ui.has_hidden_buffers())

      local hidden = state.ui.inspect_hidden_buffers()
      local invalid_buf = hidden and hidden.input_buf
      if invalid_buf and vim.api.nvim_buf_is_valid(invalid_buf) then
        vim.api.nvim_buf_delete(invalid_buf, { force = true })
      end

      local restored = ui.restore_hidden_windows()
      assert.is_false(restored)

      local recreated = ui.create_windows()
      assert.is_true(vim.api.nvim_buf_is_valid(recreated.input_buf))
      windows = recreated
    end)
  end)

  describe('window state and toggle semantics', function()
    it('transitions closed -> visible -> hidden -> visible with persist_state=true', function()
      setup_ui()

      local initial = api.get_window_state()
      assert.equals('closed', initial.status)

      create_code_file()
      toggle_wait('visible')
      toggle_wait('hidden')
      toggle_wait('visible')
    end)

    it('restores missing base mappings without replacing preserved mappings', function()
      setup_ui()
      config.keymap.output_window.a = { function() end, desc = 'Base A' }
      create_code_file()
      toggle_wait('visible')

      local output_buf = state.windows.output_buf
      local contextual_actions = require('opencode.ui.contextual_actions')
      contextual_actions.show_contextual_actions_menu(output_buf, {
        { key = 'a', text = 'Temporary A', display_line = 0 },
      }, vim.api.nvim_create_namespace('persist-state-mapping-test'))

      local function mapping_description(lhs)
        for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(output_buf, 'n')) do
          if mapping.lhs == lhs then
            return mapping.desc
          end
        end
      end

      assert.equals('Temporary A', mapping_description('a'))
      toggle_wait('hidden')
      assert.equals('Base A', mapping_description('a'))

      toggle_wait('visible')
      assert.equals('Base A', mapping_description('a'))
    end)

    it('fully closes when persist_state=false', function()
      setup_ui({ persist_state = false })
      create_code_file()

      toggle_wait('visible')
      toggle_wait('closed')
      assert.is_false(ui.has_hidden_buffers())
    end)

    it('handles persist_state true -> false -> true switching sequence', function()
      setup_ui({ persist_state = true })
      create_code_file()

      toggle_wait('visible')
      toggle_wait('hidden')
      assert.is_true(ui.has_hidden_buffers())

      config.values.ui.persist_state = false
      toggle_wait('closed')
      assert.is_false(ui.has_hidden_buffers())

      toggle_wait('visible')
      config.values.ui.persist_state = true
      toggle_wait('hidden')
      assert.is_true(ui.has_hidden_buffers())
    end)

    it('closes old windows when toggling from another tab', function()
      setup_ui()
      create_code_file()
      toggle_wait('visible')

      local original_input_win = state.windows.input_win
      local original_output_win = state.windows.output_win
      assert.is_true(vim.api.nvim_win_is_valid(original_input_win))
      assert.is_true(vim.api.nvim_win_is_valid(original_output_win))

      vim.cmd('tabnew')
      create_code_file()
      toggle_wait('visible')

      assert.is_false(vim.api.nvim_win_is_valid(original_input_win))
      assert.is_false(vim.api.nvim_win_is_valid(original_output_win))
      assert.is_true(vim.api.nvim_win_is_valid(state.windows.input_win))
      assert.equals(vim.api.nvim_get_current_tabpage(), vim.api.nvim_win_get_tabpage(state.windows.input_win))

      vim.cmd('tabclose')
    end)
  end)

  describe('toggle promise contract', function()
    it('keeps promise behavior stable across contract scenarios', function()
      setup_ui()
      create_code_file()

      local scenarios = {
        {
          name = 'thenable',
          run = function()
            local result = api.toggle(false)
            assert.is_table(result)
            assert.is_function(result.wait)
            assert.is_function(result.and_then)
            assert.is_function(result.catch)

            local ok = pcall(function()
              result:wait(5000)
            end)
            assert.is_true(ok)
          end,
        },
        {
          name = 'rapid_non_blocking',
          run = function()
            local results = {}
            for i = 1, 5 do
              results[i] = api.toggle(false)
              vim.wait(10)
            end

            vim.wait(2000, function()
              for _, p in ipairs(results) do
                if p and not p:is_resolved() then
                  return false
                end
              end
              return true
            end, 50)

            for i, p in ipairs(results) do
              assert.is_true(p:is_resolved(), 'Promise ' .. i .. ' should resolve')
            end

            local final = api.get_window_state().status
            assert.is_true(final == 'visible' or final == 'hidden')
          end,
        },
        {
          name = 'invalid_state_settles',
          run = function()
            cleanup_windows()
            state.ui.set_windows({ input_win = 99999 })

            local settled = false
            local p = api.toggle(false)
            p:and_then(function()
              settled = true
            end):catch(function()
              settled = true
            end)

            vim.wait(1000, function()
              return settled
            end, 50)

            assert.is_true(settled)
            state.ui.set_windows(nil)
          end,
        },
      }

      for _, scenario in ipairs(scenarios) do
        scenario.run()
      end
    end)
  end)

  describe('content, cursor, focus and zoom persistence', function()
    it('returns window copy, and is tab-safe', function()
      setup_ui()
      create_code_file()
      toggle_wait('visible')

      vim.wait(100)

      local snapshot = api.get_window_state()

      assert.equals('visible', snapshot.status)
      local original_input_win = state.windows.input_win
      assert.is_not_nil(snapshot.windows)
      snapshot.windows.input_win = -1
      assert.equals(original_input_win, state.windows.input_win)

      vim.cmd('tabnew')
      local other_tab_snapshot = api.get_window_state()
      vim.cmd('tabclose')

      assert.equals('closed', other_tab_snapshot.status)
      assert.is_nil(other_tab_snapshot.windows)
    end)

    it('preserves restore behavior across content, cursor, and hidden-input scenarios', function()
      local scenarios = {
        {
          name = 'content_reuse',
          setup = function()
            local input_buf = state.windows.input_buf
            vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'test content' })
            return { input_buf = input_buf }
          end,
          assert_after = function(ctx)
            assert.is_true(vim.api.nvim_buf_is_valid(ctx.input_buf))
            assert.equals(ctx.input_buf, state.windows.input_buf)
            local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
            assert.equals('test content', lines[1])
          end,
        },
        {
          name = 'hidden_input_output_focus',
          setup = function()
            local output_lines = {}
            for i = 1, 120 do
              output_lines[i] = 'h' .. i
            end
            write_lines(state.windows.output_buf, output_lines)

            input_window._hide()
            vim.wait(50)
            assert.is_true(input_window.is_hidden())

            vim.api.nvim_set_current_win(state.windows.output_win)
            vim.api.nvim_win_set_cursor(state.windows.output_win, { 35, 0 })
          end,
          assert_after = function(_)
            assert.equals(state.windows.output_win, vim.api.nvim_get_current_win())
            assert.is_true(input_window.is_hidden())
            local pos = vim.api.nvim_win_get_cursor(state.windows.output_win)
            assert.equals(35, pos[1])
          end,
        },
        {
          name = 'cursor_input',
          setup = function()
            vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, { 'i1', 'i2', 'i3' })
            vim.api.nvim_set_current_win(state.windows.input_win)
            vim.api.nvim_win_set_cursor(state.windows.input_win, { 2, 1 })
            return {
              expected_win_fn = function()
                return state.windows.input_win
              end,
              expected_cursor = { 2, 1 },
            }
          end,
          assert_after = function(ctx)
            assert.equals(ctx.expected_win_fn(), vim.api.nvim_get_current_win())
            vim.wait(200, function()
              local pos = vim.api.nvim_win_get_cursor(ctx.expected_win_fn())
              return pos[1] == ctx.expected_cursor[1] and pos[2] == ctx.expected_cursor[2]
            end, 10)
            local pos = vim.api.nvim_win_get_cursor(ctx.expected_win_fn())
            assert.equals(ctx.expected_cursor[1], pos[1])
            assert.equals(ctx.expected_cursor[2], pos[2])
          end,
        },
        {
          name = 'zoom_width',
          setup = function()
            config.values.ui.window_width = 0.4
            config.values.ui.zoom_width = 0.8
            local normal_width = vim.api.nvim_win_get_width(state.windows.output_win)
            ui.toggle_zoom()
            local expected_zoom_width = math.floor(config.ui.zoom_width * vim.o.columns)
            local zoomed_width = vim.api.nvim_win_get_width(state.windows.output_win)
            assert.equals(expected_zoom_width, zoomed_width)
            assert.is_not_nil(state.pre_zoom_width)
            return { normal_width = normal_width, expected_zoom_width = expected_zoom_width }
          end,
          assert_after = function(ctx)
            local restored_width = vim.api.nvim_win_get_width(state.windows.output_win)
            assert.equals(ctx.expected_zoom_width, restored_width)
            assert.is_not_nil(state.pre_zoom_width)
            ui.toggle_zoom()
            local unzoomed_width = vim.api.nvim_win_get_width(state.windows.output_win)
            assert.equals(ctx.normal_width, unzoomed_width)
            assert.is_nil(state.pre_zoom_width)
          end,
        },
      }

      for _, scenario in ipairs(scenarios) do
        setup_ui()
        create_code_file()
        toggle_wait('visible')

        local ctx = scenario.setup() or {}
        toggle_wait('hidden')
        toggle_wait('visible')
        scenario.assert_after(ctx)

        cleanup_windows()
      end
    end)
  end)

  describe('longer toggle stability', function()
    it('keeps state consistent across repeated hide/restore cycles', function()
      setup_ui()
      create_code_file()
      toggle_wait('visible')

      local original_input_buf = state.windows.input_buf
      for i = 1, 10 do
        local expected = (i % 2 == 1) and 'hidden' or 'visible'
        toggle_wait(expected)
      end

      assert.equals('visible', api.get_window_state().status)
      assert.is_true(vim.api.nvim_buf_is_valid(original_input_buf))

      for _ = 1, 5 do
        toggle_wait('hidden')
        assert.is_true(ui.has_hidden_buffers())
        toggle_wait('visible')
        assert.equals('visible', api.get_window_state().status)
      end
    end)
  end)
end)
