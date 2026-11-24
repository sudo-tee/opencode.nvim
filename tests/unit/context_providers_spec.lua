local assert = require('luassert')
local stub = require('luassert.stub')
local providers = require('opencode.context.providers')
local chat_context = require('opencode.context.chat_context')
local base_context = require('opencode.context.base_context')

local function provider(overrides)
  return vim.tbl_extend('force', {
    name = 'notes',
    label = 'Notes',
    enabled = true,
    collect = function()
      return { { id = 'a', name = 'note.txt', text = 'note body' } }
    end,
  }, overrides or {})
end

describe('opencode.context.providers', function()
  before_each(function()
    providers._reset()
  end)

  after_each(function()
    providers._reset()
  end)

  it('rejects invalid, reserved, and duplicate names', function()
    assert.has_error(function()
      providers.register(provider({ name = 'bad name' }))
    end)
    assert.has_error(function()
      providers.register(provider({ name = 'selection' }))
    end)
    assert.has_error(function()
      providers.register(provider({ label = '' }))
    end)
    providers.register(provider())
    assert.has_error(function()
      providers.register(provider())
    end)
  end)

  it('is disabled unless enabled explicitly', function()
    local spec = provider()
    spec.enabled = nil
    providers.register(spec)
    assert.is_false(providers.is_enabled('notes'))
    assert.same({}, providers.collect(''))
    providers.set_enabled('notes', true)
    assert.equals(1, #providers.collect('')[1].items)
  end)

  it('isolates a failing provider from the others', function()
    providers.register(provider({
      name = 'broken',
      collect = function()
        error('boom')
      end,
    }))
    providers.register(provider({
      name = 'invalid',
      collect = function()
        return { { id = 'x', name = 'x.txt', text = '' } }
      end,
    }))
    providers.register(provider())

    local results = providers.collect('')

    assert.matches('boom', results[1].error)
    assert.same({}, results[1].items)
    assert.matches('non%-empty text', results[2].error)
    assert.is_nil(results[3].error)
    assert.equals(1, #results[3].items)
  end)

  it('passes the prompt to collect and forwards removal', function()
    local seen_prompt, removed
    providers.register(provider({
      collect = function(ctx)
        seen_prompt = ctx.prompt
        return {}
      end,
      remove = function(item)
        removed = item
      end,
    }))

    providers.collect('draft')
    providers.remove('notes', { id = 'a', name = 'note.txt', text = 'note body' })

    assert.equals('draft', seen_prompt)
    assert.equals('a', removed.id)
  end)

  it('returns reference items only while the prompt references them', function()
    providers.register(provider({
      reference = true,
      collect = function()
        return {
          { id = 'a', name = 'a.txt', text = 'A' },
          { id = 'b', name = 'b.txt', text = 'B' },
        }
      end,
    }))

    assert.same({}, providers.collect('nothing here')[1].items)
    assert.same({}, providers.collect('x@a.txt @b.txtx')[1].items)
    local items = providers.collect('see @b.txt, then')[1].items
    assert.equals(1, #items)
    assert.equals('b', items[1].id)
    assert.equals('@b.txt', providers.reference(items[1]))
  end)

  it('requires unique mention-safe names for reference items', function()
    stub(require('opencode.log'), 'error')
    providers.register(provider({
      reference = true,
      collect = function()
        return { { id = 'a', name = 'has space.txt', text = 'A' } }
      end,
    }))
    providers.register(provider({
      name = 'dupes',
      reference = true,
      collect = function()
        return {
          { id = 'a', name = 'same.txt', text = 'A' },
          { id = 'b', name = 'same.txt', text = 'B' },
        }
      end,
    }))

    local results = providers.collect('@has @same.txt')
    require('opencode.log').error:revert()
    assert.is_truthy(results[1].error)
    assert.is_truthy(results[2].error)
  end)

  it('uses the preview hook and falls back to the exact text', function()
    local item = { id = 'a', name = 'note.txt', text = 'note body' }
    assert.same({ text = 'note body' }, providers.preview(provider(), item))
    assert.same(
      { text = 'short' },
      providers.preview(
        provider({
          preview = function()
            return 'short'
          end,
        }),
        item
      )
    )
    assert.same(
      { text = '# md', filetype = 'markdown' },
      providers.preview(
        provider({
          preview = function()
            return { text = '# md', filetype = 'markdown' }
          end,
        }),
        item
      )
    )

    stub(require('opencode.log'), 'error')
    local fallback = providers.preview(
      provider({
        preview = function()
          error('boom')
        end,
      }),
      item
    )
    assert.stub(require('opencode.log').error).was_called(1)
    require('opencode.log').error:revert()
    assert.same({ text = 'note body' }, fallback)
  end)

  it('renders attachments with the first provider that accepts them, even when disabled', function()
    local attachment = { name = 'paste.txt', text = 'line 1\nline 2', media_type = 'text/plain' }
    assert.is_nil(providers.render(attachment))

    providers.register(provider({
      name = 'other',
      render = function()
        return nil
      end,
    }))
    providers.register(provider({
      enabled = false,
      render = function(a)
        return a.name == 'paste.txt' and a.text or nil
      end,
    }))
    assert.same({ 'line 1', 'line 2' }, providers.render(attachment))
    assert.is_nil(providers.render({ name = 'x.txt', text = 'x', media_type = 'text/plain' }))
  end)

  it('logs a failing render once and falls back', function()
    local log_error = stub(require('opencode.log'), 'error')
    providers.register(provider({
      render = function()
        return { 1 }
      end,
    }))
    local attachment = { name = 'a.txt', text = 'a', media_type = 'text/plain' }
    assert.is_nil(providers.render(attachment))
    assert.is_nil(providers.render(attachment))
    assert.stub(log_error).was_called(1)
    log_error:revert()
  end)

  describe('format_message', function()
    local original_get_current_buf

    before_each(function()
      original_get_current_buf = base_context.get_current_buf
      base_context.get_current_buf = function()
        return nil, nil
      end
    end)

    after_each(function()
      base_context.get_current_buf = original_get_current_buf
    end)

    it('attaches changed items and records their fingerprints', function()
      providers.register(provider())
      local submission = { automatic_context = {} }

      local sends = {}
      local captured =
        chat_context.format_message('hi', { submission_context = submission, provider_sends = sends }):wait()

      assert.same({ { name = 'note.txt', media_type = 'text/plain', bytes = 'note body' } }, captured.files)
      assert.equals('a', sends.notes[1].id)
      local key, fingerprint = providers.fingerprint('notes', sends.notes[1])
      assert.equals(fingerprint, submission.automatic_context[key])
      assert.is_true(providers.is_sent('notes', sends.notes[1], submission))

      local again_sends = {}
      local again = chat_context
        .format_message('hi', {
          previous_context = submission,
          submission_context = { automatic_context = {} },
          provider_sends = again_sends,
        })
        :wait()
      assert.same({}, again.files)
      assert.same({}, again_sends)
    end)

    it('sends reference items, linked to their token, only when the prompt references them', function()
      providers.register(provider({ reference = true }))

      local unreferenced = chat_context.format_message('hi', { submission_context = { automatic_context = {} } }):wait()
      assert.same({}, unreferenced.files)

      local referenced = chat_context
        .format_message('hi @note.txt_old @note.txt', { submission_context = { automatic_context = {} } })
        :wait()
      local start = #'hi @note.txt_old '
      assert.same({
        {
          name = 'note.txt',
          media_type = 'text/plain',
          bytes = 'note body',
          mention = { start_byte = start, end_byte = start + #'@note.txt' },
        },
      }, referenced.files)
    end)
  end)
end)
