local assert = require('luassert')

describe('entry contracts', function()
  it('keeps default keymap string actions command-routable', function()
    local config = require('opencode.config')
    local commands = require('opencode.commands')
    local defs = commands.get_commands()

    local checked = 0
    for _, section in ipairs({ 'editor', 'input_window', 'output_window' }) do
      for key, keymap_entry in pairs(config.defaults.keymap[section] or {}) do
        local action = keymap_entry and keymap_entry[1]
        if type(action) == 'string' then
          checked = checked + 1
          assert.is_not_nil(
            defs[action],
            string.format('Unroutable keymap action %s -> %s in %s', key, action, section)
          )
        end
      end
    end

    assert.is_true(checked > 0, 'Expected to validate at least one keymap action')
  end)

  it('keeps builtin slash commands command-addressable', function()
    local commands = require('opencode.commands')
    local slash = require('opencode.commands.slash')
    local command_defs = commands.get_commands()

    for slash_cmd, def in pairs(slash.get_builtin_command_definitions()) do
      assert.is_string(def.cmd_str, slash_cmd .. ' should define cmd_str routing')
      assert.is_true(#def.cmd_str > 0, slash_cmd .. ' cmd_str should not be empty')
      local top_cmd = vim.split(def.cmd_str, ' ', { trimempty = true })[1]
      assert.truthy(command_defs[top_cmd], slash_cmd .. ' points to unknown command: ' .. tostring(top_cmd))
    end
  end)
end)
