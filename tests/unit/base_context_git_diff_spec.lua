local assert = require('luassert')
local stub = require('luassert.stub')
local base_context = require('opencode.context.base_context')
local Promise = require('opencode.promise')

describe('Git diff context', function()
  local system
  local enabled = { git_diff = { enabled = true } }

  before_each(function()
    system = stub(Promise, 'system')
  end)

  after_each(function()
    system:revert()
  end)

  it('does not run Git when disabled', function()
    assert.is_nil(base_context.get_git_diff({ git_diff = { enabled = false } }):wait())
    assert.stub(system).was_not_called()
  end)

  it('returns staged changes', function()
    system.returns(Promise.new():resolve({ stdout = 'staged diff' }))
    assert.equals('staged diff', base_context.get_git_diff(enabled):wait())
    assert.stub(system).was_called_with({ 'git', 'diff', '--cached', '--minimal' })
  end)

  it('returns nil for an empty diff', function()
    system.returns(Promise.new():resolve({ stdout = '' }))
    assert.is_nil(base_context.get_git_diff(enabled):wait())
  end)

  it('returns nil when Git rejects', function()
    system.returns(Promise.new():reject({ code = 129, stderr = 'not a git repository' }))
    assert.is_nil(base_context.get_git_diff(enabled):wait())
  end)

  it('returns nil when Git cannot start', function()
    system.invokes(function()
      error('Git executable not found')
    end)
    assert.is_nil(base_context.get_git_diff(enabled):wait())
  end)
end)

describe('Git diff context outside a repository', function()
  local cwd, directory

  before_each(function()
    cwd = vim.fn.getcwd()
    directory = '/tmp/opencode/git-diff-' .. vim.uv.hrtime()
    vim.fn.mkdir(directory, 'p')
    vim.fn.chdir(directory)
  end)

  after_each(function()
    vim.fn.chdir(cwd)
    vim.fn.delete(directory, 'd')
  end)

  it('resolves nil instead of rejecting', function()
    assert.is_nil(base_context.get_git_diff({ git_diff = { enabled = true } }):wait())
  end)
end)
