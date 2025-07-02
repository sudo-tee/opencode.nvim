-- tests/unit/context_spec.lua
-- Tests for the context module

local context = require("opencode.context")
local helpers = require("tests.helpers")
local state = require("opencode.state")
local template = require("opencode.template")
local config = require("opencode.config")

describe("opencode.context", function()
  local test_file, buf_id
  local original_state
  local original_config

  -- Create a temporary file and open it in a buffer before each test
  before_each(function()
    original_state = vim.deepcopy(state)
    original_config = vim.deepcopy(config.values)
    test_file = helpers.create_temp_file("Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
    buf_id = helpers.open_buffer(test_file)
  end)

  -- Clean up after each test
  after_each(function()
    -- Restore state
    for k, v in pairs(original_state) do
      state[k] = v
    end

    -- Restore config
    for k, v in pairs(original_config) do
      config[k] = v
    end

    pcall(function()
      if buf_id and vim.api.nvim_buf_is_valid(buf_id) then
        helpers.close_buffer(buf_id)
      end
      if test_file then
        helpers.delete_temp_file(test_file)
      end
    end)
    helpers.reset_editor()
  end)

  describe("get_current_file", function()
    it("returns the correct file path", function()
      local file_path = context.get_current_file()
      assert.equal(test_file, file_path.path)
    end)
  end)

  describe("get_current_cursor_data", function()
    it("returns nil if cursor data is disabled in config (default)", function()
      local cursor_data = context.get_current_cursor_data()
      assert.equal(nil, cursor_data)
    end)

    it("returns cursor data is enabled in config", function()
      config.values.context.cursor_data = true

      local cursor_data = context.get_current_cursor_data()
      assert.equal(1, cursor_data.col)
      assert.equal(1, cursor_data.line)
      assert.equal("Line 1", cursor_data.line_content)
    end)
  end)

  describe("get_current_selection", function()
    it("returns selected text and lines when in visual mode", function()
      -- Setup a visual selection (line 2 to line 3)
      vim.cmd("normal! 2Gvj$")

      -- Call the function
      local selection_result = context.get_current_selection()

      -- Check the returned selection contains the expected text and lines
      assert.is_not_nil(selection_result)
      assert.is_not_nil(selection_result.text)
      assert.is_not_nil(selection_result.lines)
      assert.truthy(selection_result.text:match("Line 2"))
      assert.truthy(selection_result.text:match("Line 3"))
      assert.equal("2, 3", selection_result.lines)
    end)

    it("returns nil when not in visual mode", function()
      -- Ensure we're in normal mode
      vim.cmd("normal! G")

      -- Call the function
      local selection_result = context.get_current_selection()

      -- Should be nil since we're not in visual mode
      assert.is_nil(selection_result)
    end)
  end)

  describe("format_message", function()
    it("formats message with file path and prompt", function()
      -- Mock template.render_template to verify it's called with right params
      local original_render = template.render_template
      local called_with_vars = nil

      template.render_template = function(vars)
        called_with_vars = vars
        return "rendered template"
      end

      -- Set up context
      -- Initialize context with proper values
      context.context.current_file = nil
      context.context.cursor_data = nil
      context.context.mentioned_files = nil
      context.context.selections = nil
      
      -- Set specific values for testing
      context.context.current_file = {
        path = test_file,
        name = vim.fn.fnamemodify(test_file, ":t"),
        extension = vim.fn.fnamemodify(test_file, ":e")
      }

      local prompt = "Help me with this code"
      local message = context.format_message(prompt)

      -- Restore original function
      template.render_template = original_render

      -- Verify template was called with correct variables
      assert.truthy(called_with_vars)
      assert.equal(test_file, called_with_vars.current_file.path)
      assert.equal(prompt, called_with_vars.prompt)

      -- Verify the message was returned
      assert.equal("rendered template", message)
    end)

    it("includes selection and selection lines in template variables when available", function()
      -- Mock template.render_template
      local original_render = template.render_template
      local called_with_vars = nil

      template.render_template = function(vars)
        called_with_vars = vars
        return "rendered template with selection"
      end

      -- Set up context
      -- Initialize context with proper values
      context.context.current_file = nil
      context.context.cursor_data = nil
      context.context.mentioned_files = nil
      context.context.selections = nil
      
      -- Set specific values for testing
      context.context.current_file = {
        path = test_file,
        name = vim.fn.fnamemodify(test_file, ":t"),
        extension = vim.fn.fnamemodify(test_file, ":e")
      }
      
      context.context.selections = {
        {
          file = context.context.current_file,
          content = "Selected text for testing",
          lines = "10, 15"
        }
      }

      local prompt = "Help with this selection"
      local message = context.format_message(prompt)

      -- Restore original function
      template.render_template = original_render

      -- Verify template was called with correct variables
      assert.truthy(called_with_vars)
      assert.equal(test_file, called_with_vars.current_file.path)
      assert.equal(prompt, called_with_vars.prompt)
      assert.equal("Selected text for testing", called_with_vars.selections[1].content)
      assert.equal("10, 15", called_with_vars.selections[1].lines)

      -- Verify the message was returned
      assert.equal("rendered template with selection", message)
    end)
  end)
end)

describe("extract_from_message", function()
  it("extracts context elements from a formatted message", function()
    -- Updated to use 'Editor context:' instead of 'Opencode context:'
    local message = [[
Help me with this code

Editor context:
Current file: /path/to/file.lua
Selected text:
function test()
  return "hello"
end
Selected lines: (10, 15)
Additional files:
- /path/to/other.lua
- /path/to/another.lua
]]

    local result = context.extract_from_message(message)

    assert.equal('Help me with this code\n\nEditor context:\nCurrent file: /path/to/file.lua\nSelected text:\nfunction test()\n  return "hello"\nend\nSelected lines: (10, 15)\nAdditional files:\n- /path/to/other.lua\n- /path/to/another.lua', vim.trim(result.prompt))
    assert.is_nil(result.selected_text)
  end)
end)
