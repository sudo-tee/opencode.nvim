local assert = require('luassert')
local stub = require('luassert.stub')

describe('e2e symbol jump with revised candidate sources', function()
  local state, renderer, navigation, reference_facts
  local tmp_lua, tmp_dir, code_buf
  local output_buf, output_win

  before_each(function()
    state = require('opencode.state')
    renderer = require('opencode.ui.renderer')
    navigation = require('opencode.ui.navigation')
    reference_facts = require('opencode.ui.reference_facts')

    -- lua fixture: nvim bundles the lua treesitter parser
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, 'p')
    tmp_lua = tmp_dir .. '/attention.lua'
    vim.fn.writefile({
      'local M = {}',
      'function M.SimpleMultiHeadAttention() end',
      'return M',
    }, tmp_lua)

    output_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[output_buf].buftype = ''
    output_win = vim.api.nvim_open_win(output_buf, true, {
      relative = 'editor', width = 80, height = 10, row = 0, col = 0,
    })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win, position = 'right' })
    state.session.set_active({ id = 'ses_e2e' })
  end)

  after_each(function()
    reference_facts.clear()
    state.session.clear_active()
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    if code_buf then
      pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    end
    pcall(vim.fn.delete, tmp_dir, 'rf')
  end)

  it('jumps to definition after render with buffer-only candidate source', function()
    local message = {
      info = { id = 'msg_e2e', role = 'assistant', sessionID = 'ses_e2e' },
      parts = {
        { id = 'part_e2e', messageID = 'msg_e2e', sessionID = 'ses_e2e', type = 'text', text = 'See SimpleMultiHeadAttention here.' },
      },
    }
    state.renderer.set_messages({ message })
    reference_facts.rebuild('ses_e2e', { message })

    code_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[code_buf].buftype = ''
    vim.api.nvim_buf_set_name(code_buf, tmp_lua)
    vim.fn.bufload(code_buf)
    vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, vim.fn.readfile(tmp_lua))
    local avail = reference_facts.available_files()
    assert.is_true(#avail > 0, 'available_files must include loaded buffer, got: ' .. vim.inspect(avail))

    -- stub the treesitter snapshot layer: symbol resolution itself is covered by
    -- symbol_snapshot_spec (nvim < 0.12 bundles no lua parser/locals query);
    -- what this test exercises is the candidate-set flow through
    -- flush -> render_state -> navigation
    local snap = require('opencode.ui.symbol_snapshot')
    local snap_stub = stub(snap, 'targets_for_token').invokes(function(_, token, candidate_files)
      for _, p in ipairs(candidate_files or {}) do
        if p:find('attention%.lua$') then
          return { { token = token, path = p, line = 2, col = 14, kind = 'function' } }
        end
      end
      return {}
    end)

    local ctx = require('opencode.ui.renderer.ctx')
    local flush = require('opencode.ui.renderer.flush')
    ctx.render_state:set_message(message)
    ctx.render_state:set_part(message.parts[1], 1, 1)
    flush.mark_part_dirty(message.parts[1].id, 'msg_e2e')
    flush.flush()
    vim.wait(300)

    local pd = ctx.render_state._parts[message.parts[1].id]
    assert.is_truthy(pd, 'part must be rendered')
    local n_sym = 0
    local attention_target = nil
    for _, t in ipairs(pd.targets or {}) do
      if t.kind == 'symbol' then
        n_sym = n_sym + 1
        if t.token == 'SimpleMultiHeadAttention' then attention_target = t end
      end
    end
    assert.is_true(n_sym > 0, 'no symbol targets from buffer-only candidate: ' .. vim.inspect(pd.targets))
    assert.is_truthy(attention_target, 'SimpleMultiHeadAttention target must exist')

    local row = nil
    local lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
    for i, l in ipairs(lines) do
      local c = l:find('SimpleMultiHeadAttention', 1, true)
      if c then row, col = i, c - 1 break end
    end
    assert.is_truthy(row, 'token must be rendered in output buffer')

    vim.api.nvim_win_set_cursor(output_win, { row, col })
    navigation.jump_to_target_at_cursor()
    vim.wait(300)

    -- macOS: tempname's /var prefix is realpath-normalized to /private/var
    local jumped_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()), ':t')
    assert.equal('attention.lua', jumped_name)
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equal(2, cursor[1])

    snap_stub:revert()
  end)
end)
