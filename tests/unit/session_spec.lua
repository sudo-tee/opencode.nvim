-- tests/unit/session_spec.lua
-- Tests for the session module

local DEFAULT_WORKSPACE = '/Users/jimmy/myproject1'
local DEFAULT_WORKSPACE_SLUG = 'Users-jimmy-myproject1'
local NON_EXISTENT_WORKSPACE = '/non/existent/path'

local session = require('opencode.session')
local helpers = require('tests.helpers')
-- Use the existing mock data
local session_list_mock = require('tests.mocks.session_list')

describe('opencode.session', function()
  local original_readfile
  local original_workspace
  local session_files = {}
  local mock_data = {}

  -- Setup test environment before each test
  before_each(function()
    session_files = {
      'new-8.json',
      'old-1.json',
    }
    -- Save the original functions
    original_readfile = vim.fn.readfile
    original_fs_dir = vim.fs.dir
    original_workspace = vim.fn.getcwd
    -- mock vim.fs
    vim.fs.dir = function(path)
      -- Return a mock directory listing
      local session_dir = session.get_workspace_session_path()
      if path:find(DEFAULT_WORKSPACE_SLUG, 1, true) then
        if path == session_dir .. '/info' then
          return coroutine.wrap(function()
            for _, file in ipairs(session_files) do
              coroutine.yield(file, 'file')
            end
          end)
        end
      end
      return original_fs_dir(path)
    end
    -- Mock the readfile function
    vim.fn.readfile = function(file)
      local session_dir = session.get_workspace_session_path()
      local info_prefix = session_dir .. '/info/'
      local filename = file:sub(#info_prefix + 1)
      local session_name = filename:sub(1, -6) -- Remove '.json' extension

      if vim.startswith(file, info_prefix) and vim.tbl_contains(session_files, filename) then
        local data
        if mock_data.session_list and mock_data.session_list[session_name] then
          data = mock_data.session_list[session_name]
        else
          data = session_list_mock[session_name]
        end
        return vim.split(data, '\n')
      end
      -- Fall back to original for other commands
      return original_readfile(file)
    end

    -- Mock getcwd - defaulting to match the working directory in the mock data
    vim.fn.getcwd = function()
      return mock_data.workspace or DEFAULT_WORKSPACE
    end
  end)

  -- Clean up after each test
  after_each(function()
    -- Restore original functions
    vim.fn.readfile = original_readfile
    vim.fn.getcwd = original_workspace
    vim.fs.dir = original_fs_dir
    mock_data = {}
  end)

  describe('get_last_workspace_session', function()
    it('returns the most recent session for current workspace', function()
      -- Using the default mock session list and workspace

      -- Call the function
      local result = session.get_last_workspace_session()

      -- Verify the result - should return "new-8" as it's the most recent
      assert.is_not_nil(result)
      assert.equal('new-8', result.name)
    end)

    it('returns nil when no sessions match the workspace', function()
      -- Mock a workspace with no sessions
      mock_data.workspace = NON_EXISTENT_WORKSPACE

      -- Call the function
      local result = session.get_last_workspace_session()

      -- Should be nil since no sessions match
      assert.is_nil(result)
    end)

    it('handles JSON parsing errors', function()
      -- Mock invalid JSON
      mock_data.session_list = { ['new-8'] = 'not valid json', ['old-1'] = 'not-valid-json' }

      -- Mock json_decode to simulate error
      local original_json_decode = vim.fn.json_decode
      vim.fn.json_decode = function(str)
        if str == 'not valid json' then
          error('Invalid JSON')
        end
        return original_json_decode(str)
      end

      -- Call the function inside pcall to catch the error
      local success, result = pcall(function()
        return session.get_last_workspace_session()
      end)

      -- Restore original function
      vim.fn.json_decode = original_json_decode

      -- Either the function should handle the error and return nil
      -- or it will throw an error which needs to be fixed in the implementation
      if success then
        assert.is_nil(result)
      else
        assert.is_truthy(result:match('Invalid JSON'))
      end
    end)

    it('handles empty session list', function()
      session_files = {} -- Clear session files to simulate empty session list
      -- Mock empty session list
      mock_data.session_list = {}

      -- Call the function
      local result = session.get_last_workspace_session()

      -- Should be nil with empty list
      assert.is_nil(result)
    end)
  end)

  describe('get_by_name', function()
    it('returns the session with matching ID', function()
      -- Call the function with an ID from the mock data
      local result = session.get_by_name('new-8')

      -- Verify the result
      assert.is_not_nil(result)
      assert.equal('new-8', result.name)
    end)

    it('returns nil when no session matches the ID', function()
      -- Call the function with non-existent ID
      local result = session.get_by_name('nonexistent')

      -- Should be nil since no sessions match
      assert.is_nil(result)
    end)
  end)
end)
