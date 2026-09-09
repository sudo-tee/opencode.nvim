describe('prompt history persistence', function()
  local history, data_dir, original_stdpath, original_rename
  before_each(function()
    data_dir = vim.fn.tempname()
    vim.fn.mkdir(data_dir .. '/opencode', 'p')
    original_stdpath = vim.fn.stdpath
    original_rename = vim.uv.fs_rename
    vim.fn.stdpath = function(kind)
      return kind == 'data' and data_dir or original_stdpath(kind)
    end
    package.loaded['opencode.history'] = nil
    history = require('opencode.history')
  end)
  after_each(function()
    vim.fn.stdpath = original_stdpath
    vim.uv.fs_rename = original_rename
    package.loaded['opencode.history'] = nil
    vim.fn.delete(data_dir, 'rf')
  end)
  local function reload()
    package.loaded['opencode.history'] = nil
    history = require('opencode.history')
    return history.read()
  end
  it('round trips literal escapes, newlines, quotes, Unicode and whitespace', function()
    local prompts = { [[print('\n')]], 'first\nsecond', '"quoted" café\\path', '  ' }
    for _, prompt in ipairs(prompts) do
      assert.is_true(history.write(prompt))
    end
    assert.same({ prompts[4], prompts[3], prompts[2], prompts[1] }, reload())
  end)
  it('migrates legacy records once and does not resurrect them after clear', function()
    vim.fn.writefile({ 'old\\nmultiline', 'latest' }, data_dir .. '/opencode/history.txt')
    assert.same({ 'latest', 'old\nmultiline' }, history.read())
    history.write([[new\ntext]])
    assert.same({ [[new\ntext]], 'latest', 'old\nmultiline' }, reload())
    history.clear()
    assert.same({}, reload())
    assert.equals(2, #vim.fn.readfile(data_dir .. '/opencode/history.txt'))
  end)
  it('removes each selected index once and ignores invalid indices', function()
    for _, prompt in ipairs({ 'a', 'b', 'c', 'd' }) do
      history.write(prompt)
    end
    history.delete({ 2, 2, 0, -1, 1.5, '3', 9 })
    assert.same({ 'd', 'b', 'a' }, reload())
  end)
  it('preserves the file and cached history when replacement fails', function()
    history.write('a')
    history.write('b')
    vim.uv.fs_rename = function()
      return nil, 'permission denied'
    end
    assert.is_false(history.delete({ 1 }))
    assert.same({ 'b', 'a' }, history.read())
    assert.same({ 'b', 'a' }, reload())
  end)
end)
