local assert = require('luassert')
local stub = require('luassert.stub')

describe('opencode.ui.reference_facts', function()
  local reference_facts
  local original_fn
  local original_api

  local function assistant_message(id, session_id, parts)
    return {
      info = { id = id, role = 'assistant', sessionID = session_id },
      parts = parts or {},
    }
  end

  before_each(function()
    original_fn = vim.fn
    original_api = vim.api

    vim.fn = vim.tbl_extend('force', vim.fn or {}, {
      getcwd = function()
        return '/repo'
      end,
      filereadable = function(path)
        return (path == '/repo/src/ok.lua' or path == '/repo/src/tool.lua') and 1 or 0
      end,
      fnamemodify = function(path, modifier)
        if modifier == ':~:.' then
          return path:gsub('^/repo/', '')
        end
        return path
      end,
    })

    package.loaded['opencode.ui.reference_facts'] = nil
    package.loaded['opencode.ui.reference_parser'] = nil
    reference_facts = require('opencode.ui.reference_facts')
  end)

  after_each(function()
    reference_facts.clear()
    vim.fn = original_fn
    vim.api = original_api
    package.loaded['opencode.ui.reference_facts'] = nil
    package.loaded['opencode.ui.reference_parser'] = nil
  end)

  it('owns session facts without loading the picker UI', function()
    package.loaded['opencode.ui.reference_picker'] = false

    assert.has_no.errors(function()
      reference_facts.rebuild('ses_1', {
        assistant_message('msg_1', 'ses_1', {
          { id = 'part_1', type = 'text', text = 'See `src/ok.lua`.' },
        }),
      })
    end)

    package.loaded['opencode.ui.reference_picker'] = nil
    assert.equal('src/ok.lua', reference_facts.current_refs()[1].path)
  end)

  it('rebuilds current session assistant reference facts only', function()
    reference_facts.rebuild('ses_1', {
      {
        info = { id = 'user_1', role = 'user', sessionID = 'ses_1' },
        parts = { { id = 'user_part', type = 'text', text = 'Ignore `src/user.lua`.' } },
      },
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', type = 'text', text = 'See `src/ok.lua:12:3`.' },
        { id = 'part_2', type = 'tool', state = { input = { filePath = '/repo/src/tool.lua' } } },
      }),
      assistant_message('msg_2', 'ses_other', {
        { id = 'part_other', type = 'text', text = 'Ignore `src/other.lua`.' },
      }),
    })

    local refs = reference_facts.current_refs()

    assert.equal(2, #refs)
    assert.equal('src/ok.lua', refs[1].path)
    assert.equal(12, refs[1].line)
    assert.equal(3, refs[1].col)
    assert.equal('assistant_text', refs[1].source_kind)
    assert.are.same({ start_offset = 5, end_offset = 21 }, refs[1].raw_range)
    assert.equal('src/tool.lua', refs[2].path)
    assert.equal('tool_file_path', refs[2].source_kind)
  end)

  it('replace_part replaces old refs for the same part', function()
    local message = assistant_message('msg_1', 'ses_1', {
      { id = 'part_1', type = 'text', text = 'See `src/ok.lua`.' },
    })
    reference_facts.rebuild('ses_1', { message })

    message.parts[1] = { id = 'part_1', type = 'text', text = 'See `src/loaded.lua`.' }
    local changed = reference_facts.replace_part('ses_1', message, message.parts[1])
    local refs = reference_facts.current_refs()

    assert.is_true(changed)
    assert.equal(1, #refs)
    assert.equal('src/loaded.lua', refs[1].path)
  end)

  it('replace_part keeps same-key append facts and adds new refs', function()
    local message = assistant_message('msg_1', 'ses_1', {
      { id = 'part_1', type = 'text', text = 'See `src/ok.lua`.' },
    })
    reference_facts.rebuild('ses_1', { message })
    local first_range = reference_facts.current_refs()[1].raw_range

    message.parts[1] = { id = 'part_1', type = 'text', text = 'See `src/ok.lua`. Also `src/loaded.lua`.' }
    local changed = reference_facts.replace_part('ses_1', message, message.parts[1])
    local refs = reference_facts.current_refs()

    assert.is_true(changed)
    assert.equal(2, #refs)
    assert.equal('src/ok.lua', refs[1].path)
    assert.are.same(first_range, refs[1].raw_range)
    assert.equal('src/loaded.lua', refs[2].path)
  end)

  it('keeps duplicate path and line facts from different source parts and messages in session order', function()
    reference_facts.rebuild('ses_1', {
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', type = 'text', text = 'First `src/ok.lua:12`.' },
        { id = 'part_2', type = 'text', text = 'Second `src/ok.lua:12`.' },
      }),
      assistant_message('msg_2', 'ses_1', {
        { id = 'part_3', type = 'text', text = 'Third `src/ok.lua:12`.' },
      }),
    })

    local refs = reference_facts.current_refs()

    assert.equal(3, #refs)
    assert.equal('msg_1', refs[1].message_id)
    assert.equal('part_1', refs[1].part_id)
    assert.equal('msg_1', refs[2].message_id)
    assert.equal('part_2', refs[2].part_id)
    assert.equal('msg_2', refs[3].message_id)
    assert.equal('part_3', refs[3].part_id)
    assert.is_true(refs[1].order < refs[2].order)
    assert.is_true(refs[2].order < refs[3].order)
  end)

  it('remove_part and remove_message shrink current refs', function()
    reference_facts.rebuild('ses_1', {
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', type = 'text', text = 'See `src/ok.lua`.' },
        { id = 'part_2', type = 'text', text = 'See `src/loaded.lua`.' },
      }),
    })

    assert.is_true(reference_facts.remove_part('msg_1', 'part_1'))
    assert.equal('src/loaded.lua', reference_facts.current_refs()[1].path)

    assert.is_true(reference_facts.remove_message('msg_1'))
    assert.are.same({}, reference_facts.current_refs())
  end)

  it('maintains current_files from readable files', function()
    reference_facts.rebuild('ses_1', {
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', type = 'text', text = 'See `src/ok.lua`, `src/loaded.lua`, and `src/missing.lua`.' },
        { id = 'part_2', type = 'text', text = 'See `src/ok.lua` again.' },
      }),
    })

    assert.are.same({ '/repo/src/ok.lua' }, reference_facts.current_files())
  end)

  it('refreshes current_files when filesystem availability changes', function()
    local ok_exists = true
    vim.fn.filereadable = function(path)
      return (ok_exists and path == '/repo/src/ok.lua') and 1 or 0
    end

    reference_facts.rebuild('ses_1', {
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', type = 'text', text = 'See `src/ok.lua`.' },
      }),
    })

    assert.are.same({ '/repo/src/ok.lua' }, reference_facts.current_files())

    ok_exists = false
    reference_facts.refresh_current_files()

    assert.are.same({}, reference_facts.current_files())
  end)
end)

describe('reference facts renderer dirty propagation', function()
  local state = require('opencode.state')
  local ctx = require('opencode.ui.renderer.ctx')
  local flush = require('opencode.ui.renderer.flush')
  local events
  local reference_facts
  local schedule_stub

  local function message_with_refs()
    return {
      info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' },
      parts = {
        { id = 'part_ref', messageID = 'msg_1', sessionID = 'ses_1', type = 'text', text = 'See `src/ok.lua`.' },
        { id = 'part_later', messageID = 'msg_1', sessionID = 'ses_1', type = 'text', text = 'Call foo after refs.' },
      },
    }
  end

  local function render_message_parts(message)
    state.renderer.set_messages({ message })
    ctx.render_state:set_message(message)
    ctx.render_state:set_part(message.parts[1], 1, 1)
    ctx.render_state:set_part(message.parts[2], 2, 2)
  end

  before_each(function()
    package.loaded['opencode.ui.reference_facts'] = nil
    package.loaded['opencode.ui.renderer.events'] = nil
    reference_facts = require('opencode.ui.reference_facts')
    events = require('opencode.ui.renderer.events')
    ctx:reset()
    reference_facts.clear()
    state.session.set_active({ id = 'ses_1' })
    schedule_stub = stub(flush, 'schedule')
  end)

  after_each(function()
    schedule_stub:revert()
    ctx:reset()
    reference_facts.clear()
    package.loaded['opencode.ui.renderer.events'] = nil
    package.loaded['opencode.ui.reference_facts'] = nil
    state.session.clear_active()
    state.renderer.set_messages({})
  end)

  it('dirties following assistant text parts when a ref-bearing part changes', function()
    local message = message_with_refs()
    state.renderer.set_messages({ message })
    reference_facts.rebuild('ses_1', { message })
    ctx.render_state:set_message(message)
    ctx.render_state:set_part(message.parts[1], 1, 1)
    ctx.render_state:set_part(message.parts[2], 2, 2)

    events.on_part_updated({
      part = {
        id = 'part_ref',
        messageID = 'msg_1',
        sessionID = 'ses_1',
        type = 'text',
        text = 'Reference removed.',
      },
    })

    assert.equal('msg_1', ctx.pending.dirty_parts.part_ref)
    assert.equal('msg_1', ctx.pending.dirty_parts.part_later)
  end)

  it('dirties following assistant text parts when a ref-bearing part is removed', function()
    local message = message_with_refs()
    state.renderer.set_messages({ message })
    reference_facts.rebuild('ses_1', { message })
    ctx.render_state:set_message(message)
    ctx.render_state:set_part(message.parts[1], 1, 1)
    ctx.render_state:set_part(message.parts[2], 2, 2)

    events.on_part_removed({ sessionID = 'ses_1', messageID = 'msg_1', partID = 'part_ref' })

    assert.is_true(ctx.pending.removed_parts.part_ref)
    assert.equal('msg_1', ctx.pending.dirty_parts.part_later)
  end)

  it('dirties rendered assistant text parts when files are edited', function()
    local message = message_with_refs()
    message.parts[#message.parts + 1] = {
      id = 'part_hidden',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      type = 'text',
      text = 'Unrendered text should wait for its normal render path.',
    }
    render_message_parts(message)

    local original_cmd = vim.cmd
    local refresh_stub = stub(reference_facts, 'refresh_current_files')
    local ok, err = pcall(function()
      vim.cmd = function(command)
        assert.equal('checktime', command)
      end

      events.on_file_edited({ file = 'src/ok.lua' })

      assert.stub(refresh_stub).was_called(1)
      assert.equal('msg_1', ctx.pending.dirty_parts.part_ref)
      assert.equal('msg_1', ctx.pending.dirty_parts.part_later)
      assert.is_nil(ctx.pending.dirty_parts.part_hidden)
    end)
    vim.cmd = original_cmd
    refresh_stub:revert()
    if not ok then
      error(err)
    end
  end)

  it('dirties rendered assistant text parts when watched files change', function()
    local message = message_with_refs()
    render_message_parts(message)

    local refresh_stub = stub(reference_facts, 'refresh_current_files')
    local ok, err = pcall(function()
      events.on_file_watcher_updated({ file = 'src/ok.lua', event = 'unlink' })

      assert.stub(refresh_stub).was_called(1)
      assert.equal('msg_1', ctx.pending.dirty_parts.part_ref)
      assert.equal('msg_1', ctx.pending.dirty_parts.part_later)
    end)
    refresh_stub:revert()
    if not ok then
      error(err)
    end
  end)
end)
