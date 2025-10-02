# Buffers' High-Level Symbols Feature Spec

## Overview

This feature enhances the `recent_buffers` context in `opencode.context` by optionally including high-level symbols (e.g., functions, variables, classes) extracted via LSP's `document_symbols()` for eligible buffers. The goal is to provide a structured overview of buffer contents without sending full file text, reducing token usage (~80% savings for config files) while aiding navigation and understanding of plugin interactions (e.g., exports/requires in Lua files).

- **Integration Point**: Modify `M.get_recent_buffers()` to conditionally fetch and append symbols data to each buffer entry.
- **Config Location**: Add `symbols_only` (boolean, default: false) under `config.context.recent_buffers`. When true, symbols replace full content summary; when false, symbols are additional metadata.
- **Output Format**: Append `symbols` array to buffer objects in `recent_buffers` context, e.g.:
  ```lua
  {
    bufnr = 1,
    name = '/path/to/file.lua',
    lastused = 1234567890,
    changed = false,
    symbols = {
      { name = 'setup', kind = 'Function', range = { start = {1,0}, ['end'] = {5,0} }, detail = '...' },
      { name = 'opts', kind = 'Variable', range = { start = {10,0}, ['end'] = {15,0} }, detail = '...' },
    }
  }
  ```
- **Benefits**:
  - Reduces noise in AI prompts by focusing on structure.
  - Highlights key elements (e.g., `setup()` in Neovim plugins).
  - Pairs with `cursor_surrounding` for deeper context on demand.
- **Drawbacks & Mitigations**:
  - LSP dependency: Skip if no client attached.
  - Performance: Fetch only for recent/active buffers; cache if needed.
  - Parser limits: Relies on Treesitter/LSP; fallback to nil if unavailable.

## Requirements

1. **Configurability**: User can enable/disable via `config.context.recent_buffers.symbols_only`.
2. **Data Extraction**: Use `vim.lsp.buf.document_symbols()` to get hierarchical symbols (functions, variables, etc.).
3. **Context Inclusion**: Serialize symbols into JSON-friendly format for `format_message()` parts.
4. **Filtering**: Only include symbols for buffers meeting all constraints (below).
5. **Staleness Handling**: Prioritize buffers with `lastused > 0` (recently accessed); limit to top N (e.g., 5) for symbols fetch to avoid overhead.
6. **Error Handling**: Gracefully skip symbols if LSP call fails (e.g., no client, timeout); log via `vim.notify`.
7. **Test Coverage**: Unit tests for enabled/disabled cases, constraint edge cases (e.g., <100 lines, no LSP).

## Constraints

- **Line Count**: Fetch symbols only if buffer has >100 lines (`vim.api.nvim_buf_line_count(bufnr) > 100`). Rationale: Small files (<100 lines) are cheap to send fully; symbols add little value.
- **LSP Attached**: Only if LSP client(s) attached to buffer (`#vim.lsp.get_active_clients({ bufnr = bufnr }) > 0`). Skip otherwise to avoid errors.
- **Editable Buffer**: Only for editable, file-based buffers:
  - Not readonly (`not vim.api.nvim_buf_get_option(bufnr, 'readonly')`).
  - Not terminal (`not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= 'terminal'`).
  - Listed and in cwd (`buflisted = true` and `is_in_cwd(name)`).
  Rationale: Symbols irrelevant for non-editable (e.g., help, quickfix) or transient buffers.

## Implementation Steps

1. **Config Update** (`lua/opencode/config.lua`):
   - Add `symbols_only` to `recent_buffers` schema/defaults.
   - Deep merge support for user overrides.

2. **Core Logic** (`lua/opencode/context.lua`):
   - In `M.get_recent_buffers()`:
     - After collecting base buffers, loop over eligible ones.
     - For each: Check constraints (lines >100, LSP attached, editable).
     - If met and `symbols_only` enabled: Call `vim.lsp.buf_request(bufnr, 'textDocument/documentSymbol', {}, handler)`.
     - Handler: Flatten hierarchy to array of {name, kind, range, detail}; append to buffer entry.
     - Async handling: Use promises or callbacks to avoid blocking; collect results post-fetch.
   - Update `M.load()` to call `get_recent_buffers()` as before.
   - In `format_context_part('recent_buffers', ...)`: Ensure symbols serialize correctly (JSON-safe).

3. **Edge Cases**:
   - No symbols: Append empty array `symbols = {}`.
   - Partial fetch: If some buffers qualify, include for those only.
   - Limit: Cap symbols per buffer (e.g., top 20) to prevent bloat.
   - Fallback: If `symbols_only=true` but constraints fail, include basic buffer info without symbols.

4. **Testing** (`tests/unit/context_spec.lua`):
   - Mock `vim.lsp.get_active_clients()` to return clients/nil.
   - Mock `vim.api.nvim_buf_line_count()` for line checks.
   - Mock `vim.lsp.buf_request()` to simulate symbol responses.
   - Test: Enabled with constraints met → symbols included; failed constraint → skipped; disabled → no symbols.

5. **Verification**:
   - Run `./run_tests.sh` → All pass.
   - Manual: Enable in config, open large Lua file with LSP → Check context includes symbols.
   - Token Savings: Compare prompt sizes with/without.

## Dependencies

- Neovim >=0.8 (LSP APIs).
- Treesitter/LSP setup for language (e.g., lua_ls for Lua).
- No external libs; use built-in `vim.lsp`.

## Potential Extensions

- Cache symbols per buffer (invalidate on write).
- Support Treesitter fallback if no LSP.
- Filter symbols by kind (e.g., only functions/variables).

This spec ensures elegant, constraint-driven implementation aligned with project principles: simplicity, performance, and spec-driven development.