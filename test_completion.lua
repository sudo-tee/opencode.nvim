-- Test script to verify completion trigger characters work correctly
local completion = require('opencode.ui.completion')
local config = require('opencode.config')

-- Test the blink.cmp engine
local blink_engine = require('opencode.ui.completion.engines.blink_cmp')
local source = blink_engine.new()

print('=== Testing Completion Trigger Characters ===')

-- Test trigger characters
local trigger_chars = source:get_trigger_characters()
print('Trigger characters:', vim.inspect(trigger_chars))

-- Expected trigger characters from config
local expected_chars = {
  config.get().keymap.window.mention_file,
  config.get().keymap.window.slash_commands
}
print('Expected characters:', vim.inspect(expected_chars))

-- Verify they match
local match = true
for i, char in ipairs(expected_chars) do
  if trigger_chars[i] ~= char then
    match = false
    break
  end
end

if match and #trigger_chars == #expected_chars then
  print('✅ Trigger characters match config')
else
  print('❌ Trigger characters do not match config')
end

-- Test completion context parsing
print('\n=== Testing Completion Context Parsing ===')

-- Mock completion context for different trigger characters
local test_cases = {
  {
    line = "This is a #test",
    cursor = {1, 14},  -- At end of line
    expected_input = "test",
    expected_trigger = "#",
    description = "mention_file trigger (#)"
  },
  {
    line = "Run /help command",
    cursor = {1, 8},   -- After /help
    expected_input = "help",
    expected_trigger = "/",
    description = "slash_commands trigger (/)"
  },
  {
    line = "No trigger here",
    cursor = {1, 15},
    expected_input = nil,
    expected_trigger = nil,
    description = "no trigger"
  }
}

for _, test_case in ipairs(test_cases) do
  print(string.format('\nTesting: %s', test_case.description))
  print(string.format('Line: "%s"', test_case.line))
  
  -- Simulate the completion context
  local before_cursor = test_case.line:sub(1, test_case.cursor[2])
  local mention_file_char = vim.pesc(config.get().keymap.window.mention_file)
  local slash_commands_char = vim.pesc(config.get().keymap.window.slash_commands)
  
  local mention_match, trigger_char
  
  -- Try mention_file trigger
  mention_match = before_cursor:match(mention_file_char .. '([%w_%-%.]*)')
  if mention_match then
    trigger_char = config.get().keymap.window.mention_file
  else
    -- Try slash_commands trigger
    mention_match = before_cursor:match(slash_commands_char .. '([%w_%-%.]*)')
    if mention_match then
      trigger_char = config.get().keymap.window.slash_commands
    end
  end
  
  if test_case.expected_input then
    if mention_match == test_case.expected_input and trigger_char == test_case.expected_trigger then
      print(string.format('✅ Correctly parsed: input="%s", trigger="%s"', mention_match, trigger_char))
    else
      print(string.format('❌ Parse failed: got input="%s" trigger="%s", expected input="%s" trigger="%s"', 
        mention_match or 'nil', trigger_char or 'nil', 
        test_case.expected_input, test_case.expected_trigger))
    end
  else
    if not mention_match then
      print('✅ Correctly identified no trigger')
    else
      print(string.format('❌ Unexpected match: input="%s" trigger="%s"', mention_match, trigger_char))
    end
  end
end

print('\n=== Testing Source Filtering ===')

-- Test that sources only complete for their appropriate triggers
local files_source = require('opencode.ui.completion.files').get_source()
local commands_source = require('opencode.ui.completion.commands').get_source()

-- Test files source with correct trigger
local context_files = {
  input = "test",
  trigger_char = config.get().keymap.window.mention_file
}
local files_result = files_source.complete(context_files)
print(string.format('Files source with # trigger: %d items', #files_result))

-- Test files source with wrong trigger
local context_files_wrong = {
  input = "test", 
  trigger_char = config.get().keymap.window.slash_commands
}
local files_result_wrong = files_source.complete(context_files_wrong)
print(string.format('Files source with / trigger: %d items', #files_result_wrong))

-- Test commands source with correct trigger
local context_commands = {
  input = "help",
  trigger_char = config.get().keymap.window.slash_commands
}
local commands_result = commands_source.complete(context_commands)
print(string.format('Commands source with / trigger: %d items', #commands_result))

-- Test commands source with wrong trigger
local context_commands_wrong = {
  input = "help",
  trigger_char = config.get().keymap.window.mention_file
}
local commands_result_wrong = commands_source.complete(context_commands_wrong)
print(string.format('Commands source with # trigger: %d items', #commands_result_wrong))

print('\n=== Test Complete ===')