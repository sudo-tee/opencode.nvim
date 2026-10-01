local session_picker = require('opencode.ui.session_picker')
local session_runtime = require('opencode.services.session_runtime')
local state = require('opencode.state')
local store = require('opencode.state.store')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')
local support = require('tests.unit.services_spec_support')

describe('opencode.ui.session_picker', function()
  describe('preview_fn contract', function()
    local original
    local original_pick
    local connection

    local function set_entries(entries)
      local observation = connection:observe({ id = 's1' })
      observation._state.entries_by_id = {}
      observation._state.entry_order = {}
      for _, entry in ipairs(entries) do
        observation._state.entries_by_id[entry.id] = entry
        observation._state.entry_order[#observation._state.entry_order + 1] = entry.id
      end
      observation._state.sync.messages = { state = 'current' }
      observation.watch = function(self, _, changed)
        changed(self)
        return function() end
      end
    end

    before_each(function()
      original = support.snapshot_state()
      connection = support.mock_connection()
      local base_picker = require('opencode.ui.base_picker')
      original_pick = base_picker.pick
    end)

    after_each(function()
      support.restore_state(original)
      require('opencode.ui.base_picker').pick = original_pick
    end)

    it('writes through the backend-neutral preview target', function()
      local base_picker = require('opencode.ui.base_picker')
      local captured_opts
      base_picker.pick = function(opts)
        captured_opts = opts
        return true
      end

      set_entries({})

      session_picker.pick({ { id = 's1', title = 'Session', time = { updated = 'now' } } }, function() end)
      assert.is_table(captured_opts)

      local writes = {}
      local target = {
        get_bufnr = function()
          return nil
        end,
        is_valid = function()
          return true
        end,
        set_lines = function(_, lines)
          writes[#writes + 1] = lines
        end,
        with_window = function() end,
      }

      captured_opts.preview_fn({ id = 's1' }, target)
      vim.wait(100, function()
        return #writes >= 2
      end)

      assert.are.same({ 'Loading...' }, writes[1])
      assert.are.same({ 'No messages' }, writes[2])
    end)

    it('renders loaded messages before releasing the observation state', function()
      local lifecycle = require('opencode.protocols.observation')
      local request = Promise.new()
      local ref = { id = 's1' }
      local observation = lifecycle.attach(connection, ref, lifecycle.new_state(ref), {
        name = 'preview-test',
        stream_resource = function()
          return false
        end,
        request_resource = function()
          return request
        end,
        apply_resource = function(observed, _, entries)
          observed:read().entry_order = { entries[1].id }
          observed:read().entries_by_id = { [entries[1].id] = entries[1] }
        end,
      })
      connection.observations.s1 = observation
      local captured_opts
      require('opencode.ui.base_picker').pick = function(opts)
        captured_opts = opts
        return true
      end
      session_picker.pick({ ref }, function() end)

      local bufnr = vim.api.nvim_create_buf(false, true)
      local writes = {}
      local target = {
        get_bufnr = function()
          return bufnr
        end,
        is_valid = function()
          return true
        end,
        set_lines = function(_, lines)
          writes[#writes + 1] = lines
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        end,
        with_window = function() end,
      }
      captured_opts.preview_fn(ref, target)
      request:resolve({
        {
          id = 'msg_1',
          kind = 'assistant',
          session_id = 's1',
          content = { { id = 'part_1', kind = 'text', text = 'Loaded preview message' } },
        },
      })
      vim.wait(1000, function()
        return #writes >= 2
      end)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

      assert.is_truthy(table.concat(writes[#writes], '\n'):find('Loaded preview message', 1, true))
      assert.same({}, observation:read().entry_order)
      assert.is_nil(connection.observations.s1)
    end)

    it('formats preview parts with non-interactive formatter context', function()
      local base_picker = require('opencode.ui.base_picker')
      local formatter = require('opencode.ui.formatter')
      local Output = require('opencode.ui.output')
      local captured_opts
      local contexts = {}
      local format_stub = stub(formatter, 'format_part').invokes(function(_, _, _, context)
        contexts[#contexts + 1] = context
        local output = Output.new()
        output:add_line('preview part')
        return output
      end)

      base_picker.pick = function(opts)
        captured_opts = opts
        return true
      end

      set_entries({
        {
          id = 'msg_1',
          kind = 'assistant',
          session_id = 'ses_1',
          content = {
            { id = 'part_1', kind = 'text', text = 'See `src/main.lua`.' },
          },
        },
      })

      session_picker.pick({ { id = 's1', title = 'Session', time = { updated = 'now' } } }, function() end)

      local target = {
        get_bufnr = function()
          return nil
        end,
        is_valid = function()
          return true
        end,
        set_lines = function() end,
        with_window = function() end,
      }

      captured_opts.preview_fn({ id = 's1' }, target)
      vim.wait(100, function()
        return #contexts == 1
      end)

      format_stub:revert()

      assert.equal(1, #contexts)
      assert.is_false(contexts[1].interactive)
      assert.is_nil(contexts[1].get_child_parts)
      assert.is_nil(contexts[1].symbol_cycle)
    end)

    it('does not resolve rendered targets while formatting preview parts', function()
      local base_picker = require('opencode.ui.base_picker')
      local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
      local captured_opts
      local writes = {}
      local bufnr = vim.api.nvim_create_buf(false, true)

      package.loaded['opencode.ui.symbol_snapshot'] = {
        new_cycle = function()
          error('preview formatting must not create a symbol cycle')
        end,
        targets_for_token = function()
          error('preview formatting must not resolve symbol targets')
        end,
      }

      base_picker.pick = function(opts)
        captured_opts = opts
        return true
      end

      set_entries({
        {
          id = 'msg_1',
          kind = 'assistant',
          session_id = 'ses_1',
          content = {
            { id = 'part_1', kind = 'text', text = 'See `src/main.lua` then call foo.' },
          },
        },
      })

      session_picker.pick({ { id = 's1', title = 'Session', time = { updated = 'now' } } }, function() end)

      local target = {
        get_bufnr = function()
          return bufnr
        end,
        is_valid = function()
          return true
        end,
        set_lines = function(_, lines)
          writes[#writes + 1] = lines
        end,
        with_window = function(_, fn)
          fn()
        end,
      }

      captured_opts.preview_fn({ id = 's1' }, target)
      vim.wait(100, function()
        return #writes >= 2
      end)

      package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

      assert.is_truthy(table.concat(writes[#writes], '\n'):find('src/main.lua', 1, true))
      assert.is_nil(table.concat(writes[#writes], '\n'):find('%[render error%]'))
    end)
  end)

  describe('delete action – session switch on ancestor deletion', function()
    local original
    local switch_stub
    local connection

    local root_session = { id = 'root', parentID = nil, title = 'Root', time = { updated = '2024-01-01' } }
    local other_root = { id = 'other-root', parentID = nil, title = 'Other', time = { updated = '2024-01-01' } }
    local child_session = { id = 'child', parentID = 'root', title = 'Child', time = { updated = '2024-01-01' } }
    local grandchild_session =
      { id = 'grandchild', parentID = 'child', title = 'Grandchild', time = { updated = '2024-01-01' } }

    before_each(function()
      original = support.snapshot_state()

      vim.schedule = function(fn)
        fn()
      end

      connection = support.mock_connection()
      connection.operations.delete_session = function(_, _id)
        return Promise.new():resolve(true)
      end

      stub(session_runtime, 'list_sessions_by_scope').invokes(function()
        return Promise.new():resolve({ root_session, other_root, child_session, grandchild_session })
      end)

      switch_stub = stub(require('opencode.services.session_runtime'), 'select_session').invokes(function(_id)
        return Promise.new():resolve(true)
      end)
    end)

    after_each(function()
      support.restore_state(original)
      if session_runtime.list_sessions_by_scope.revert then
        session_runtime.list_sessions_by_scope:revert()
      end
      if require('opencode.services.session_runtime').select_session.revert then
        require('opencode.services.session_runtime').select_session:revert()
      end
    end)

    local function picker_actions()
      local captured
      local base_picker = require('opencode.ui.base_picker')
      local orig_pick = base_picker.pick
      base_picker.pick = function(opts)
        captured = opts.actions
        return true
      end
      session_picker.pick({ root_session, other_root }, function() end, { scope = 'project' })
      base_picker.pick = orig_pick
      return captured
    end

    local function run_delete(active, items_in_picker, sessions_to_delete)
      state.session.set_active(active)
      local opts = { items = vim.deepcopy(items_in_picker) }
      picker_actions().delete.fn(sessions_to_delete, opts):wait()
    end

    it('keeps successful deletions reflected in the picker when a later deletion fails', function()
      state.session.set_active(nil)
      local deleted = {}
      connection.operations.delete_session = function(_, id)
        deleted[#deleted + 1] = id
        if id == other_root.id then
          return Promise.new():reject('delete failed')
        end
        return Promise.new():resolve(true)
      end
      local opts = { items = { root_session, other_root } }
      local ok = pcall(function()
        picker_actions().delete.fn({ root_session, other_root }, opts):wait()
      end)
      assert.is_false(ok)
      assert.same({ 'root', 'other-root' }, deleted)
      assert.same({ other_root }, opts.items)
    end)

    it('renames through the service without invoking command hooks', function()
      local config = require('opencode.config')
      local original_hooks = config.hooks
      local events = {}
      config.hooks = {
        on_command_before = function(ctx)
          events[#events + 1] = ctx.intent.name
        end,
      }
      connection.operations.rename_session = function(_, id, _, title)
        assert.equals('root', id)
        assert.equals('Renamed', title)
        return Promise.new():resolve(true)
      end
      local input_stub = stub(vim.ui, 'input').invokes(function(_, callback)
        callback('Renamed')
      end)
      local opts = { items = { root_session } }
      local ok, result = pcall(function()
        return picker_actions().rename.fn(root_session, opts):wait()
      end)
      input_stub:revert()
      config.hooks = original_hooks
      assert.is_true(ok, tostring(result))
      assert.same({}, events)
      assert.equals('Renamed', result[1].title)
      assert.equals('Root', root_session.title)
    end)

    it('leaves the picker unchanged when renaming is cancelled or fails', function()
      local requested_title
      local calls = 0
      connection.operations.rename_session = function()
        calls = calls + 1
        return Promise.new():reject('rename failed')
      end
      local input_stub = stub(vim.ui, 'input').invokes(function(_, callback)
        callback(requested_title)
      end)
      local opts = { items = { root_session } }
      local action = picker_actions().rename.fn
      local ok, err = pcall(function()
        assert.is_nil(action(root_session, opts):wait())
        assert.equals(0, calls)
        requested_title = 'Renamed'
        assert.is_nil(action(root_session, opts):wait())
        assert.equals(1, calls)
        assert.equals('Root', opts.items[1].title)
      end)
      input_stub:revert()
      assert.is_true(ok, tostring(err))
    end)

    it('preserves command lifecycle hooks for API renames', function()
      local config = require('opencode.config')
      local original_hooks = config.hooks
      local events = {}
      config.hooks = {
        on_command_before = function(ctx)
          events[#events + 1] = 'before:' .. ctx.intent.name
        end,
        on_command_after = function(ctx)
          events[#events + 1] = 'after:' .. ctx.intent.name
        end,
      }
      connection.operations.rename_session = function()
        return Promise.new():resolve(true)
      end
      local ok, result = pcall(function()
        return require('opencode.api').rename_session(root_session, 'Renamed'):wait()
      end)
      config.hooks = original_hooks
      assert.is_true(ok, tostring(result))
      assert.same({ 'before:rename_session', 'after:rename_session' }, events)
      assert.equals('Renamed', result.title)
      assert.equals('Root', root_session.title)
    end)

    it('switches session when the active session direct parent is deleted', function()
      run_delete(child_session, { root_session, other_root }, root_session)

      assert.stub(switch_stub).was_called()
      local called_with = switch_stub.calls[1].vals[1]
      assert.equals('other-root', called_with.id)
    end)

    it('switches session when active session grandparent is deleted', function()
      run_delete(grandchild_session, { root_session, other_root }, root_session)

      assert.stub(switch_stub).was_called()
      local called_with = switch_stub.calls[1].vals[1]
      assert.equals('other-root', called_with.id)
    end)

    it('does NOT switch session when an unrelated root is deleted', function()
      run_delete(child_session, { root_session, other_root }, other_root)

      assert.stub(switch_stub).was_not_called()
    end)

    it('resets agent mode when all sessions are deleted and a new session is created', function()
      local agent_model = require('opencode.services.agent_model')
      local store = require('opencode.state.store')

      store.set('current_mode', 'explore')

      local ensure_stub = stub(agent_model, 'ensure_current_mode').invokes(function()
        store.set('current_mode', 'default')
        return Promise.new():resolve(true)
      end)

      run_delete(child_session, { root_session }, root_session)

      assert.stub(switch_stub).was_not_called()
      assert.stub(ensure_stub).was_called()
      assert.equals('default', state.current_mode)

      ensure_stub:revert()
    end)
  end)
end)
