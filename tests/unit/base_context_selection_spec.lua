local base_context = require('opencode.context.base_context')
local state = require('opencode.state')
local assert = require('luassert')

describe('visual selection buffer ownership', function()
  local original_buf
  local original_code_buf
  local buffers
  local context_config = { selection = { enabled = true } }

  local function leave_visual()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', true)
  end

  local function create_buffer(name, buftype, text)
    local buf = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = buf
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = buftype
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    original_buf = vim.api.nvim_get_current_buf()
    original_code_buf = state.current_code_buf
    buffers = {}
  end)

  after_each(function()
    leave_visual()
    vim.api.nvim_set_current_buf(original_buf)
    state.ui.set_current_code_buf(original_code_buf)
    for _, buf in ipairs(buffers) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it('ignores explorer Visual mode without consuming its selection', function()
    local code_buf = create_buffer('/tmp/opencode/selection-code.md', '', '# Heading')
    state.ui.set_current_code_buf(code_buf)
    create_buffer('snacks_picker_list', 'nofile', '#')
    vim.cmd('normal! v')

    assert.is_nil(base_context.get_current_selection(context_config))
    assert.equals('v', vim.fn.mode())
  end)

  it('does not attribute another file selection to the remembered code buffer', function()
    local code_buf = create_buffer('/tmp/opencode/selection-code.md', '', '# Heading')
    state.ui.set_current_code_buf(code_buf)
    create_buffer('/tmp/opencode/selection-other.md', '', '# Other')
    vim.cmd('normal! v')

    assert.is_nil(base_context.get_current_selection(context_config))
    assert.equals('v', vim.fn.mode())
  end)

  it('keeps legitimate single-character selections in the code buffer', function()
    local code_buf = create_buffer('/tmp/opencode/selection-code.md', '', '# Heading')
    state.ui.set_current_code_buf(code_buf)
    vim.cmd('normal! v')

    assert.same({ text = '#', lines = '1, 1' }, base_context.get_current_selection(context_config))
  end)

  it('captures file selections when no code buffer has been remembered', function()
    create_buffer('/tmp/opencode/selection-code.md', '', '# Heading')
    state.ui.set_current_code_buf(nil)
    vim.cmd('normal! V')

    assert.same({ text = '# Heading\n', lines = '1, 1' }, base_context.get_current_selection(context_config))
  end)
end)
