local assert = require('luassert')
local stub = require('luassert.stub')
local providers = require('opencode.context.providers')
local chat_context = require('opencode.context.chat_context')
local base_context = require('opencode.context.base_context')

describe('paste-as-attachment recipe', function()
  local attach, provider, references
  local getreg, get_current_buf

  before_each(function()
    providers._reset()
    references = {}
    getreg = stub(vim.fn, 'getreg', function()
      return 'query { pageBySlug { title } }'
    end)
    get_current_buf = stub(base_context, 'get_current_buf', function()
      return nil, nil
    end)

    local opencode = {
      setup = function(opts)
        attach = opts.keymap.input_window['<C-g>p'][1]
      end,
      register_context_provider = providers.register,
      insert_context_reference = function(item)
        references[#references + 1] = providers.reference(item)
      end,
    }
    local markdown = table.concat(vim.fn.readfile('docs/recipes/paste-as-attachment.md'), '\n')
    local source = assert(markdown:match('```lua\n(.-)\n```'))
    local recipe = assert(loadstring(source, '@paste-as-attachment recipe'))
    setfenv(
      recipe,
      setmetatable({
        require = function(name)
          assert.equals('opencode', name)
          return opencode
        end,
      }, { __index = _G })
    )
    recipe()
    provider = providers.list()[1]
  end)

  after_each(function()
    getreg:revert()
    get_current_buf:revert()
    providers._reset()
  end)

  it('sends inline content with an explicit explanation that the name is not a disk file', function()
    attach()
    local prompt = references[1] .. ' use this query'
    local captured = chat_context.format_message(prompt, { submission_context = {} }):wait()

    assert.equals(prompt, captured.text)
    assert.equals(1, #captured.files)
    local file = captured.files[1]
    assert.equals(references[1], '@' .. file.name)
    assert.equals('text/plain', file.media_type)
    assert.is_nil(file.server_uri)
    assert.equals(
      'This attachment contains inline pasted text, not a file on disk. Use the content below directly.\n\n'
        .. 'query { pageBySlug { title } }',
      file.bytes
    )
    assert.same({ start_byte = 0, end_byte = #references[1] }, file.mention)
  end)

  it('uses short unique references and keeps the counter across sends', function()
    attach()
    attach()

    assert.equals('@pasted_text_1', references[1])
    assert.equals('@pasted_text_2', references[2])
    local result = providers.collect(table.concat(references, ' '))[1]
    assert.is_nil(result.error)
    assert.equals(2, #result.items)

    provider.on_sent(result.items)
    assert.same({}, provider.collect())
    attach()
    assert.equals('@pasted_text_3', references[3])
  end)

  it('previews and renders only the original paste with a safe code fence', function()
    local text = 'first\n```text\nsecond\n````\nlast\n'
    getreg:revert()
    getreg = stub(vim.fn, 'getreg', function()
      return text
    end)
    attach()
    local item = providers.collect(references[1])[1].items[1]

    assert.same({ text = text }, providers.preview(provider, item))
    assert.same(
      { '`````text', text, '`````' },
      provider.render({ name = item.name, text = item.text, media_type = 'text/plain' })
    )
  end)

  it('still renders older unwrapped paste attachments from history', function()
    for _, name in ipairs({
      'pasted_text_20261124_082441.txt',
      'pasted_text_20261124_082441_1.txt',
      'pasted_text_20261124_082441_1',
    }) do
      assert.same(
        { '```text', 'original paste', '```' },
        provider.render({ name = name, text = 'original paste', media_type = 'text/plain' })
      )
    end
    assert.is_nil(provider.render({ name = 'notes.txt', text = 'notes', media_type = 'text/plain' }))
  end)
end)
