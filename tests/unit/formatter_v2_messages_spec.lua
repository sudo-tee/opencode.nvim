local assert = require('luassert')
local formatter = require('opencode.ui.formatter')
local normalize = require('opencode.protocols.v2.normalize')

describe('V2 native message rendering', function()
  local function render(info)
    info.id = 'msg_native'
    info.time = { created = 1 }
    local entry = normalize.mapped_message('ses_native', info)
    assert.equals(1, #entry.content)
    return table.concat(formatter.format_part(entry.content[1], entry, true).lines, '\n')
  end

  it('renders system text', function()
    assert.equals('Catalog updated\nSecond line\n', render({ type = 'system', text = 'Catalog updated\nSecond line' }))
  end)

  it('renders a loaded skill name and instructions', function()
    local text =
      render({ type = 'skill', skill = 'review', name = 'Code review', text = 'Review changes\nCheck tests' })
    assert.is_truthy(text:find('Loaded skill', 1, true))
    assert.is_truthy(text:find('Code review', 1, true))
    assert.is_truthy(text:find('Review changes\nCheck tests', 1, true))
  end)

  it('renders structured shell output without exposing its envelope', function()
    local text = render({
      type = 'shell',
      shellID = 'sh_native',
      command = 'pwd',
      status = 'exited',
      exit = 0,
      output = { output = '/project', cursor = 8, size = 8, truncated = true },
    })
    assert.is_truthy(text:find('Shell exited', 1, true))
    assert.is_truthy(text:find('pwd', 1, true))
    assert.is_truthy(text:find('Exit code: 0', 1, true))
    assert.is_truthy(text:find('/project', 1, true))
    assert.is_truthy(text:find('Shell output truncated.', 1, true))
    assert.is_nil(text:find('cursor', 1, true))
  end)

  it('renders shell commands before output arrives', function()
    local text = render({ type = 'shell', shellID = 'sh_native', command = 'make test', status = 'running' })
    assert.is_truthy(text:find('Shell running', 1, true))
    assert.is_truthy(text:find('make test', 1, true))
    assert.is_nil(text:find('Exit code', 1, true))
  end)

  it('retains legacy string shell output', function()
    local text =
      render({ type = 'shell', shellID = 'sh_native', command = 'pwd', status = 'exited', output = '/project' })
    assert.is_truthy(text:find('/project', 1, true))
  end)

  it('renders completed compaction summary and recent context', function()
    local text =
      render({ type = 'compaction', status = 'completed', reason = 'auto', summary = 'Summary', recent = 'Recent' })
    assert.is_truthy(text:find('Session compacted', 1, true))
    assert.is_nil(text:find('Reason:', 1, true))
    assert.is_truthy(text:find('**Summary**', 1, true))
    assert.is_truthy(text:find('**Recent context**', 1, true))
    assert.is_truthy(text:find('Summary', 1, true))
    assert.is_truthy(text:find('Recent', 1, true))
  end)

  it('renders running compaction with no summary yet', function()
    local text = render({ type = 'compaction', status = 'running', reason = 'manual', summary = '', recent = '' })
    assert.is_truthy(text:find('Compacting session…', 1, true))
    assert.is_truthy(text:find('Condensing conversation history.', 1, true))
    assert.is_nil(text:find('**Summary**', 1, true))
    assert.is_nil(text:find('**Recent context**', 1, true))
    assert.is_nil(text:find('\n\n', 1, true))
    assert.is_nil(text:find('Session compacted', 1, true))
  end)

  it('renders failed compaction error', function()
    local text = render({
      type = 'compaction',
      status = 'failed',
      reason = 'manual',
      error = { name = 'ProviderError', message = 'Provider unavailable' },
    })
    assert.is_truthy(text:find('Compaction failed', 1, true))
    assert.is_nil(text:find('[!ERROR]', 1, true))
    assert.is_truthy(text:find('Provider unavailable', 1, true))
  end)

  it('renders nonempty partial compaction text and hides whitespace-only sections', function()
    local text = render({
      type = 'compaction',
      status = 'running',
      reason = 'auto',
      summary = 'Summarizing earlier decisions…',
      recent = ' \n\t',
    })
    assert.is_truthy(text:find('**Summary**\nSummarizing earlier decisions…', 1, true))
    assert.is_nil(text:find('**Recent context**', 1, true))
  end)

  it('renders current and previous session directories', function()
    local text = render({
      type = 'location-switched',
      location = { directory = '/new' },
      projectID = 'project',
      previous = { location = { directory = '/old' }, projectID = 'project' },
    })
    assert.is_truthy(text:find('Session directory: `/new`', 1, true))
    assert.is_truthy(text:find('Previous directory: `/old`', 1, true))
  end)

  it('renders location changes without a previous directory', function()
    local text = render({ type = 'location-switched', location = { directory = '/new' }, projectID = 'project' })
    assert.is_truthy(text:find('Session directory: `/new`', 1, true))
    assert.is_nil(text:find('Previous directory', 1, true))
  end)
end)
