local assert = require('luassert')
local normalize = require('opencode.protocols.v1.normalize')
local helpers = require('tests.helpers')
local formatter = require('opencode.ui.formatter')

---@param payload table
---@return table
local function part(payload)
  return {
    id = 'prt-context',
    sessionID = 'ses-context',
    messageID = 'msg-context',
    type = 'text',
    synthetic = true,
    text = vim.json.encode(payload),
  }
end

describe('V1 historical synthetic editor context', function()
  it('maps legacy selection JSON to the same facts as declared metadata', function()
    local native = part({
      context_type = 'selection',
      content = '```lua\nreturn value\n```',
      lines = '8, 9',
      file = { name = 'main.lua' },
    })
    local original = vim.deepcopy(native)
    local legacy, diagnostic = normalize.mapped_content(native)
    native.metadata = { context_type = 'selection' }
    local current = normalize.mapped_content(native)

    assert.is_nil(diagnostic)
    assert.same(current, legacy)
    assert.equals('editor_context', legacy.kind)
    assert.same({ kind = 'selection', file_name = 'main.lua', range = '8, 9' }, legacy.source)
    native.metadata = nil
    assert.same(original, native)
  end)

  it('preserves cursor excerpts and surrounding lines', function()
    local content, diagnostic = normalize.mapped_content(part({
      context_type = 'cursor-data',
      line = 59,
      column = 1,
      line_content = 'local value = true',
      lines_before = { 'before' },
      lines_after = { 'after' },
    }))

    assert.is_nil(diagnostic)
    assert.equals('editor_context', content.kind)
    assert.equals('cursor', content.source.kind)
    assert.equals(59, content.line)
    assert.equals(1, content.column)
    assert.equals('local value = true', content.line_content)
    assert.same({ 'before' }, content.lines_before)
    assert.same({ 'after' }, content.lines_after)
  end)

  it('maps compact diagnostics without requiring metadata', function()
    local content, diagnostic = normalize.mapped_content(part({
      context_type = 'diagnostics',
      content = { { msg = 'bad value', severity = 2, pos = 'l8:c3' } },
    }))

    assert.is_nil(diagnostic)
    assert.equals('diagnostics', content.source.kind)
    assert.same({ { message = 'bad value', severity = 2, position = 'l8:c3' } }, content.diagnostics)
  end)

  it('renders valid legacy hint diagnostics without dropping or crashing on their severity', function()
    local content = normalize.mapped_content(part({
      context_type = 'diagnostics',
      content = { { message = 'hint', severity = 4, lnum = 0, col = 0 } },
    }))
    local output = require('opencode.ui.output').new()

    formatter._format_diagnostics_context(output, content)

    assert.equals('**Diagnostics:** ' .. require('opencode.ui.icons').get('info') .. '(1)', output.lines[1])
  end)

  it('connects trailing file borders to normalized selection and cursor context', function()
    for _, payload in ipairs({
      { context_type = 'selection', content = 'selected code' },
      { context_type = 'cursor-data', line = 1, column = 1, line_content = 'cursor code' },
    }) do
      local context = normalize.mapped_content(part(payload))
      local file = { id = 'prt-file', kind = 'file', name = 'main.lua' }
      local output = formatter.format_part(file, { id = 'msg-user', kind = 'user', content = { context, file } }, true)

      assert.is_not_nil(output.extmarks[-1])
    end
  end)

  it('converts raw Neovim diagnostics to neutral messages and one-based positions', function()
    local native = part({
      context_type = 'diagnostics',
      file = 'main.lua',
      content = {
        { message = 'bad value', severity = 2, lnum = 7, col = 2, bufnr = 13 },
        { msg = 'compact entry', severity = 1, pos = 'l9:c1' },
      },
    })
    local original = vim.deepcopy(native)
    local content, diagnostic = normalize.mapped_content(native)

    assert.is_nil(diagnostic)
    assert.same({ kind = 'diagnostics', file_name = 'main.lua' }, content.source)
    assert.same({
      { message = 'bad value', severity = 2, position = 'l8:c3' },
      { message = 'compact entry', severity = 1, position = 'l9:c1' },
    }, content.diagnostics)
    assert.same(original, native)
  end)

  it('keeps explicit metadata authoritative rather than guessing another context type', function()
    local native = part({ context_type = 'selection', content = 'selected code' })
    native.metadata = { context_type = 'cursor-data' }
    local content, diagnostic = normalize.mapped_content(native)

    assert.equals('text', content.kind)
    assert.equals(native.text, content.text)
    assert.matches('invalid cursor%-data editor context JSON', diagnostic)
  end)

  it('leaves non-synthetic prompts and ordinary synthetic JSON untouched', function()
    local prompt = part({ context_type = 'selection', content = 'not an attachment' })
    prompt.synthetic = false
    local ordinary = part({ content = 'ordinary JSON' })
    local unknown = part({ context_type = 'unknown', content = 'ordinary JSON' })
    for _, native in ipairs({ prompt, ordinary, unknown }) do
      local content, diagnostic = normalize.mapped_content(native)
      assert.equals('text', content.kind)
      assert.equals(native.text, content.text)
      assert.is_nil(diagnostic)
    end
  end)

  it('does not reinterpret malformed synthetic JSON', function()
    local native = part({})
    native.text = 'Called the Read tool with the following input: {"filePath":"main.lua"}'
    local content, diagnostic = normalize.mapped_content(native)

    assert.equals('text', content.kind)
    assert.equals(native.text, content.text)
    assert.is_nil(diagnostic)
  end)

  it('diagnoses invalid declared legacy context without losing its original text', function()
    for _, payload in ipairs({
      { context_type = 'selection', content = {} },
      { context_type = 'cursor-data', line = 'invalid', column = 1, line_content = 'text' },
      { context_type = 'diagnostics', content = { { message = 'bad value', severity = 2, lnum = -1, col = 0 } } },
      {
        context_type = 'diagnostics',
        content = { { msg = 'good', severity = 2, pos = 'l1:c1' }, { message = 'bad', severity = 2 } },
      },
    }) do
      local native = part(payload)
      local content, diagnostic = normalize.mapped_content(native)
      assert.equals('text', content.kind)
      assert.equals(native.text, content.text)
      assert.is_not_nil(diagnostic)
    end
  end)

  it('decodes the historical selection, cursor, and diagnostics replay fixtures', function()
    local expected = { selection = 2, cursor_data = 1, diagnostics = 1 }
    for fixture, count in pairs(expected) do
      local decoded = {}
      for _, event in ipairs(helpers.load_test_data('tests/data/' .. fixture .. '.json')) do
        if event.type == 'message.part.updated' then
          local content = normalize.mapped_content(event.properties.part)
          if content.kind == 'editor_context' then
            decoded[content.id] = content
          end
        end
      end
      assert.equals(count, vim.tbl_count(decoded))
      if fixture == 'diagnostics' then
        local diagnostics = vim.tbl_values(decoded)[1].diagnostics
        assert.equals(3, #diagnostics)
        assert.equals('l131:c21', diagnostics[1].position)
      end
    end
  end)
end)
