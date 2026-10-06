local assert = require('luassert')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')
local reference_facts = require('opencode.ui.reference_facts')

describe('replay environment isolation', function()
  local path_stub
  local files_stub

  before_each(function()
    path_stub = stub(vim.fn, 'fnamemodify').invokes(function(path, modifiers)
      return 'host-dependent:' .. modifiers .. ':' .. path
    end)
    files_stub = stub(reference_facts, 'available_files').returns({ '/host/loaded/file.lua' })
  end)

  after_each(function()
    helpers.restore_replay_environment()
    path_stub:revert()
    files_stub:revert()
  end)

  it('uses mock cwd without shortening recorded paths against host cwd or home', function()
    helpers.isolate_replay_environment()

    assert.equals('src/test.lua', vim.fn.fnamemodify(helpers.MOCK_CWD .. '/src/test.lua', ':~:.'))
    assert.equals('/home/francis/project/test.lua', vim.fn.fnamemodify('/home/francis/project/test.lua', ':~:.'))
    assert.equals('test.lua', vim.fn.fnamemodify('test.lua', ':~:.'))
    assert.equals('host-dependent::e:test.lua', vim.fn.fnamemodify('test.lua', ':e'))
  end)

  it('does not infer reference availability from host files or loaded buffers', function()
    helpers.isolate_replay_environment()

    assert.same({}, reference_facts.available_files())
    assert.stub(files_stub).was_not_called()
  end)

  it('restores host functions even after repeated isolation', function()
    local fnamemodify = vim.fn.fnamemodify
    local available_files = reference_facts.available_files
    helpers.isolate_replay_environment()
    helpers.isolate_replay_environment()

    helpers.restore_replay_environment()

    assert.equals(fnamemodify, vim.fn.fnamemodify)
    assert.equals(available_files, reference_facts.available_files)
    assert.same({ '/host/loaded/file.lua' }, reference_facts.available_files())
  end)
end)
