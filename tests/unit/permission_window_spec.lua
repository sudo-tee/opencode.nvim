local permission_window = require('opencode.ui.permission_window')
local Output = require('opencode.ui.output')

describe('permission_window', function()
  after_each(function()
    permission_window._permission_queue = {}
    permission_window._dialog = nil
    permission_window._processing = false
  end)

  it('escapes line breaks in permission titles for display', function()
    local captured_opts = nil
    permission_window._dialog = {
      format_dialog = function(_, _, opts)
        captured_opts = opts
      end,
    }

    permission_window._permission_queue = {
      {
        id = 'per_test',
        permission = 'bash',
        patterns = {
          "python3 - <<'PY'\nprint('hello')\nPY",
        },
      },
    }

    local output = Output.new()
    permission_window.format_display(output)

    assert.is_not_nil(captured_opts)
    assert.is_not_nil(captured_opts.content)
    assert.are.equal(1, #captured_opts.content)

    local rendered_title = captured_opts.content[1]
    local expected_pattern = "python3 - <<'PY'\\nprint('hello')\\nPY"
    assert.is_true(rendered_title:find('`' .. expected_pattern .. '`', 1, true) ~= nil)
    assert.is_nil(rendered_title:find('\n', 1, true))
  end)
end)
