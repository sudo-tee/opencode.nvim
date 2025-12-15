local util = require('opencode.util')

describe('util.parse_dot_args', function()
  it('parses flat booleans', function()
    local args = util.parse_dot_args('context=false foo=true')
    assert.are.same({ context = false, foo = true }, args)
  end)

  it('parses nested dot notation', function()
    local args = util.parse_dot_args('context.enabled=false context.selection.enabled=true')
    assert.are.same({ context = { enabled = false, selection = { enabled = true } } }, args)
  end)

  it('parses mixed nesting and booleans', function()
    local args = util.parse_dot_args('context=false context.enabled=true context.selection.enabled=false foo=bar')
    assert.are.same({ context = { enabled = true, selection = { enabled = false } }, foo = 'bar' }, args)
  end)

  it('parses numbers', function()
    local args = util.parse_dot_args('foo=42 bar=3.14')
    assert.are.same({ foo = 42, bar = 3.14 }, args)
  end)

  it('handles empty string', function()
    local args = util.parse_dot_args('')
    assert.are.same({}, args)
  end)
end)

describe('util.parse_run_args', function()
  it('parses no prefixes', function()
    local opts, prompt = util.parse_run_args({ 'just', 'a', 'regular', 'prompt' })
    assert.are.same({}, opts)
    assert.equals('just a regular prompt', prompt)
  end)

  it('parses single agent prefix', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan', 'hello', 'world' })
    assert.are.same({ agent = 'plan' }, opts)
    assert.equals('hello world', prompt)
  end)

  it('parses single model prefix', function()
    local opts, prompt = util.parse_run_args({ 'model=openai/gpt-4', 'analyze', 'this' })
    assert.are.same({ model = 'openai/gpt-4' }, opts)
    assert.equals('analyze this', prompt)
  end)

  it('parses single context prefix', function()
    local opts, prompt = util.parse_run_args({ 'context=current_file.enabled=false', 'test' })
    assert.are.same({ context = { current_file = { enabled = false } } }, opts)
    assert.equals('test', prompt)
  end)

  it('parses multiple prefixes in order', function()
    local opts, prompt = util.parse_run_args({
      'agent=plan',
      'model=openai/gpt-4',
      'context=current_file.enabled=false',
      'prompt',
      'here',
    })
    assert.are.same({
      agent = 'plan',
      model = 'openai/gpt-4',
      context = { current_file = { enabled = false } },
    }, opts)
    assert.equals('prompt here', prompt)
  end)

  it('parses context with multiple comma-delimited values', function()
    local opts, prompt = util.parse_run_args({ 'context=current_file.enabled=false,selection.enabled=true', 'test' })
    assert.are.same({
      context = {
        current_file = { enabled = false },
        selection = { enabled = true },
      },
    }, opts)
    assert.equals('test', prompt)
  end)

  it('handles empty prompt after prefixes', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan' })
    assert.are.same({ agent = 'plan' }, opts)
    assert.equals('', prompt)
  end)

  it('handles empty string', function()
    local opts, prompt = util.parse_run_args({})
    assert.are.same({}, opts)
    assert.equals('', prompt)
  end)

  it('stops parsing at first non-prefix token', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan', 'some', 'prompt', 'model=openai/gpt-4' })
    assert.are.same({ agent = 'plan' }, opts)
    assert.equals('some prompt model=openai/gpt-4', prompt)
  end)
end)

describe('util.format_time', function()
  local function make_timestamp(year, month, day, hour, min, sec)
    return os.time({ year = year, month = month, day = day, hour = hour or 0, min = min or 0, sec = sec or 0 })
  end

  local today = os.date('*t')
  local today_morning = make_timestamp(today.year, today.month, today.day, 8, 30, 0)
  local today_afternoon = make_timestamp(today.year, today.month, today.day, 15, 45, 30)
  local today_evening = make_timestamp(today.year, today.month, today.day, 23, 59, 59)

  local yesterday = os.time() - 86400 -- 24 hours ago
  local last_week = os.time() - (7 * 86400) -- 7 days ago
  local last_month = os.time() - (30 * 86400) -- 30 days ago
  local next_year = make_timestamp(today.year + 1, 6, 15, 12, 0, 0)

  describe('today timestamps', function()
    it('formats morning time correctly', function()
      local result = util.format_time(today_morning)
      assert.matches('^%d%d?:%d%d [AP]M$', result)
      assert.is_nil(result:match('%d%d%d%d'))
    end)

    it('formats afternoon time correctly', function()
      local result = util.format_time(today_afternoon)
      assert.matches('^%d%d?:%d%d [AP]M$', result)
      assert.is_nil(result:match('%d%d%d%d'))
    end)

    it('formats late evening time correctly', function()
      local result = util.format_time(today_evening)
      assert.matches('^%d%d?:%d%d [AP]M$', result)
      assert.is_nil(result:match('%d%d%d%d'))
    end)

    it('formats current time as time-only', function()
      local current_time = os.time()
      local result = util.format_time(current_time)
      assert.matches('^%d%d?:%d%d [AP]M$', result)
      assert.is_nil(result:match('%d%d%d%d'))
    end)
  end)

  describe('other day timestamps', function()
    it('formats yesterday with date', function()
      local result = util.format_time(yesterday)
      local yesterday_date = os.date('*t', yesterday)
      if yesterday_date.year == today.year then
        assert.matches('^%d%d? %a%a%a %d%d?:%d%d [AP]M$', result)
      else
        assert.matches('^%d%d? %a%a%a %d%d%d%d %d%d?:%d%d [AP]M$', result)
      end
    end)

    it('formats last week with date', function()
      local result = util.format_time(last_week)
      local last_week_date = os.date('*t', last_week)
      if last_week_date.year == today.year then
        assert.matches('^%d%d? %a%a%a %d%d?:%d%d [AP]M$', result)
      else
        assert.matches('^%d%d? %a%a%a %d%d%d%d %d%d?:%d%d [AP]M$', result)
      end
    end)

    it('formats yesterday with same month date', function()
      local result = util.format_time(yesterday)
      assert.matches('^%d%d? %a%a%a %d%d?:%d%d [AP]M$', result)
    end)

    it('formats future date with full date', function()
      local result = util.format_time(next_year)
      assert.matches('^%d%d? %a%a%a %d%d%d%d %d%d?:%d%d [AP]M$', result)
      assert.matches('%d%d%d%d', result)
    end)
  end)

  describe('millisecond timestamp conversion', function()
    it('converts millisecond timestamps to seconds', function()
      local seconds_timestamp = os.time()
      local milliseconds_timestamp = seconds_timestamp * 1000

      local seconds_result = util.format_time(seconds_timestamp)
      local milliseconds_result = util.format_time(milliseconds_timestamp)

      assert.equals(seconds_result, milliseconds_result)
    end)

    it('handles large millisecond timestamps correctly', function()
      local ms_timestamp = 1762350000000 -- ~November 2025 in milliseconds
      local result = util.format_time(ms_timestamp)

      assert.is_not_nil(result)
      assert.is_string(result)

      local is_time_only = result:match('^%d%d?:%d%d [AP]M$')
      local is_same_year = result:match('^%d%d? %a%a%a %d%d?:%d%d [AP]M$')
      local is_full_date = result:match('^%d%d? %a%a%a %d%d%d%d %d%d?:%d%d [AP]M$')
      assert.is_true(is_time_only ~= nil or is_same_year ~= nil or is_full_date ~= nil)
    end)

    it('does not convert regular second timestamps', function()
      local small_timestamp = 1000000000 -- Year 2001, definitely in seconds
      local result = util.format_time(small_timestamp)

      -- Should format without error
      assert.is_not_nil(result)
      assert.is_string(result)
    end)
  end)

  describe('edge cases', function()
    it('handles midnight correctly', function()
      local midnight = make_timestamp(today.year, today.month, today.day, 0, 0, 0)
      local result = util.format_time(midnight)

      if os.date('%Y-%m-%d', midnight) == os.date('%Y-%m-%d') then
        assert.matches('^%d%d?:%d%d [AP]M$', result)
        assert.matches('12:00 AM', result) -- Midnight should be 12:00 AM
      else
        assert.matches('^%d%d? %a%a%a %d%d%d%d %d%d?:%d%d [AP]M$', result)
      end
    end)

    it('handles noon correctly', function()
      local noon = make_timestamp(today.year, today.month, today.day, 12, 0, 0)
      local result = util.format_time(noon)

      assert.matches('^%d%d?:%d%d [AP]M$', result)
      assert.matches('12:00 PM', result) -- Noon should be 12:00 PM
    end)

    it('handles date boundary transitions', function()
      local late_today = make_timestamp(today.year, today.month, today.day, 23, 59, 0)
      local early_tomorrow = late_today + 120 -- 2 minutes later (next day)

      local late_result = util.format_time(late_today)
      local early_result = util.format_time(early_tomorrow)

      -- Late today should be time-only
      assert.matches('^%d%d?:%d%d [AP]M$', late_result)

      -- Early tomorrow behavior depends on whether it's actually tomorrow
      if os.date('%Y-%m-%d', early_tomorrow) == os.date('%Y-%m-%d') then
        -- Still today
        assert.matches('^%d%d?:%d%d [AP]M$', early_result)
      else
        -- Actually tomorrow
        assert.matches('^%d%d? %a%a%a %d%d?:%d%d [AP]M$', early_result)
      end
    end)
  end)

  describe('timezone consistency', function()
    it('uses consistent timezone for date comparison', function()
      local now = os.time()

      -- Both should use the same local timezone
      local timestamp_date = os.date('%Y-%m-%d', now)
      local current_date = os.date('%Y-%m-%d')

      assert.equals(timestamp_date, current_date)

      local result = util.format_time(now)
      assert.matches('^%d%d?:%d%d [AP]M$', result)
    end)
  end)
end)

describe('util.parse_quick_context_args', function()
  local function parse_and_verify(input, expected_prompt, context_checks)
    local prompt, config = util.parse_quick_context_args(input)
    assert.is_true(config.enabled)
    assert.equals(expected_prompt, prompt)

    if context_checks then
      for context_type, checks in pairs(context_checks) do
        if context_type == 'diagnostics' then
          assert.is_true(config.diagnostics.enabled)
          if checks.only_closest ~= nil then
            assert.equals(checks.only_closest, config.diagnostics.only_closest)
          end
          for _, diag_type in ipairs({ 'warning', 'error', 'info' }) do
            if checks[diag_type] ~= nil then
              assert.equals(checks[diag_type], config.diagnostics[diag_type])
            end
          end
        else
          assert.is_true(config[context_type].enabled)
        end
      end
    end
  end

  -- Test cases with expected results
  local test_cases = {
    -- Basic cases
    { '', '', nil },
    { nil, '', nil },

    -- Single context types
    { '#buffer', '', { buffer = {} } },
    { 'add something #buffer', 'add something', { buffer = {} } },
    { 'generate a conventional commit #git_diff', 'generate a conventional commit', { git_diff = {} } },
    { 'explain this code #current_file', 'explain this code', { current_file = {} } },
    { 'explain this code #file', 'explain this code', { current_file = {} } }, -- alias test
    { 'refactor this #selection', 'refactor this', { selection = {} } },
    { 'complete this line #cursor_data', 'complete this line', { cursor_data = {} } },
    { 'complete this line #cursor', 'complete this line', { cursor_data = {} } }, -- alias test
    { 'help with this task #agents', 'help with this task', { agents = {} } },

    -- Diagnostic types
    { 'fix these issues #warnings', 'fix these issues', { diagnostics = { warning = true, only_closest = true } } },
    { 'debug this #errors', 'debug this', { diagnostics = { error = true, only_closest = true } } },
    { 'review #info', 'review', { diagnostics = { info = true, only_closest = true } } },

    -- Multiple contexts
    {
      'generate a conventional commit #buffer #git_diff #warnings #errors',
      'generate a conventional commit',
      { buffer = {}, git_diff = {}, diagnostics = { warning = true, error = true } },
    },

    -- Edge cases
    {
      'generate #buffer a conventional #git_diff commit',
      'generate a conventional commit',
      { buffer = {}, git_diff = {} },
    },
    {
      'Generate Code #BUFFER #Git_Diff #WaRnInGs',
      'Generate Code',
      { buffer = {}, git_diff = {}, diagnostics = { warning = true } },
    },
    {
      'create function #buffer #invalid #git_diff #unknown',
      'create function #invalid #unknown',
      { buffer = {}, git_diff = {} },
    },
    {
      '  generate   code   #buffer   #git_diff  #warnings  ',
      'generate code',
      { buffer = {}, git_diff = {}, diagnostics = { warning = true } },
    },
    {
      'check code quality #warnings #errors #info',
      'check code quality',
      { diagnostics = { warning = true, error = true, info = true } },
    },
    {
      'help me with this task #buffer #errors',
      'help me with this task',
      { buffer = {}, diagnostics = { error = true } },
    },
    { '#buffer #git_diff #warnings', '', { buffer = {}, git_diff = {}, diagnostics = { warning = true } } },
  }

  for _, case in ipairs(test_cases) do
    local input, expected_prompt, context_checks = case[1], case[2], case[3]
    local test_name = input and input ~= '' and ('parses "' .. input .. '"') or 'handles empty/nil input'

    it(test_name, function()
      parse_and_verify(input, expected_prompt, context_checks)
    end)
  end
end)
