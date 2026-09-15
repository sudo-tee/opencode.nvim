local assert = require('luassert')
local stub = require('luassert.stub')

describe('opencode.ui.reference_facts', function()
  local reference_facts
  local original_fn
  local original_api

  local function assistant_message(id, session_id, content)
    return {
      id = id,
      kind = 'assistant',
      session_id = session_id,
      content = content or {},
    }
  end

  local function rebuild(messages)
    reference_facts.rebuild('ses_1', messages, { directory = '/repo' })
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
      rebuild({
        assistant_message('msg_1', 'ses_1', {
          { id = 'part_1', kind = 'text', text = 'See `src/ok.lua`.' },
        }),
      })
    end)

    package.loaded['opencode.ui.reference_picker'] = nil
    assert.equal('src/ok.lua', reference_facts.current_refs()[1].path)
  end)

  it('collects user file parts as reference facts', function()
    rebuild({
      {
        id = 'user_1',
        kind = 'user',
        session_id = 'ses_1',
        content = {
          { id = 'prt_user_file', kind = 'file', name = 'src/ok.lua' },
          { id = 'user_text', kind = 'text', text = 'look at this' },
        },
      },
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', kind = 'text', text = 'Call foo.' },
      }),
    })

    local refs = reference_facts.current_refs()

    assert.equal(1, #refs)
    assert.equal('src/ok.lua', refs[1].path)
    assert.equal('user_file_part', refs[1].source_kind)
    assert.equal('user_1', refs[1].message_id)
    assert.equal('prt_user_file', refs[1].part_id)
    assert.are.same({ '/repo/src/ok.lua' }, reference_facts.current_files())
  end)

  it('keeps unreadable user file parts as refs but excludes them from current_files', function()
    rebuild({
      {
        id = 'user_1',
        kind = 'user',
        session_id = 'ses_1',
        content = {
          { id = 'prt_user_file', kind = 'file', name = 'src/missing.lua' },
        },
      },
    })

    assert.equal('src/missing.lua', reference_facts.current_refs()[1].path)
    assert.are.same({}, reference_facts.current_files())
  end)

  it('available_files merges readable ref files with loaded plain buffers', function()
    local dedup_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[dedup_buf].buftype = ''
    local buffer_only_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buffer_only_buf].buftype = ''
    local nofile_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[nofile_buf].buftype = 'nofile'
    local getbufinfo_stub = stub(vim.fn, 'getbufinfo').returns({
      { bufnr = dedup_buf, name = '/repo/src/ok.lua' },
      { bufnr = buffer_only_buf, name = '/repo/buffer_only.lua' },
      { bufnr = nofile_buf, name = '/repo/scratch.log' },
    })

    rebuild({
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', kind = 'text', text = 'See `src/ok.lua`.' },
      }),
    })

    local files = reference_facts.available_files()

    getbufinfo_stub:revert()
    pcall(vim.api.nvim_buf_delete, dedup_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, buffer_only_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, nofile_buf, { force = true })

    assert.is_true(vim.tbl_contains(files, '/repo/src/ok.lua'))
    assert.is_true(vim.tbl_contains(files, '/repo/buffer_only.lua'))
    assert.is_false(vim.tbl_contains(files, '/repo/scratch.log'))
    local ok_count = 0
    for _, path in ipairs(files) do
      if path == '/repo/src/ok.lua' then
        ok_count = ok_count + 1
      end
    end
    assert.equal(1, ok_count)
  end)

  it('rebuilds current session assistant reference facts only', function()
    rebuild({
      {
        id = 'user_1',
        kind = 'user',
        session_id = 'ses_1',
        content = { { id = 'user_part', kind = 'text', text = 'Ignore `src/user.lua`.' } },
      },
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', kind = 'text', text = 'See `src/ok.lua:12:3`.' },
        { id = 'part_2', kind = 'tool', name = 'read', state = 'completed', target = { path = '/repo/src/tool.lua' } },
      }),
      assistant_message('msg_2', 'ses_other', {
        { id = 'part_other', kind = 'text', text = 'Ignore `src/other.lua`.' },
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

  it('keeps duplicate path and line facts from different source parts and messages in session order', function()
    rebuild({
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', kind = 'text', text = 'First `src/ok.lua:12`.' },
        { id = 'part_2', kind = 'text', text = 'Second `src/ok.lua:12`.' },
      }),
      assistant_message('msg_2', 'ses_1', {
        { id = 'part_3', kind = 'text', text = 'Third `src/ok.lua:12`.' },
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

  it('maintains current_files from readable files', function()
    rebuild({
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', kind = 'text', text = 'See `src/ok.lua`, `src/loaded.lua`, and `src/missing.lua`.' },
        { id = 'part_2', kind = 'text', text = 'See `src/ok.lua` again.' },
      }),
    })

    assert.are.same({ '/repo/src/ok.lua' }, reference_facts.current_files())
  end)

  it('refreshes current_files when filesystem availability changes', function()
    local ok_exists = true
    vim.fn.filereadable = function(path)
      return (ok_exists and path == '/repo/src/ok.lua') and 1 or 0
    end

    rebuild({
      assistant_message('msg_1', 'ses_1', {
        { id = 'part_1', kind = 'text', text = 'See `src/ok.lua`.' },
      }),
    })

    assert.are.same({ '/repo/src/ok.lua' }, reference_facts.current_files())

    ok_exists = false
    reference_facts.refresh_current_files()

    assert.are.same({}, reference_facts.current_files())
  end)
end)
