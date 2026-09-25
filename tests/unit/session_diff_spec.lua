local patch = require('opencode.session_patch')
local config = require('opencode.config')
local diff = require('opencode.ui.session_diff')
local icons = require('opencode.ui.icons')
local Promise = require('opencode.promise')

local function file(name, text)
  return { file = name, patch = text, additions = 1, deletions = 1, status = 'modified' }
end

describe('session diff', function()
  local default_keymaps = vim.deepcopy(config.keymap.session_diff)
  after_each(function()
    diff.close()
    config.keymap.session_diff = vim.deepcopy(default_keymaps)
  end)

  it('uses configurable mappings in list, messages, and preview buffers', function()
    config.keymap.session_diff.list['p'] = false
    config.keymap.session_diff.list['v'] = { 'toggle_view' }
    config.keymap.session_diff.messages['f'] = false
    config.keymap.session_diff.messages['s'] = { 'mark_from' }
    config.keymap.session_diff.preview['p'] = false
    config.keymap.session_diff.preview['v'] = { 'toggle_view' }
    config.keymap.session_diff.message_preview['q'] = false
    config.keymap.session_diff.message_preview['x'] = { 'hide_message_preview' }

    diff.open({ file(vim.fn.getcwd() .. '/one.lua', '@@ -1 +1 @@\n-old\n+new') }, { id = 'ses_123' }, {
      load_turns = function()
        return Promise.new():resolve({ { id = 'msg_one', text = 'First' } })
      end,
      review_range = function()
        return Promise.new():resolve(nil)
      end,
    })
    local list_buf = vim.api.nvim_get_current_buf()
    local function mapped(buf, key)
      return vim.tbl_contains(vim.tbl_map(function(entry)
        return entry.lhs
      end, vim.api.nvim_buf_get_keymap(buf, 'n')), key)
    end
    assert.is_true(mapped(list_buf, 'v'))
    assert.is_false(mapped(list_buf, 'p'))
    local preview_win = vim.api.nvim_tabpage_list_wins(0)[2]
    local preview_buf = vim.api.nvim_win_get_buf(preview_win)
    assert.is_true(mapped(preview_buf, 'v'))
    assert.is_false(mapped(preview_buf, 'p'))

    diff.toggle_range()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_get_current_buf() ~= list_buf
    end))
    local turns_buf = vim.api.nvim_get_current_buf()
    assert.is_true(mapped(turns_buf, 's'))
    assert.is_false(mapped(turns_buf, 'f'))
    assert.equals(' Messages  (s/t mark, <CR> apply, <Esc> close) ', vim.api.nvim_win_get_config(0).title[1][1])
    diff.show_turn_preview()
    local message_buf = vim.api.nvim_get_current_buf()
    assert.is_true(mapped(message_buf, 'x'))
    assert.is_false(mapped(message_buf, 'q'))
    assert.is_false(mapped(message_buf, 'p'))
  end)

  it('aligns folders and files at the same tree depth', function()
    local cwd = vim.fn.getcwd()
    diff.open({
      file(cwd .. '/lua/opencode/ui/session_diff.lua', '@@ -1 +1 @@\n-old\n+new'),
      file(cwd .. '/lua/opencode/ui/session_diff/render.lua', '@@ -1 +1 @@\n-old\n+new'),
    }, { id = 'ses_tree' })

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    local function column(name)
      for _, line in ipairs(lines) do
        local start = line:find(name, 1, true)
        if start then
          return vim.fn.strdisplaywidth(line:sub(1, start - 1))
        end
      end
      error('missing tree item: ' .. name)
    end

    assert.equals(column('session_diff.lua'), column('session_diff/'))
    assert.is_true(column('render.lua') > column('session_diff.lua'))
  end)

  it('toggles help with configured keys and shows only active mappings', function()
    config.keymap.session_diff.list['g?'] = false
    config.keymap.session_diff.list['?'] = { 'toggle_help', desc = 'Show keymaps' }
    config.keymap.session_diff.list['p'] = false
    config.keymap.session_diff.list['v'] = { 'toggle_view', desc = 'Switch layout' }
    diff.open({ file(vim.fn.getcwd() .. '/one.lua', '@@ -1 +1 @@\n-old\n+new') }, { id = 'ses_123' })
    local list_win = vim.api.nvim_get_current_win()
    assert.is_true(vim.wo[list_win].winbar:find('Opencode Session Diff', 1, true) ~= nil)
    assert.is_true(vim.wo[list_win].winbar:find('Help: ', 1, true) ~= nil)
    assert.is_true(vim.wo[list_win].winbar:find('?', 1, true) ~= nil)
    vim.api.nvim_feedkeys('?', 'xt', false)
    local help_win = vim.api.nvim_get_current_win()
    assert.not_equals(list_win, help_win)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(line)
      return line:find('Switch layout', 1, true) ~= nil
    end, lines), true))
    local first_group = vim.list_slice(lines, 1, vim.fn.index(lines, ''))
    assert.is_false(vim.tbl_contains(vim.tbl_map(function(line)
      return line:find('  p        Toggle diff layout', 1, true) ~= nil
    end, first_group), true))
    local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(mark)
      return mark[4].hl_group
    end, marks), 'Title'))
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(mark)
      return mark[4].hl_group
    end, marks), 'Special'))
    vim.api.nvim_feedkeys('g?', 'xt', false)
    assert.equals(list_win, vim.api.nvim_get_current_win())
    assert.is_false(vim.api.nvim_win_is_valid(help_win))
  end)

  it('reconstructs full before and after files across adjacent hunks', function()
    local before, after = patch.sides(table.concat({
      '--- a/src/demo.lua',
      '+++ b/src/demo.lua',
      '@@ -1,3 +1,3 @@',
      ' unchanged',
      '-old',
      '+new',
      ' middle',
      '@@ -4,2 +4,2 @@',
      '-tail',
      '+end',
      ' last',
    }, '\n'))
    assert.same({ 'unchanged', 'old', 'middle', 'tail', 'last' }, before)
    assert.same({ 'unchanged', 'new', 'middle', 'end', 'last' }, after)
  end)

  it('maps patch buffer rows across headers and multiple hunks', function()
    assert.same({ {}, {}, {}, { old = 1, new = 1 }, { old = 2 }, { new = 2 },
      {}, { old = 3, new = 3 }, { old = 4 }, { new = 4 } }, patch.line_map(table.concat({
      '--- a/file', '+++ b/file', '@@ -1,2 +1,2 @@', ' unchanged', '-old', '+new',
      '@@ -3,2 +3,2 @@', ' context', '-tail', '+end',
    }, '\n')))
  end)

  it('adds and edits snapshot comments on either side, then redraws markers', function()
    local context = require('opencode.context')
    local comment_input = require('opencode.ui.session_diff.comment_input')
    local original_open = comment_input.open
    local saved = context.snapshot()
    context.clear_review_comments()
    local path = vim.fn.getcwd() .. '/review-snapshot.lua'
    local content = '@@ -1,2 +1,2 @@\n unchanged\n-old\n+new'
    comment_input.open = function(opts) opts.on_submit('Please check') end
    diff.open({ file(path, content) }, { id = 'session' }, { from = 'turn' })
    local list_buf = vim.api.nvim_get_current_buf()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local before, after
    for _, win in ipairs(wins) do
      local title = vim.wo[win].winbar
      if title:find('Before:', 1, true) then before = win end
      if title:find('After:', 1, true) then after = win end
    end
    vim.api.nvim_set_current_win(after)
    vim.api.nvim_win_set_cursor(after, { 2, 0 })
    diff.add_comment()
    local title_ns = vim.api.nvim_get_namespaces().OpencodeSessionDiffTitle
    local title_marks = vim.api.nvim_buf_get_extmarks(list_buf, title_ns, 0, -1, { details = true })
    local title_visible = false
    for _, mark in ipairs(title_marks) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        title_visible = title_visible or table.concat(vim.tbl_map(function(chunk) return chunk[1] end, line))
          :find('Changes (1)', 1, true) ~= nil
      end
    end
    assert.is_true(title_visible)
    local entry = context.get_review_comments(path)[1]
    assert.equals('after', entry.side)
    assert.equals(2, entry.start_line)
    assert.equals('new', entry.code)
    assert.equals('turn', entry.from)
    local ns = vim.api.nvim_get_namespaces().OpencodeSessionDiffComments
    local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(after), ns, 0, -1, { details = true })
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(mark)
      return mark[4].sign_text
    end, marks), icons.get('review_comment')))
    vim.api.nvim_set_current_win(before)
    vim.api.nvim_win_set_cursor(before, { 2, 0 })
    diff.add_comment()
    assert.equals('before', context.get_review_comments(path)[2].side)
    assert.equals('old', context.get_review_comments(path)[2].code)
    diff.delete_comment()
    assert.equals(1, #context.get_review_comments(path))
    diff.close()
    comment_input.open = original_open
    context.restore(saved)
  end)

  it('anchors unified deleted and added rows to their respective sides', function()
    local context = require('opencode.context')
    local comment_input = require('opencode.ui.session_diff.comment_input')
    local original_open, saved = comment_input.open, context.snapshot()
    local original_line_map, map_calls = patch.line_map, 0
    patch.line_map = function(text)
      map_calls = map_calls + 1
      return original_line_map(text)
    end
    context.clear_review_comments()
    local path = vim.fn.getcwd() .. '/review-patch.lua'
    comment_input.open = function(opts) opts.on_submit('Review') end
    diff.open({ file(path, '@@ -1,2 +1,2 @@\n same\n-old\n+new') }, { id = 'session' })
    diff.show_patch()
    local preview
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].winbar == path then preview = win end
    end
    vim.api.nvim_set_current_win(preview)
    vim.api.nvim_win_set_cursor(preview, { 3, 0 })
    local calls_before_comment = map_calls
    diff.add_comment()
    assert.equals(calls_before_comment, map_calls)
    vim.api.nvim_win_set_cursor(preview, { 4, 0 })
    diff.add_comment()
    local comments = context.get_review_comments(path)
    assert.same({ 'before', 'after' }, { comments[1].side, comments[2].side })
    assert.same({ 'old', 'new' }, { comments[1].code, comments[2].code })
    vim.api.nvim_win_set_cursor(preview, { 3, 0 })
    diff.jump_comment(1)
    assert.equals(4, vim.api.nvim_win_get_cursor(preview)[1])
    diff.close()
    patch.line_map = original_line_map
    comment_input.open = original_open
    context.restore(saved)
  end)

  it('captures a visual range of snapshot lines', function()
    local context = require('opencode.context')
    local comment_input = require('opencode.ui.session_diff.comment_input')
    local original_open, saved = comment_input.open, context.snapshot()
    context.clear_review_comments()
    local path = vim.fn.getcwd() .. '/review-visual.lua'
    comment_input.open = function(opts) opts.on_submit('Both lines') end
    diff.open({ file(path, '@@ -1,3 +1,3 @@\n first\n-old\n+new\n last') }, { id = 'session' })
    local after
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].winbar:find('After:', 1, true) then after = win end
    end
    vim.api.nvim_set_current_win(after)
    vim.api.nvim_win_set_cursor(after, { 1, 0 })
    vim.cmd('normal! Vj')
    diff.add_comment()
    local comment = context.get_review_comments(path)[1]
    assert.same({ 1, 2, 'first\nnew' }, { comment.start_line, comment.end_line, comment.code })
    diff.close()
    comment_input.open = original_open
    context.restore(saved)
  end)

  it('handles additions and deletions without reading working files', function()
    local before, after = patch.sides('@@ -0,0 +1,1 @@\n+new')
    assert.same({}, before)
    assert.same({ 'new' }, after)
    before, after = patch.sides('@@ -1 +0,0 @@\n-old')
    assert.same({ 'old' }, before)
    assert.same({}, after)
    assert.is_nil(patch.sides('@@ -8,1 +8,1 @@\n-old\n+new'))
  end)

  it('keeps added, modified, and deleted status markers in one column', function()
    local cwd = vim.fn.getcwd()
    diff.open({
      { file = cwd .. '/new.lua', patch = '@@ -0,0 +1 @@\n+new', additions = 1, deletions = 0, status = 'added' },
      file(cwd .. '/nested/changed.lua', '@@ -1 +1 @@\n-old\n+new'),
      { file = cwd .. '/nested/old.lua', patch = '@@ -1 +0,0 @@\n-old', additions = 0, deletions = 1, status = 'deleted' },
    }, { id = 'ses_123' })
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals('  ', lines[2]:sub(1, 2))
    assert.equals('M', lines[3]:sub(3, 3))
    assert.equals('D', lines[4]:sub(3, 3))
    assert.equals('A', lines[5]:sub(3, 3))
    local highlights = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      if mark[3] == 2 and mark[4].end_col == 3 then
        highlights[mark[2]] = mark[4].hl_group
      end
    end
    assert.same({ [2] = 'DiagnosticWarn', [3] = 'Removed', [4] = 'Added' }, highlights)
  end)

  it('uses filetype icons and their highlight group when devicons are available', function()
    local original_icons = package.loaded['nvim-web-devicons']
    local original_module = package.loaded['opencode.ui.session_diff']
    package.loaded['nvim-web-devicons'] = {
      get_icon = function(name)
        assert.equals('sample.lua', name)
        return '', 'DevIconLua'
      end,
    }
    package.loaded['opencode.ui.session_diff'] = nil
    local with_icons = require('opencode.ui.session_diff')
    with_icons.open({ file(vim.fn.getcwd() .. '/sample.lua', '@@ -1 +1 @@\n-old\n+new') }, { id = 'ses_123' })
    local buf = vim.api.nvim_get_current_buf()
    assert.matches(' sample.lua', vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], 1, true)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(mark)
      return mark[4].hl_group
    end, marks), 'DevIconLua'))
    with_icons.close()
    package.loaded['nvim-web-devicons'] = original_icons
    package.loaded['opencode.ui.session_diff'] = original_module
  end)

  it('selects ordered user-message endpoints inside the tree pane', function()
    local requested
    local calls = 0
    diff.open({ file(vim.fn.getcwd() .. '/one.lua', '@@ -1 +1 @@\n-old\n+new') }, { id = 'ses_123' }, {
      load_turns = function()
        calls = calls + 1
        return Promise.new():resolve({
          { id = 'msg_one', text = 'First prompt\n' .. string.rep('with detail ', 15), created = 1700000000000 },
          { id = 'msg_two', text = 'Second prompt' },
          { id = 'msg_three', text = 'Latest prompt' },
        })
      end,
      review_range = function(from, to, message_count)
        requested = { from, to, message_count }
        return Promise.new():resolve(nil)
      end,
    })
    local list_buf = vim.api.nvim_get_current_buf()
    diff.toggle_range()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_get_current_buf() ~= list_buf
    end))
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(buf) == 3
    end))
    local title_marks = vim.api.nvim_buf_get_extmarks(list_buf, -1, 0, -1, { details = true })
    local found_change_count = false
    local found_message_range_hint = false
    local highlighted_range_key = false
    local found_turns_help = false
    for _, mark in ipairs(title_marks) do
      if mark[4].virt_lines then
        for _, virtual_line in ipairs(mark[4].virt_lines) do
          local line = table.concat(vim.tbl_map(function(chunk)
            return chunk[1]
          end, virtual_line))
          found_change_count = found_change_count or line:find('Changes (1)', 1, true) ~= nil
          found_message_range_hint = found_message_range_hint
            or line:find('1 message · <r> choose range', 1, true) ~= nil
          for _, chunk in ipairs(virtual_line) do
            highlighted_range_key = highlighted_range_key
              or (chunk[1] == '<r>' and chunk[2] == 'OpencodeInputLegend')
          end
          found_turns_help = found_turns_help or line:find('Turns', 1, true) ~= nil
        end
      end
    end
    assert.is_true(found_change_count)
    assert.is_true(found_message_range_hint)
    assert.is_true(highlighted_range_key)
    assert.is_false(found_turns_help)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches('First prompt with detail', lines[1])
    assert.matches('…$', lines[1])
    assert.is_false(vim.wo[win].wrap)
    assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= vim.api.nvim_win_get_width(win) - 3)
    local win_config = vim.api.nvim_win_get_config(win)
    assert.equals(' Messages  (f/t mark, <CR> apply, <Esc> close) ', win_config.title[1][1])
    assert.equals(math.floor((vim.o.lines - win_config.height) / 2), win_config.row)
    assert.equals(math.floor(vim.o.columns * 0.75), win_config.width)
    assert.equals('      Second prompt', lines[2])
    assert.equals('  FT  Latest prompt', lines[3])
    local message_marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(mark)
      return mark[4].virt_text and mark[4].virt_text[1][1]
    end, message_marks), os.date('%Y-%m-%d %H:%M', 1700000000)))
    assert.equals(2, #vim.tbl_filter(function(mark)
      return mark[4].hl_group == 'Comment' and mark[4].end_col and mark[4].end_col > 6
    end, message_marks))
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Down>', true, false, true), 'xt', false)
    assert.equals(2, vim.api.nvim_win_get_cursor(win)[1])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Up>', true, false, true), 'xt', false)
    assert.equals(1, vim.api.nvim_win_get_cursor(win)[1])
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    diff.mark_range('to')
    assert.equals('  FT  Latest prompt', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
    diff.mark_range('from')
    assert.matches('  F   First prompt with detail', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    local active_range_marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert.equals(0, #vim.tbl_filter(function(mark)
      return mark[4].hl_group == 'Comment' and mark[4].end_col and mark[4].end_col > 6
    end, active_range_marks))
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    diff.mark_range('to')
    assert.equals('   T  Latest prompt', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
    local updated_message_count = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(list_buf, -1, 0, -1, { details = true })) do
      for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
        local line = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, virtual_line))
        updated_message_count = updated_message_count or line:find('3 messages · <r> choose range', 1, true) ~= nil
      end
    end
    assert.is_true(updated_message_count)
    diff.activate()
    assert.same({ 'msg_one', 'msg_three', 3 }, requested)
    diff.toggle_range()
    assert.equals(1, calls)
    assert.equals(list_buf, vim.api.nvim_get_current_buf())
  end)

  it('marks a single previously selected turn as both range endpoints', function()
    diff.open({ file(vim.fn.getcwd() .. '/one.lua', '@@ -1 +1 @@\n-old\n+new') }, { id = 'ses_123' }, {
      from = 'msg_one',
      load_turns = function()
        return Promise.new():resolve({
          { id = 'msg_one', text = 'First' },
          { id = 'msg_two', text = 'Second' },
        })
      end,
      review_range = function()
        return Promise.new():resolve(nil)
      end,
    })
    local list_buf = vim.api.nvim_get_current_buf()
    local marks = vim.api.nvim_buf_get_extmarks(list_buf, -1, 0, -1, { details = true })
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(mark)
      return mark[4].virt_lines and mark[4].virt_lines[#mark[4].virt_lines][1][1]
    end, marks), '  Range: msg_one'))
    diff.toggle_range()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_get_current_buf() ~= list_buf
    end))
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(buf) == 2
    end))
    assert.equals('  FT  First', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it('can open range picker when latest turn changed no files', function()
    diff.open({}, { id = 'ses_123' }, {
      load_turns = function()
        return Promise.new():resolve({ { id = 'msg_one', text = 'Earlier prompt' } })
      end,
      review_range = function()
        return Promise.new():resolve(nil)
      end,
    })
    local list_buf = vim.api.nvim_get_current_buf()
    diff.toggle_range()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_get_current_buf() ~= list_buf
    end))
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_buf_line_count(buf) == 1
    end))
    diff.toggle_range()
    assert.same({ '' }, vim.api.nvim_buf_get_lines(list_buf, 0, -1, false))
  end)

  it('focuses a tool file in the existing review and toggles it closed', function()
    local previous = vim.api.nvim_get_current_tabpage()
    local cwd = vim.fn.getcwd()
    diff.open({
      file(cwd .. '/a.lua', '@@ -1 +1 @@\n-before\n+after'),
      file(cwd .. '/nested/b.lua', '@@ -1 +1 @@\n-old\n+new'),
    }, { id = 'ses_123' }, { from = 'msg_123' })
    local review_tab = vim.api.nvim_get_current_tabpage()
    local list_win = vim.api.nvim_get_current_win()
    assert.is_true(diff.toggle_file(cwd .. '/nested/b.lua', 'msg_123', 'ses_123'))
    assert.equals(review_tab, vim.api.nvim_get_current_tabpage())
    assert.matches('b.lua', vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win),
      vim.api.nvim_win_get_cursor(list_win)[1] - 1, vim.api.nvim_win_get_cursor(list_win)[1], false)[1])
    assert.is_true(diff.toggle_file(cwd .. '/nested/b.lua', 'msg_123', 'ses_123'))
    assert.equals(previous, vim.api.nvim_get_current_tabpage())
  end)

  it('opens on the requested tool file instead of the first changed file', function()
    local cwd = vim.fn.getcwd()
    diff.open({
      file(cwd .. '/a.lua', '@@ -1 +1 @@\n-before\n+after'),
      file(cwd .. '/b.lua', '@@ -1 +1 @@\n-old\n+new'),
    }, { id = 'ses_123' }, { from = 'msg_123', file = cwd .. '/b.lua' })
    local list_win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win),
      vim.api.nvim_win_get_cursor(list_win)[1] - 1, vim.api.nvim_win_get_cursor(list_win)[1], false)[1]
    assert.matches('b.lua', line)
  end)

  it('opens side-by-side, navigates tree files, and returns to patch', function()
    local original_tab = vim.api.nvim_get_current_tabpage()
    local cwd = vim.fn.getcwd()
    diff.open({
      file(cwd .. '/src/nested/one.lua', '@@ -1 +1 @@\n-old\n+new'),
      file(cwd .. '/src/nested/two.lua', '@@ -1 +1 @@\n-first\n+second'),
    }, { id = 'ses_123', title = 'Review session' })
    local list_win = vim.api.nvim_get_current_win()
    local tab = vim.api.nvim_get_current_tabpage()
    local list_buf = vim.api.nvim_get_current_buf()
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(tab))
    assert.is_false(vim.wo[list_win].number)
    assert.is_false(vim.wo[list_win].relativenumber)
    assert.is_true(vim.wo[list_win].winfixwidth)
    local list_width = vim.api.nvim_win_get_width(list_win)
    local lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
    assert.is_true(vim.wo[list_win].winbar:find('g?', 1, true) ~= nil)
    assert.is_true(vim.wo[list_win].winbar:find('Opencode Session Diff', 1, true) ~= nil)
    local list_keys = vim.tbl_map(function(mapping)
      return mapping.lhs
    end, vim.api.nvim_buf_get_keymap(list_buf, 'n'))
    assert.is_false(vim.tbl_contains(list_keys, 'K'))
    assert.is_false(vim.tbl_contains(list_keys, 'f'))
    assert.is_false(vim.tbl_contains(list_keys, 't'))
    assert.same({
      '',
      '    ▾ ' .. icons.get('folder') .. 'src/nested/',
      '  M     ' .. vim.trim(icons.get('file')) .. ' one.lua  +1 -1',
      '  M     ' .. vim.trim(icons.get('file')) .. ' two.lua  +1 -1',
    }, lines)
    local highlights = vim.api.nvim_buf_get_extmarks(list_buf, -1, 0, -1, { details = true })
    assert.equals(8, #highlights)
    local groups = {}
    local title_lines
    for _, mark in ipairs(highlights) do
      if mark[4].hl_group then
        groups[mark[4].hl_group] = true
      end
      if mark[4].virt_lines then
        assert.equals(0, mark[2])
        assert.is_false(mark[4].virt_lines_above)
        title_lines = mark[4].virt_lines
      end
    end
    local title = ''
    for _, virtual_line in ipairs(vim.list_slice(title_lines, 1, #title_lines - 2)) do
      assert.equals('Title', virtual_line[1][2])
      assert.is_true(vim.fn.strdisplaywidth(virtual_line[1][1]) <= list_width)
      title = title .. virtual_line[1][1]:sub(3)
    end
    assert.equals('Session: Review session', title)
    assert.same({ { ' ' } }, title_lines[#title_lines - 1])
    assert.same({ { '  Changes (2)', 'Normal' } }, title_lines[#title_lines])
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(list_win))
    vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = list_buf })
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(list_win))
    assert.is_true(groups.Added)
    assert.is_true(groups.Removed)
    assert.is_true(groups.Directory)

    diff.select(1)
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(list_win))
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    local texts = {}
    for _, win in ipairs(wins) do
      texts[#texts + 1] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1]
    end
    assert.is_true(vim.tbl_contains(texts, 'first'))
    assert.is_true(vim.tbl_contains(texts, 'second'))
    diff.select(-1)
    texts = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      texts[#texts + 1] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1]
    end
    assert.is_true(vim.tbl_contains(texts, 'old'))
    assert.is_true(vim.tbl_contains(texts, 'new'))

    vim.api.nvim_win_set_cursor(list_win, { 2, 0 })
    diff.activate()
    assert.same({
      '',
      '    ▸ ' .. icons.get('folder') .. 'src/',
    }, vim.api.nvim_buf_get_lines(list_buf, 0, -1, false))
    diff.activate()
    assert.equals(4, vim.api.nvim_buf_line_count(list_buf))
    diff.toggle_view()
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(tab))
    assert.equals(list_width, vim.api.nvim_win_get_width(list_win))
    diff.toggle_view()
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(tab))
    assert.equals(list_width, vim.api.nvim_win_get_width(list_win))
    diff.close()
    assert.equals(original_tab, vim.api.nvim_get_current_tabpage())
  end)
end)
