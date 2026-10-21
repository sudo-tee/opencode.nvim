local assert = require('luassert')
local formatter = require('opencode.ui.formatter')
local normalize = require('opencode.protocols.v2.normalize')
local output_spinner = require('opencode.ui.output_spinner')
local output_window = require('opencode.ui.output_window')
local contexts = require('opencode.ui.renderer.ctx')
local background_tasks = require('opencode.services.background_tasks')
local footer = require('opencode.ui.footer')
local state = require('opencode.state')
local support = require('tests.unit.services_spec_support')

local BACKGROUND_TEXT = 'Command moved to the background (shell ID: sh_1).\n'
  .. 'Output is streaming to: /tmp/shell/sh_1.out'
local INSTRUCTION = 'You will be notified automatically when the command finishes. DO NOT poll for completion.'

---@param name string
---@param input table
---@param metadata table
---@param content table[]
---@param ids? {message?: string, call?: string}
local function assistant_with_tool(name, input, metadata, content, ids)
  ids = ids or {}
  return normalize.mapped_message('ses_bg', {
    id = ids.message or 'msg_bg',
    type = 'assistant',
    agent = 'build',
    time = { created = 1 },
    content = {
      {
        type = 'tool',
        id = ids.call or 'call_bg',
        name = name,
        time = { created = 1, ran = 2, completed = 3 },
        state = { status = 'completed', input = input, metadata = metadata, content = content },
      },
    },
  })
end

---@param shell_id? string
---@param ids? {message?: string, call?: string}
local function background_shell(shell_id, ids)
  return assistant_with_tool(
    'shell',
    { command = 'make build', background = true },
    { status = 'running', shellID = shell_id or 'sh_1', truncated = false },
    { { type = 'text', text = BACKGROUND_TEXT }, { type = 'text', text = INSTRUCTION } },
    ids
  )
end

---@param child_id? string
---@param ids? {message?: string, call?: string}
local function background_subagent(child_id, ids)
  return assistant_with_tool(
    'subagent',
    { description = 'explore' },
    { sessionID = child_id or 'ses_child', status = 'running' },
    { { type = 'text', text = 'The subagent is working in the background' } },
    ids
  )
end

---@param metadata table
---@param text string
local function notification(metadata, text)
  return normalize.mapped_message('ses_bg', {
    id = 'msg_note',
    type = 'synthetic',
    time = { created = 4 },
    text = text,
    metadata = metadata,
  })
end

---@param result? OpencodeV2BackgroundResult
---@param interactive? boolean
---@param tool? table
---@return FormatterContext
local function context(result, interactive, tool)
  return {
    interactive = interactive == true,
    get_background_result = function(id)
      return result and result.id == id and result or nil
    end,
    get_background_tool = function(id)
      return tool and tool.background.id == id and tool or nil
    end,
  }
end

---@param formatted Output
---@return table[]
local function badges(formatted)
  local found = {}
  for _, marks in pairs(formatted.extmarks) do
    for _, mark in ipairs(marks) do
      if type(mark) == 'table' and mark.virt_text_pos == 'eol' then
        found[#found + 1] = mark
      end
    end
  end
  return found
end

---@param mark table
---@return string
local function badge_text(mark)
  local text = {}
  for _, chunk in ipairs(mark.virt_text) do
    text[#text + 1] = chunk[1]
  end
  return table.concat(text)
end

describe('V2 background tasks', function()
  describe('normalization', function()
    it('marks a completed tool whose metadata status is still running as backgrounded', function()
      local tool = background_shell().content[1]
      assert.same({ id = 'sh_1' }, tool.background)
    end)

    it('leaves foreground shell results alone', function()
      local tool = assistant_with_tool(
        'shell',
        { command = 'ls' },
        { status = 'completed', shellID = 'sh_2', exit = 0 },
        { { type = 'text', text = 'file' } }
      ).content[1]
      assert.is_nil(tool.background)
    end)

    it('marks backgrounded subagents by their child session', function()
      local tool = assistant_with_tool(
        'subagent',
        { description = 'explore' },
        { sessionID = 'ses_child', status = 'running' },
        { { type = 'text', text = 'The subagent is working in the background' } }
      ).content[1]
      assert.same({ id = 'ses_child' }, tool.background)
      assert.same({ id = 'ses_child' }, tool.child_session)
    end)

    it('maps shell completion notifications without their model-facing envelope', function()
      local entry = notification(
        { source = 'shell', shellID = 'sh_1', jobID = 'job_1', state = 'completed', exit = 2, truncated = false },
        '<shell id="job_1" state="completed" command="make build">\nbuild failed\n\nExited with code 2\n</shell>'
      )
      assert.same({
        source = 'shell',
        id = 'sh_1',
        state = 'completed',
        exit = 2,
        truncated = false,
        text = 'build failed\n\nExited with code 2',
      }, entry.background_result)
    end)

    it('maps subagent completion notifications by child session id', function()
      local entry = notification(
        { source = 'subagent', childID = 'ses_child', agent = 'explore', state = 'completed' },
        '<subagent sessionID="ses_child" state="completed" description="explore">\nFound it\n</subagent>'
      )
      assert.equals('ses_child', entry.background_result.id)
      assert.equals('Found it', entry.background_result.text)
    end)

    it('ignores synthetic messages from other sources', function()
      local entry = notification({ source = 'other' }, 'hello')
      assert.is_nil(entry.background_result)
    end)
  end)

  describe('completion notices', function()
    it('renders a compact shell completion without a header or raw output', function()
      local note =
        notification({ source = 'shell', shellID = 'sh_1', state = 'completed', exit = 0 }, 'all checks passed')
      local tool = background_shell().content[1]
      tool.input.command = 'make check 2>&1 | tail -12'
      local output = formatter.format_part(note.content[1], note, true, context(nil, false, tool))
      assert.same({ '↳ Shell finished · make check 2>&1 | tail -12', '' }, output.lines)
      assert.same({}, formatter.format_message_header(note).lines)
      assert.equals('all checks passed', note.background_result.text)
    end)

    it('renders the agent name and task description', function()
      local note = notification(
        { source = 'subagent', childID = 'ses_child', state = 'completed' },
        '<subagent sessionID="ses_child" description="Wrong label">\nFound it\n</subagent>'
      )
      local tool = background_subagent().content[1]
      tool.input = { agent = 'code-reviewer', description = 'Review bg task commit' }
      local output = formatter.format_part(note.content[1], note, true, context(nil, false, tool))
      assert.equals('↳ Code-Reviewer finished · Review bg task commit', output.lines[1])
    end)

    it('shows failure outcomes instead of claiming success', function()
      local note = notification(
        { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 2 },
        '<shell id="sh_1" state="completed" command="make build">\nbuild failed\n</shell>'
      )
      local output =
        formatter.format_part(note.content[1], note, true, context(nil, false, background_shell().content[1]))
      assert.equals('↳ Shell exit 2 · make build', output.lines[1])
      assert.equals('DiagnosticError', output.extmarks[0][1].hl_group)
    end)

    it('falls back to the job id when the original tool is not loaded', function()
      local note = notification(
        { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 0 },
        '<shell command="Do not parse this">\nok\n</shell>'
      )
      assert.equals('↳ Shell finished · sh_1', formatter.format_part(note.content[1], note, true).lines[1])
    end)

    it('leaves unrelated synthetic messages hidden', function()
      local note = notification({ source = 'other' }, 'model-facing text')
      assert.same({}, formatter.format_part(note.content[1], note, true).lines)
    end)
  end)

  describe('background task counts', function()
    it('counts running shells and subagents separately', function()
      assert.same(
        { shells = 1, subagents = 1, total = 2 },
        background_tasks.count({
          background_shell(),
          background_subagent(),
        })
      )
    end)

    it('drops jobs once their completion notification is present', function()
      local note = notification(
        { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 0 },
        '<shell id="sh_1" state="completed" command="make build">\nok\n</shell>'
      )
      assert.same(
        { shells = 0, subagents = 1, total = 1 },
        background_tasks.count({
          background_shell(),
          background_subagent(),
          note,
        })
      )
    end)

    it('counts each background job id once', function()
      assert.same(
        { shells = 1, subagents = 0, total = 1 },
        background_tasks.count({
          background_shell(),
          background_shell(),
        })
      )
    end)

    it('keeps a shell counted until its own completion arrives', function()
      local note = notification(
        { source = 'shell', shellID = 'sh_2', state = 'completed', exit = 0 },
        '<shell id="sh_2" state="completed" command="make test">\nok\n</shell>'
      )
      assert.same(
        { shells = 1, subagents = 0, total = 1 },
        background_tasks.count({
          background_shell('sh_1', { message = 'msg_shell_1', call = 'call_shell_1' }),
          background_shell('sh_2', { message = 'msg_shell_2', call = 'call_shell_2' }),
          note,
        })
      )
    end)

    it('keeps a subagent counted until its own completion arrives', function()
      local note = notification(
        { source = 'subagent', childID = 'ses_b', agent = 'explore', state = 'completed' },
        '<subagent sessionID="ses_b" state="completed" description="explore">\ndone\n</subagent>'
      )
      assert.same(
        { shells = 0, subagents = 1, total = 1 },
        background_tasks.count({
          background_subagent('ses_a', { message = 'msg_agent_a', call = 'call_agent_a' }),
          background_subagent('ses_b', { message = 'msg_agent_b', call = 'call_agent_b' }),
          note,
        })
      )
    end)
  end)

  describe('shell formatter', function()
    it('hides model-facing instructions and points at the output file while running', function()
      local entry = background_shell()
      local formatted = formatter.format_part(entry.content[1], entry, true, context(nil, false))
      local text = table.concat(formatted.lines, '\n')

      assert.is_nil(text:find('DO NOT poll', 1, true))
      assert.is_nil(text:find('moved to the background', 1, true))
      assert.is_nil(text:find('> make build', 1, true))
      assert.is_truthy(text:find('`make build`', 1, true))
      assert.is_truthy(text:find('Output: /tmp/shell/sh_1.out', 1, true))

      local found = badges(formatted)
      assert.equals(1, #found)
      assert.equals(' Background ', badge_text(found[1]))
      assert.is_nil(found[1].spinner_chunk)
    end)

    it('animates the badge in interactive output', function()
      local entry = background_shell()
      local formatted = formatter.format_part(entry.content[1], entry, true, context(nil, true))
      local found = badges(formatted)
      assert.equals(1, #found)
      assert.equals(2, found[1].spinner_chunk)
    end)

    it('renders the job outcome once its notification arrives', function()
      local entry = background_shell()
      local result = notification(
        { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 2 },
        '<shell id="sh_1" state="completed" command="make build">\nbuild failed\n</shell>'
      ).background_result
      local formatted = formatter.format_part(entry.content[1], entry, true, context(result, true))
      local text = table.concat(formatted.lines, '\n')

      assert.is_truthy(text:find('build failed', 1, true))
      assert.is_nil(text:find('Output: ', 1, true))
      local found = badges(formatted)
      assert.equals(' Background · exit 2 ', badge_text(found[1]))
      assert.equals('OpencodeBackgroundBadgeFailed', found[1].virt_text[1][2])
      assert.is_nil(found[1].spinner_chunk)
    end)

    local outcomes = {
      {
        name = 'a clean exit',
        metadata = { exit = 0 },
        label = ' Background · done ',
        hl = 'OpencodeBackgroundBadge',
      },
      {
        name = 'a failing exit',
        metadata = { exit = 2 },
        label = ' Background · exit 2 ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
      {
        name = 'a signal',
        metadata = { signal = 'SIGKILL' },
        label = ' Background · killed by SIGKILL ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
      {
        name = 'a timeout',
        metadata = { timeout = true },
        label = ' Background · timed out ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
      {
        name = 'cancellation',
        metadata = { state = 'cancelled' },
        label = ' Background · cancelled ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
      {
        name = 'an error state',
        metadata = { state = 'error' },
        label = ' Background · failed ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
      {
        name = 'a timeout with a signal',
        metadata = { timeout = true, signal = 'SIGTERM', exit = 1 },
        label = ' Background · timed out ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
      {
        name = 'a signal with cancellation',
        metadata = { signal = 'SIGTERM', state = 'cancelled' },
        label = ' Background · killed by SIGTERM ',
        hl = 'OpencodeBackgroundBadgeFailed',
      },
    }

    for _, case in ipairs(outcomes) do
      it('labels ' .. case.name, function()
        local entry = background_shell()
        local result = notification(
          vim.tbl_extend('force', { source = 'shell', shellID = 'sh_1', state = 'completed' }, case.metadata),
          '<shell id="sh_1" state="completed">\nbody\n</shell>'
        ).background_result
        local formatted = formatter.format_part(entry.content[1], entry, true, context(result, true))
        local found = badges(formatted)

        assert.equals(1, #found)
        assert.equals(case.label, badge_text(found[1]))
        assert.equals(case.hl, found[1].virt_text[1][2])
        assert.is_nil(found[1].spinner_chunk)
      end)
    end

    it('renders a running job beside a completed one', function()
      local shell_1 = background_shell('sh_1', { message = 'msg_shell_1', call = 'call_shell_1' })
      local shell_2 = background_shell('sh_2', { message = 'msg_shell_2', call = 'call_shell_2' })
      local result = notification(
        { source = 'shell', shellID = 'sh_2', state = 'completed', exit = 0 },
        '<shell id="sh_2" state="completed" command="make test">\nok\n</shell>'
      ).background_result

      local running = formatter.format_part(shell_1.content[1], shell_1, true, context(result, true))
      local running_text = table.concat(running.lines, '\n')
      assert.is_truthy(running_text:find('Output: /tmp/shell/sh_1.out', 1, true))
      assert.equals('  Background ', badge_text(badges(running)[1]))

      local completed_output = formatter.format_part(shell_2.content[1], shell_2, true, context(result, true))
      local completed = table.concat(completed_output.lines, '\n')
      assert.is_nil(completed:find('Output: ', 1, true))
      assert.equals(' Background · done ', badge_text(badges(completed_output)[1]))
    end)
  end)

  describe('renderer context', function()
    it('indexes original tool inputs by job id and clears stale jobs', function()
      local ctx = contexts.new()
      local shell = background_shell()
      local agent = background_subagent()
      ctx:set_entries({ shell, agent })
      assert.equals(shell.content[1], ctx.background_tools.sh_1)
      assert.equals(agent.content[1], ctx.background_tools.ses_child)
      ctx:set_entries({ agent })
      assert.is_nil(ctx.background_tools.sh_1)
      ctx:reset()
      assert.same({}, ctx.background_tools)
    end)

    it('indexes background outcomes from observed entries', function()
      local ctx = contexts.new()
      local note = notification(
        { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 0 },
        '<shell id="sh_1" state="completed" command="make">\nok\n</shell>'
      )
      ctx:set_entries({ background_shell(), note })
      assert.equals(note.background_result, ctx.background_results.sh_1)
    end)

    it('links a shell completion to its own block only', function()
      local ctx = contexts.new()
      local note = notification(
        { source = 'shell', shellID = 'sh_2', state = 'completed', exit = 2 },
        '<shell id="sh_2" state="completed" command="make test">\nfailed\n</shell>'
      )
      ctx:set_entries({
        background_shell('sh_1', { message = 'msg_shell_1', call = 'call_shell_1' }),
        background_shell('sh_2', { message = 'msg_shell_2', call = 'call_shell_2' }),
        note,
      })
      assert.is_nil(ctx.background_results.sh_1)
      assert.equals(note.background_result, ctx.background_results.sh_2)
    end)

    it('links a subagent completion to its own child session only', function()
      local ctx = contexts.new()
      local note = notification(
        { source = 'subagent', childID = 'ses_b', agent = 'explore', state = 'completed' },
        '<subagent sessionID="ses_b" state="completed" description="explore">\ndone\n</subagent>'
      )
      ctx:set_entries({
        background_subagent('ses_a', { message = 'msg_agent_a', call = 'call_agent_a' }),
        background_subagent('ses_b', { message = 'msg_agent_b', call = 'call_agent_b' }),
        note,
      })
      assert.is_nil(ctx.background_results.ses_a)
      assert.equals(note.background_result, ctx.background_results.ses_b)
    end)
  end)

  describe('output spinner', function()
    local buf

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'header' })
    end)

    after_each(function()
      output_spinner.stop()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    local function spinner_marks()
      return vim.api.nvim_buf_get_extmarks(buf, output_spinner.namespace, 0, -1, { details = true })
    end

    it('animates only the frame chunk without touching buffer lines', function()
      output_window.apply_extmarks(buf, {
        [0] = {
          {
            virt_text = { { ' ', 'A' }, { '', 'A' }, { ' Background ', 'A' } },
            virt_text_pos = 'eol',
            spinner_chunk = 2,
          },
        },
      })

      local marks = spinner_marks()
      assert.equals(1, #marks)
      local first = marks[1][4].virt_text[2][1]
      assert.is_true(output_spinner.is_running())
      assert.same({}, vim.api.nvim_buf_get_extmarks(buf, output_window.namespace, 0, -1, {}))

      vim.wait(500, function()
        return spinner_marks()[1][4].virt_text[2][1] ~= first
      end, 20)

      marks = spinner_marks()
      assert.are_not.equal(first, marks[1][4].virt_text[2][1])
      assert.equals(' Background ', marks[1][4].virt_text[3][1])
      assert.same({ 'header' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it('stops once its extmarks are cleared', function()
      output_window.apply_extmarks(buf, {
        [0] = { { virt_text = { { '', 'A' } }, virt_text_pos = 'eol', spinner_chunk = 1 } },
      })
      assert.is_true(output_spinner.is_running())
      vim.api.nvim_buf_clear_namespace(buf, output_spinner.namespace, 0, -1)

      vim.wait(500, function()
        return not output_spinner.is_running()
      end, 20)
      assert.is_false(output_spinner.is_running())
    end)
  end)

  describe('footer counter', function()
    local original
    local observation
    local footer_windows
    local watchers

    local function set_entries(entries)
      observation._state.entries_by_id = {}
      observation._state.entry_order = {}
      for index, entry in ipairs(entries) do
        local key = string.format('%s:%d', entry.id, index)
        observation._state.entries_by_id[key] = entry
        observation._state.entry_order[index] = key
      end
    end

    local function notify_messages()
      for _, watcher in ipairs(watchers) do
        if vim.tbl_contains(watcher.resources, 'messages') then
          watcher.changed(observation)
        end
      end
    end

    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(footer_windows.footer_buf, 0, -1, false), '')
    end

    local function spinner_marks()
      return vim.api.nvim_buf_get_extmarks(
        footer_windows.footer_buf,
        output_spinner.namespace,
        0,
        -1,
        { details = true }
      )
    end

    local function badge_covers(col)
      local ns = vim.api.nvim_get_namespaces()['opencode_footer']
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(footer_windows.footer_buf, ns, 0, -1, { details = true })) do
        local details = mark[4]
        if
          details.hl_group == 'OpencodeBackgroundBadge'
          and col >= mark[3]
          and col < (details.end_col or mark[3] + 1)
        then
          return true
        end
      end
      return false
    end

    before_each(function()
      original = support.snapshot_state()
      output_spinner.stop()
      local connection = support.mock_connection()
      connection.session_facts = { ses_bg = { id = 'ses_bg' } }
      state.session.set_active({ id = 'ses_bg' })
      observation = state.session.active_observation()
      watchers = {}
      observation.watch = function(_, resources, changed)
        local watcher = { resources = resources, changed = changed }
        watchers[#watchers + 1] = watcher
        return function()
          for index, candidate in ipairs(watchers) do
            if candidate == watcher then
              table.remove(watchers, index)
              break
            end
          end
        end
      end
      footer_windows = {
        output_win = vim.api.nvim_get_current_win(),
        output_buf = vim.api.nvim_get_current_buf(),
        footer_buf = footer.create_buf(),
      }
      state.store.set_raw('windows', footer_windows)
      footer.setup(footer_windows)
    end)

    after_each(function()
      footer.close()
      output_spinner.stop()
      support.restore_state(original)
    end)

    it('renders the count with an animated spinner and drops it on completion', function()
      set_entries({ background_shell() })
      notify_messages()
      assert.is_truthy(text():find('1 shell', 1, true))
      assert.equals(1, #spinner_marks())

      local line = text()
      local label_start = assert(line:find('1 shell', 1, true))
      local mark = spinner_marks()[1]
      local spinner_col = mark[3]
      assert.equals(label_start - 1 + #'1 shell' + 1, spinner_col)
      assert.equals('OpencodeBackgroundBadge', mark[4].virt_text[1][2])
      assert.is_true(badge_covers(spinner_col - 1))
      assert.is_true(badge_covers(spinner_col + 1))

      set_entries({ background_shell(), background_subagent() })
      notify_messages()
      assert.is_truthy(text():find('2 tasks', 1, true))

      local shell_note = notification(
        { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 0 },
        '<shell id="sh_1" state="completed" command="make build">\nok\n</shell>'
      )
      local agent_note = notification(
        { source = 'subagent', childID = 'ses_child', state = 'completed' },
        '<subagent sessionID="ses_child" state="completed" description="explore">\nFound it\n</subagent>'
      )
      set_entries({ background_shell(), background_subagent(), shell_note, agent_note })
      notify_messages()

      assert.is_nil(text():find('shell', 1, true))
      assert.is_nil(text():find('agent', 1, true))
      assert.is_nil(text():find('task', 1, true))
      assert.equals(0, #spinner_marks())
    end)
  end)
end)
