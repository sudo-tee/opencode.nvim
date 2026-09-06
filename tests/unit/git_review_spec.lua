local Promise = require('opencode.promise')
local state = require('opencode.state')
local snapshot = require('opencode.snapshot')
local diff_tab = require('opencode.ui.diff_tab')
local picker = require('opencode.ui.picker')

describe('asynchronous git review', function()
  local original, review, cwd, displayed
  before_each(function()
    original = {
      snapshot = vim.tbl_extend('force', {}, snapshot),
      cwd = vim.fn.getcwd,
      session = state.active_session,
      display = diff_tab.open_diff_tab,
      select = picker.select,
    }
    cwd, displayed = '/project', {}
    vim.fn.getcwd = function()
      return cwd
    end
    state.session.set_active({ id = 'one' })
    snapshot.with_context = function(fn)
      return Promise.spawn(fn)
    end
    snapshot.patch = function()
      return Promise.new():resolve({ files = { '/project/file.lua' } })
    end
    snapshot.diff_file = function(_, file)
      return Promise.new():resolve({ left = file, right = '/tmp/before', file_type = 'lua' })
    end
    diff_tab.open_diff_tab = function(left)
      displayed[#displayed + 1] = left
    end
    package.loaded['opencode.git_review'] = nil
    review = require('opencode.git_review')
  end)
  after_each(function()
    for key, value in pairs(original.snapshot) do
      snapshot[key] = value
    end
    vim.fn.getcwd = original.cwd
    state.session.set_active(original.session)
    diff_tab.open_diff_tab, picker.select = original.display, original.select
    package.loaded['opencode.git_review'] = nil
  end)
  it('does not display stale results after a directory switch', function()
    local patch = Promise.new()
    snapshot.patch = function()
      return patch
    end
    local result = review.review('hash')
    assert.is_false(result:is_resolved())
    cwd = '/other'
    patch:resolve({ files = { '/project/file.lua' } })
    result:wait()
    assert.same({}, displayed)
  end)
  it('keeps the command pending until picker selection and ignores a stale choice', function()
    snapshot.patch = function()
      return Promise.new():resolve({ files = { '/project/a', '/project/b' } })
    end
    local choice, items
    picker.select = function(values, _, callback)
      items, choice = values, callback
    end
    local result = review.review('hash')
    assert.is_function(choice)
    assert.is_false(result:is_resolved())
    state.session.set_active({ id = 'two' })
    choice(items[1])
    result:wait()
    assert.same({}, displayed)
  end)
  it('displays a completed diff for the active workspace', function()
    review.review('hash'):wait()
    assert.same({ '/project/file.lua' }, displayed)
  end)
end)
