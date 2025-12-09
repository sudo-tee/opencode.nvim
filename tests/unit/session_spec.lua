-- tests/unit/session_spec.lua
-- Tests for the session module

local DEFAULT_WORKSPACE = '/Users/jimmy/myproject1'
local DEFAULT_WORKSPACE_ID = 'Users-jimmy-myproject1'
local NON_EXISTENT_WORKSPACE = '/non/existent/path'

local session = require('opencode.session')
-- Use the existing mock data
local session_list_mock = require('tests.mocks.session_list')
local util = require('opencode.util')
local assert = require('luassert')
local config_file = require('opencode.config_file')
local state = require('opencode.state')
local Promise = require('opencode.promise')

describe('opencode.session', function()
  local original_is_git_project
  local original_fs_stat
  local original_readfile
  local original_workspace
  local original_fs_dir
  local original_isdirectory
  local original_json_decode
  local original_get_opencode_project
  local original_api_client
  local session_files = {}
  local mock_data = {}

  -- Setup test environment before each test
  before_each(function()
    session_files = {
      'new-8.json',
      'old-1.json',
    }
    -- Save the original functions
    original_fs_stat = vim.uv.fs_stat
    original_is_git_project = util.is_git_project
    original_readfile = vim.fn.readfile
    original_fs_dir = vim.fs.dir
    original_workspace = vim.fn.getcwd
    original_isdirectory = vim.fn.isdirectory
    original_json_decode = vim.fn.json_decode
    original_get_opencode_project = config_file.get_opencode_project
    original_api_client = state.api_client
    -- mock vim.fs and isdirectory
    config_file.get_opencode_project = function()
      local p = Promise.new()
      p:resolve({ id = DEFAULT_WORKSPACE_ID })
      return p
    end

    vim.fs.dir = function(path)
      -- Return a mock directory listing
      -- Check if this is the session directory
      if path:find(DEFAULT_WORKSPACE_ID, 1, true) and path:match('/session/') then
        return coroutine.wrap(function()
          for _, file in ipairs(session_files) do
            coroutine.yield(file, 'file')
          end
        end)
      end
      if mock_data.message_files and path:match('/message/new%-8$') then
        return coroutine.wrap(function()
          for _, file in ipairs(mock_data.message_files) do
            coroutine.yield(file, 'file')
          end
        end)
      elseif mock_data.part_files and path:match('/part/new%-8/msg1$') then
        return coroutine.wrap(function()
          for _, file in ipairs(mock_data.part_files) do
            coroutine.yield(file, 'file')
          end
        end)
      end
      return original_fs_dir(path)
    end

    vim.fn.isdirectory = function(path)
      if mock_data.valid_dirs and vim.tbl_contains(mock_data.valid_dirs, path) then
        return 1
      end
      return original_isdirectory(path)
    end

    -- Mock the readfile function
    vim.fn.readfile = function(file)
      local storage_path = session.get_storage_path()

      -- Handle session info files - check if file matches session directory pattern
      if file:match('/session/') and file:match('%.json$') then
        local filename = file:match('([^/]+)$')
        local session_name = filename:sub(1, -6) -- Remove '.json' extension
        if vim.tbl_contains(session_files, filename) then
          local data
          if mock_data.session_list and mock_data.session_list[session_name] then
            data = mock_data.session_list[session_name]
          else
            data = session_list_mock[session_name]
          end
          return vim.split(data, '\n')
        end
      end

      -- Handle message files
      if mock_data.messages and file:match('/message/new%-8/') then
        local msg_name = vim.fn.fnamemodify(file, ':t:r')
        if mock_data.messages[msg_name] then
          return vim.split(mock_data.messages[msg_name], '\n')
        end
      end

      -- Handle part files
      if mock_data.parts and vim.startswith(file, storage_path .. '/part/new-8/msg1/') then
        local part_name = vim.fn.fnamemodify(file, ':t:r')
        if mock_data.parts[part_name] then
          return vim.split(mock_data.parts[part_name], '\n')
        end
      end

      -- Fall back to original for other commands
      return original_readfile(file)
    end

    -- Mock getcwd - defaulting to match the working directory in the mock data
    vim.fn.getcwd = function()
      return mock_data.workspace or DEFAULT_WORKSPACE
    end

    vim.uv.fs_stat = function(path)
      if path:find(DEFAULT_WORKSPACE_ID, 1, true) then
        -- Simulate a valid session file
        if vim.tbl_contains(session_files, path:match('([^/]+)$')) then
          return { type = 'file', mtime = { sec = os.time() } }
        end
        -- Simulate a valid directory for messages or parts
        if mock_data.valid_dirs and vim.tbl_contains(mock_data.valid_dirs, path) then
          return { type = 'directory', mtime = { sec = os.time() } }
        end
      end
    end

    util.is_git_project = function()
      return true
    end

    -- Mock the api_client to return session data
    state.api_client = {
      list_sessions = function()
        local sessions = {}
        local session_source = mock_data.session_list or session_list_mock

        for session_name, session_data in pairs(session_source) do
          local success, decoded = pcall(vim.fn.json_decode, session_data)
          if success then
            -- Sessions are associated with DEFAULT_WORKSPACE unless tests modify data
            decoded.directory = DEFAULT_WORKSPACE
            table.insert(sessions, decoded)
          end
          -- If JSON parsing fails, we skip the session (simulating real behavior)
        end
        local promise = Promise.new()
        promise:resolve(sessions)
        return promise
      end,
      list_messages = function(session_id)
        local promise = Promise.new()

        -- Return nil for sessions with no data
        if not session_id then
          promise:resolve(nil)
          return promise
        end

        -- Check if mock_data has specific messages for this session
        if mock_data.messages then
          local messages = {}
          for msg_id, msg_data in pairs(mock_data.messages) do
            local decoded = vim.fn.json_decode(msg_data)
            table.insert(messages, decoded)
          end
          promise:resolve(messages)
        else
          -- Return nil when directory doesn't exist (simulating 404)
          if mock_data.messages == false then
            promise:resolve(nil)
          else
            -- Mock empty messages for default case
            promise:resolve({})
          end
        end
        return promise
      end,
    }
  end)

  -- Clean up after each test
  after_each(function()
    -- Restore original functions
    vim.fn.readfile = original_readfile
    vim.fn.getcwd = original_workspace
    vim.fs.dir = original_fs_dir
    vim.fn.isdirectory = original_isdirectory
    vim.uv.fs_stat = original_fs_stat
    vim.fn.json_decode = original_json_decode
    util.is_git_project = original_is_git_project
    config_file.get_opencode_project = original_get_opencode_project
    state.api_client = original_api_client
    mock_data = {}
  end)

  describe('get_last_workspace_session', function()
    it('returns the most recent session for current workspace', function()
      -- Using the default mock session list and workspace

      -- Call the function
      local promise = session.get_last_workspace_session()
      local result = promise:wait()

      -- Verify the result - should return "new-8" as it's the most recent
      assert.is_not_nil(result)
      if result then
        assert.equal('new-8', result.id)
      end
    end)

    it('returns nil when no sessions match the workspace', function()
      -- Mock a workspace with no sessions
      mock_data.workspace = NON_EXISTENT_WORKSPACE

      config_file.get_opencode_project = function()
        local p = Promise.new()
        p:resolve({ id = NON_EXISTENT_WORKSPACE })
        return p
      end

      -- For this test, make it not a git project so filtering happens
      util.is_git_project = function()
        return false
      end

      -- Call the function
      local promise = session.get_last_workspace_session()
      local result = promise:wait()

      -- Should be nil since no sessions match
      assert.is_nil(result)
    end)

    it('handles JSON parsing errors', function()
      -- Mock invalid JSON
      mock_data.session_list = { ['new-8'] = 'not valid json', ['old-1'] = 'not-valid-json' }

      -- Mock json_decode to simulate error
      vim.fn.json_decode = function(str)
        if str == 'not valid json' then
          error('Invalid JSON')
        end
        return original_json_decode(str)
      end

      -- Call the function inside pcall to catch the error
      local success, result = pcall(function()
        local promise = session.get_last_workspace_session()
        return promise:wait()
      end)

      -- Restore original function
      vim.fn.json_decode = original_json_decode

      -- Either the function should handle the error and return nil
      -- or it will throw an error which needs to be fixed in the implementation
      if success then
        assert.is_nil(result)
      else
        assert.is_truthy(result and result:match('Invalid JSON'))
      end
    end)

    it('handles empty session list', function()
      session_files = {} -- Clear session files to simulate empty session list
      -- Mock empty session list
      mock_data.session_list = {}

      -- Call the function
      local promise = session.get_last_workspace_session()
      local result = promise:wait()

      -- Should be nil with empty list
      assert.is_nil(result)
    end)
  end)

  describe('get_by_name', function()
    it('returns the session with matching ID', function()
      -- Mock the get_session method
      local original_get_session = state.api_client.get_session
      state.api_client.get_session = function(self, id)
        local p = Promise.new()
        if id == 'new-8' then
          local session_data = vim.trim(session_list_mock['new-8'])
          local decoded = vim.json.decode(session_data)
          p:resolve(decoded)
        else
          p:resolve(nil)
        end
        return p
      end

      -- Call the function with an ID from the mock data
      local promise = session.get_by_id('new-8')
      local result = promise:wait()

      -- Verify the result
      assert.is_not_nil(result)
      if result then
        assert.equal('new-8', result.id)
      end
      
      -- Restore
      if original_get_session then
        state.api_client.get_session = original_get_session
      end
    end)

    it('returns nil when no session matches the ID', function()
      -- Mock the get_session method
      state.api_client.get_session = function(self, id)
        local p = Promise.new()
        p:resolve(nil)
        return p
      end

      -- Call the function with non-existent ID
      local promise = session.get_by_id('nonexistent')
      local result = promise:wait()

      -- Should be nil since no sessions match
      assert.is_nil(result)
    end)
  end)

  describe('read_json_dir', function()
    it('returns nil for non-existent directory', function()
      local result = util.read_json_dir('/nonexistent/path')
      assert.is_nil(result)
    end)

    it('returns nil when directory exists but has no JSON files', function()
      mock_data.valid_dirs = { '/empty/dir' }
      mock_data.message_files = {}
      local result = util.read_json_dir('/empty/dir')
      assert.is_nil(result)
    end)

    it('returns decoded JSON content from directory', function()
      local dir = session.get_storage_path() .. '/message/new-8'
      mock_data.valid_dirs = { dir }
      mock_data.message_files = { 'msg1.json' }
      mock_data.messages = {
        msg1 = '{"id": "msg1", "content": "test message"}',
      }

      -- Update vim.fn.isdirectory to recognize this directory
      vim.fn.isdirectory = function(path)
        if path == dir or (mock_data.valid_dirs and vim.tbl_contains(mock_data.valid_dirs, path)) then
          return 1
        end
        return 0
      end

      -- Update vim.fs.dir to return the mock data for this specific path
      vim.fs.dir = function(path)
        if path == dir then
          return coroutine.wrap(function()
            for _, file in ipairs(mock_data.message_files) do
              coroutine.yield(file, 'file')
            end
          end)
        end
        return original_fs_dir(path)
      end

      local result = util.read_json_dir(dir)
      assert.is_not_nil(result)
      if result then
        assert.equal(1, #result)
        assert.equal('msg1', result[1].id)
        assert.equal('test message', result[1].content)
      end
    end)

    it('skips invalid JSON files', function()
      local dir = session.get_storage_path() .. '/message/new-8'
      mock_data.valid_dirs = { dir }
      mock_data.message_files = { 'valid.json', 'invalid.json' }
      mock_data.messages = {
        valid = '{"id": "valid"}',
        invalid = 'not json',
      }

      -- Update vim.fn.isdirectory to recognize this directory
      vim.fn.isdirectory = function(path)
        if path == dir or (mock_data.valid_dirs and vim.tbl_contains(mock_data.valid_dirs, path)) then
          return 1
        end
        return 0
      end

      -- Update vim.fs.dir to return the mock data for this specific path
      vim.fs.dir = function(path)
        if path == dir then
          return coroutine.wrap(function()
            for _, file in ipairs(mock_data.message_files) do
              coroutine.yield(file, 'file')
            end
          end)
        end
        return original_fs_dir(path)
      end

      local result = util.read_json_dir(dir)
      assert.is_not_nil(result)
      if result then
        assert.equal(1, #result)
        assert.equal('valid', result[1].id)
      end
    end)
  end)

  describe('get_messages', function()
    it('returns nil when session is nil', function()
      local result = session.get_messages(nil)
      if result then
        result = result:wait()
      end
      assert.is_nil(result)
    end)

    it('returns nil when messages directory does not exist', function()
      mock_data.messages = false
      local result = session.get_messages({ id = 'nonexistent', messages_path = '/nonexistent/path' })
      if result then
        result = result:wait()
      end
      assert.is_nil(result)
    end)

    it('returns messages with their parts', function()
      local storage_path = session.get_storage_path()
      local messages_dir = storage_path .. '/message/new-8'
      local parts_dir = storage_path .. '/part/new-8/msg1'

      mock_data.valid_dirs = { messages_dir, parts_dir }
      mock_data.message_files = { 'msg1.json' }
      mock_data.part_files = { 'part1.json', 'part2.json' }
      mock_data.messages = {
        msg1 = '{"id": "msg1", "content": "test message"}',
      }
      mock_data.parts = {
        part1 = '{"id": "part1", "content": "part 1"}',
        part2 = '{"id": "part2", "content": "part 2"}',
      }

      local test_session = {
        messages_path = messages_dir,
        parts_path = storage_path .. '/part/new-8',
      }

      local result = session.get_messages(test_session)
      assert.is_not_nil(result)
      if result then
        result = result:wait()
        assert.equal(1, #result)
        assert.equal('msg1', result[1].id)
        assert.equal('test message', result[1].content)
        if result[1].parts then
          assert.equal(2, #result[1].parts)
          assert.equal('part1', result[1].parts[1].id)
          assert.equal('part2', result[1].parts[2].id)
        end
      end
    end)
  end)
end)
