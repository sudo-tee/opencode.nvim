local assert = require('luassert')

describe('opencode.ui.reference_parser', function()
  local reference_parser
  local original_startswith

  before_each(function()
    original_startswith = vim.startswith

    vim.startswith = function(str, prefix)
      return str:sub(1, #prefix) == prefix
    end

    package.loaded['opencode.ui.reference_parser'] = nil
    reference_parser = require('opencode.ui.reference_parser')
    reference_parser.clear_all()
  end)

  after_each(function()
    reference_parser.clear_all()
    vim.startswith = original_startswith
    package.loaded['opencode.ui.reference_parser'] = nil
  end)

  it('parses backtick file references with line and column', function()
    local refs = reference_parser.parse_references('Error at `src/handler.lua:10:5`.', 'part1')

    assert.equal(1, #refs)
    assert.equal('src/handler.lua', refs[1].file_path)
    assert.equal(10, refs[1].line)
    assert.equal(5, refs[1].col)
    assert.is_number(refs[1].match_start)
    assert.is_number(refs[1].match_end)
  end)

  it('parses file URIs, nested paths, and top-level file mentions', function()
    local refs =
      reference_parser.parse_references('Open file://src/config.lua, src/module/helper.lua:25, and README.md.', 'part1')

    assert.equal(3, #refs)
    assert.equal('src/config.lua', refs[1].file_path)
    assert.equal('src/module/helper.lua', refs[2].file_path)
    assert.equal(25, refs[2].line)
    assert.equal('README.md', refs[3].file_path)
  end)

  it('rejects URL paths and extensionless paths', function()
    local refs = reference_parser.parse_references('Visit https://example.com/file.lua and see `README`.', 'part1')

    assert.equal(0, #refs)
  end)

  it('parses missing top-level file mentions without checking filesystem', function()
    local refs = reference_parser.parse_references('Read missing.xyz.', 'part1')

    assert.equal(1, #refs)
    assert.equal('missing.xyz', refs[1].file_path)
  end)

  it('includes explicit references regardless of file availability', function()
    local refs = reference_parser.parse_references('Create `newfile.xyz`.', 'part1')

    assert.equal(1, #refs)
    assert.equal('newfile.xyz', refs[1].file_path)
  end)

  it('ignores path-shaped text inside fenced code blocks', function()
    local refs = reference_parser.parse_references('```bash\n./run_tests.sh\nsrc/main.lua\n```', 'part1')

    assert.equal(0, #refs)
  end)

  it('parses prose and inline references outside fenced code blocks', function()
    local refs = reference_parser.parse_references(
      '```bash\n./run_tests.sh\nsrc/ignored.lua\n```\nRun `./run_tests.sh` and inspect src/main.lua.',
      'part1'
    )

    assert.equal(2, #refs)
    assert.equal('./run_tests.sh', refs[1].file_path)
    assert.equal('src/main.lua', refs[2].file_path)
  end)

  it('keeps one reference per text range while allowing repeated paths', function()
    local refs =
      reference_parser.parse_references('Check file://src/main.lua, then `src/main.lua:10`, then main.lua:42.', 'part1')

    assert.equal(3, #refs)
    table.sort(refs, function(a, b)
      return a.match_start < b.match_start
    end)
    assert.equal('src/main.lua', refs[1].file_path)
    assert.equal('src/main.lua', refs[2].file_path)
    assert.equal(10, refs[2].line)
    assert.equal('main.lua', refs[3].file_path)
    assert.equal(42, refs[3].line)
  end)

  it('keeps repeated mentions of the same path at distinct text positions', function()
    local refs = reference_parser.parse_references(
      'Open lua/opencode/ui/formatter.lua first, then mention lua/opencode/ui/formatter.lua before format_part.',
      'part1'
    )

    assert.equal(2, #refs)
    assert.equal('lua/opencode/ui/formatter.lua', refs[1].file_path)
    assert.equal('lua/opencode/ui/formatter.lua', refs[2].file_path)
    assert.is_true(refs[1].match_start < refs[2].match_start)
  end)

  it('extends append-only updates without recreating existing refs', function()
    local refs1 = reference_parser.parse_references('Check `src/main.lua`.', 'part1')
    local count_before_append = #refs1
    local first_ref = refs1[1]
    local first_range = vim.deepcopy(first_ref)
    local refs2 = reference_parser.parse_references('Check `src/main.lua`. Also `lib/util.lua`.', 'part1')

    assert.equal(1, count_before_append)
    assert.equal(2, #refs2)
    assert.is_true(rawequal(first_ref, refs2[1]))
    assert.are.same(first_range, refs2[1])
    assert.equal('lib/util.lua', refs2[2].file_path)
  end)

  it('waits for closing backticks before caching a path inside a code span', function()
    local partial_refs = reference_parser.parse_references('- `lua/opencode/event_manager.lua', 'part1')
    local count_before_closing_backtick = #partial_refs
    local refs = reference_parser.parse_references('- `lua/opencode/event_manager.lua`', 'part1')

    assert.equal(0, count_before_closing_backtick)
    assert.equal(1, #refs)
    assert.equal('lua/opencode/event_manager.lua', refs[1].file_path)
    assert.are.same(
      { match_start = 3, match_end = 34 },
      { match_start = refs[1].match_start, match_end = refs[1].match_end }
    )
  end)

  it('extends append-only references whose opening backtick is outside the overlap window', function()
    local prefix = string.rep('a', 160)
    local partial_text = prefix .. ' `src/' .. string.rep('deep/', 40)
    reference_parser.parse_references(partial_text, 'part1')

    local refs = reference_parser.parse_references(partial_text .. 'main.lua`', 'part1')

    assert.equal(1, #refs)
    assert.equal(prefix:len() + 2, refs[1].match_start)
    assert.equal('src/' .. string.rep('deep/', 40) .. 'main.lua', refs[1].file_path)
  end)

  it('resets same-key cache when text becomes shorter', function()
    reference_parser.parse_references('Check `src/main.lua`. Also `lib/util.lua`.', 'part1')

    local refs = reference_parser.parse_references('No refs.', 'part1')

    assert.equal(0, #refs)
  end)

  it('resets same-key cache when existing text changes in place', function()
    local old_refs = reference_parser.parse_references('Check `src/main.lua`.', 'part1')

    local refs = reference_parser.parse_references('Check `src/other.lua`.', 'part1')

    reference_parser.clear('part1')
    local refs_after_clear = reference_parser.parse_references('No refs.', 'part1')

    assert.equal(1, #old_refs)
    assert.equal(1, #refs)
    assert.equal('src/other.lua', refs[1].file_path)
    assert.are.same(
      { match_start = 7, match_end = 21 },
      { match_start = refs[1].match_start, match_end = refs[1].match_end }
    )
    assert.equal(0, #refs_after_clear)
  end)
end)
