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
      review_range = function(from, to)
        requested = { from, to }
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
    local found_turns_help = false
    for _, mark in ipairs(title_marks) do
      if mark[4].virt_lines then
        for _, virtual_line in ipairs(mark[4].virt_lines) do
          local line = table.concat(vim.tbl_map(function(chunk)
            return chunk[1]
          end, virtual_line))
          found_change_count = found_change_count or line:find('Changes (1)', 1, true) ~= nil
          found_turns_help = found_turns_help or line:find('Turns', 1, true) ~= nil
        end
      end
    end
    assert.is_true(found_change_count)
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
    diff.activate()
    assert.same({ 'msg_one', 'msg_three' }, requested)
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
      '  M       ' .. vim.trim(icons.get('file')) .. ' one.lua  +1 -1',
      '  M       ' .. vim.trim(icons.get('file')) .. ' two.lua  +1 -1',
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
