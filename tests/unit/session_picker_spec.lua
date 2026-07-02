-- tests/unit/session_picker_spec.lua
-- Tests for session_picker helpers and delete action behaviour

local session_picker = require('opencode.ui.session_picker')
local session_mod = require('opencode.session')
local session_runtime = require('opencode.services.session_runtime')
local state = require('opencode.state')
local store = require('opencode.state.store')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')
local support = require('tests.unit.services_spec_support')

describe('opencode.ui.session_picker', function()
  -- -----------------------------------------------------------------------
  -- Pure unit tests for the helper – no mocks needed
  -- -----------------------------------------------------------------------
  describe('_is_session_or_ancestor_deleted', function()
    local root = { id = 'root', parentID = nil }
    local child = { id = 'child', parentID = 'root' }
    local grandchild = { id = 'grandchild', parentID = 'child' }
    local unrelated = { id = 'unrelated', parentID = nil }
    local all_sessions = { root, child, grandchild, unrelated }

    it('returns true when the session itself is in the delete set', function()
      assert.is_true(session_picker._is_session_or_ancestor_deleted('child', { child = true }, all_sessions))
    end)

    it('returns true when the direct parent is in the delete set', function()
      assert.is_true(session_picker._is_session_or_ancestor_deleted('child', { root = true }, all_sessions))
    end)

    it('returns true when a grandparent is in the delete set', function()
      assert.is_true(session_picker._is_session_or_ancestor_deleted('grandchild', { root = true }, all_sessions))
    end)

    it('returns false when an unrelated session is deleted', function()
      assert.is_false(session_picker._is_session_or_ancestor_deleted('child', { unrelated = true }, all_sessions))
    end)

    it('returns false when only a sibling is deleted', function()
      local sibling = { id = 'sibling', parentID = 'root' }
      assert.is_false(
        session_picker._is_session_or_ancestor_deleted(
          'child',
          { sibling = true },
          { root, child, sibling, grandchild }
        )
      )
    end)

    it('returns false for a root session when an unrelated root is deleted', function()
      assert.is_false(session_picker._is_session_or_ancestor_deleted('root', { unrelated = true }, all_sessions))
    end)

    it('returns true for root session when root itself is deleted', function()
      assert.is_true(session_picker._is_session_or_ancestor_deleted('root', { root = true }, all_sessions))
    end)
  end)

  describe('preview_fn contract', function()
    local original_api_client
    local original_pick

    before_each(function()
      original_api_client = state.api_client
      local base_picker = require('opencode.ui.base_picker')
      original_pick = base_picker.pick
    end)

    after_each(function()
      state.jobs.set_api_client(original_api_client)
      require('opencode.ui.base_picker').pick = original_pick
    end)

    it('writes through the backend-neutral preview target', function()
      local base_picker = require('opencode.ui.base_picker')
      local captured_opts
      base_picker.pick = function(opts)
        captured_opts = opts
        return true
      end

      state.jobs.set_api_client({
        list_messages = function()
          return Promise.new():resolve({})
        end,
      })

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
      assert.are.same({ 'No messages or failed to load' }, writes[2])
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

      state.jobs.set_api_client({
        list_messages = function()
          return Promise.new():resolve({
            {
              info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' },
              parts = {
                { id = 'part_1', type = 'text', text = 'See `src/main.lua`.' },
              },
            },
          })
        end,
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

      state.jobs.set_api_client({
        list_messages = function()
          return Promise.new():resolve({
            {
              info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' },
              parts = {
                { id = 'part_1', type = 'text', text = 'See `src/main.lua` then call foo.' },
              },
            },
          })
        end,
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

  -- -----------------------------------------------------------------------
  -- Integration tests: delete action triggers switch when parent/grandparent
  -- of the active session is deleted
  -- -----------------------------------------------------------------------
  describe('delete action – session switch on ancestor deletion', function()
    local original
    local switch_stub

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

      support.mock_api_client()

      -- Stub delete_session on the api_client so it doesn't error
      state.api_client.delete_session = function(_, _id)
        return Promise.new():resolve(true)
      end

      -- Stub get_all_workspace_sessions to return our fixture tree
      stub(session_mod, 'get_all_workspace_sessions').invokes(function()
        return Promise.new():resolve({ root_session, other_root, child_session, grandchild_session })
      end)

      -- Stub switch_session so we can assert it was called
      switch_stub = stub(session_runtime, 'switch_session').invokes(function(_id)
        return Promise.new():resolve(true)
      end)
    end)

    after_each(function()
      support.restore_state(original)
      if session_mod.get_all_workspace_sessions.revert then
        session_mod.get_all_workspace_sessions:revert()
      end
      if session_runtime.switch_session.revert then
        session_runtime.switch_session:revert()
      end
    end)

    -- Helper: build a minimal opts table with items and invoke the delete fn
    local function run_delete(active, items_in_picker, sessions_to_delete)
      state.session.set_active(active)

      -- Extract the delete action fn from the picker actions by opening a
      -- dummy picker and grabbing the action directly from the module.
      -- Because `pick()` closes over the actions, we re-create them here
      -- by invoking the delete fn directly through a fake opts table.
      local delete_fn = nil
      -- Monkey-patch base_picker.pick to capture the actions
      local base_picker = require('opencode.ui.base_picker')
      local orig_pick = base_picker.pick
      base_picker.pick = function(opts)
        -- grab delete fn from the actions passed in
        delete_fn = opts.actions.delete.fn
      end
      session_picker.pick(items_in_picker, function() end)
      base_picker.pick = orig_pick

      assert.truthy(delete_fn, 'delete fn should have been captured')

      local opts = { items = vim.deepcopy(items_in_picker) }
      delete_fn(sessions_to_delete, opts):wait()
    end

    it('switches session when the active session direct parent is deleted', function()
      -- Active = child, deleting root (parent of child), other_root remains
      run_delete(child_session, { root_session, other_root }, root_session)

      assert.stub(switch_stub).was_called()
      local called_with = switch_stub.calls[1].vals[1]
      assert.equals('other-root', called_with)
    end)

    it('switches session when active session grandparent is deleted', function()
      -- Active = grandchild, deleting root (grandparent), other_root remains
      run_delete(grandchild_session, { root_session, other_root }, root_session)

      assert.stub(switch_stub).was_called()
      local called_with = switch_stub.calls[1].vals[1]
      assert.equals('other-root', called_with)
    end)

    it('does NOT switch session when an unrelated root is deleted', function()
      -- Active = child (parentID=root), deleting other_root (unrelated)
      run_delete(child_session, { root_session, other_root }, other_root)

      assert.stub(switch_stub).was_not_called()
    end)

    it('resets agent mode when all sessions are deleted and a new session is created', function()
      local agent_model = require('opencode.services.agent_model')
      local store = require('opencode.state.store')

      -- Simulate being stuck in a subagent mode (e.g. EXPLORE)
      store.set('current_mode', 'explore')

      -- Stub ensure_current_mode to clear the mode (simulating default reset)
      local ensure_stub = stub(agent_model, 'ensure_current_mode').invokes(function()
        store.set('current_mode', 'default')
        return Promise.new():resolve(true)
      end)

      -- Active = child session, only session in the picker is root (which is being deleted)
      -- No remaining sessions after deletion
      run_delete(child_session, { root_session }, root_session)

      assert.stub(switch_stub).was_not_called()
      assert.stub(ensure_stub).was_called()
      assert.equals('default', state.current_mode)

      ensure_stub:revert()
    end)
  end)
end)
