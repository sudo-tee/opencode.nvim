---Adjudication record for the upstream V2 event contract. The source of truth
---for which `session.*` events exist is the opencode distribution itself,
---extracted at check time; never snapshotted here.

local M = {}

---Event types with no handler on purpose; each reason says why the missing
---projection has no user-visible consequence.
M.EXEMPT = {
  ['session.agent.selected'] = 'the server persists an agent-switched message; the snapshot channel carries it and rendering hides these messages anyway',
  ['session.model.selected'] = 'the server persists a model-switched message; the snapshot channel carries it and rendering hides these messages anyway',
  ['session.viewed'] = 'read receipt for other clients; nothing in the UI consumes it',
  ['session.archived'] = 'the session list is refetched whenever it is shown, so an archived session drops out on the next fetch; an already open tab keeps its copy until the user closes it',
  ['session.unarchived'] = 'the session list is refetched whenever it is shown, so an unarchived session reappears on the next fetch',
  ['session.permissions'] = 'permission requests arrive through the permissions resource pull; this event only updates the ruleset, which is static in practice',
  ['session.forked'] = 'forking creates a new session the user switches to explicitly; no incremental dependency',
  ['session.usage.recorded'] = 'per-call usage detail; the UI consumes the session.usage.updated aggregate instead',
  ['session.metadata.updated'] = 'server-side session metadata; nvim picks up title etc. on the next session fetch',
  ['session.shell.started'] = 'shell messages reach the snapshot; the projection would only advance visibility until the next refetch',
  ['session.shell.ended'] = 'shell messages reach the snapshot; the projection would only advance visibility until the next refetch',
  ['session.skill.activated'] = 'the server persists the activation notice; the plugin has no skill-state UI',
  ['session.compaction.delta'] = 'streaming compaction progress display only; session.compaction.ended (handled) triggers the refetch that carries the result',
  ['session.status'] = 'ephemeral busy/idle/retry broadcast; the durable execution lifecycle events plus session.retry.scheduled already carry these signals',
  ['session.idle'] = 'ephemeral viewer read-state watermark managed server-side; no UI consumption in the plugin',
  ['session.diff'] = 'ephemeral TUI diff-panel refresh signal; the plugin pulls diff data through the API on demand',
  ['session.updated'] = 'v1-protocol session info event still shipped in the binary; the v2 observation consumes v2 events only',
}

---Handled-worthy event types with no handler yet; unhandled events surface in
---the runtime log.
M.KNOWN_GAPS = {
  ['session.message.content.updated'] = 'edited message content does not re-render until the next refetch',
  ['session.compaction.started'] = 'no compaction-in-progress indication while it runs',
  ['session.compaction.failed'] = 'compaction failure is invisible to the user',
  ['session.error'] = 'ephemeral session-level error broadcast; step failures surface through the handled execution events, but error shapes outside a step would be invisible',
}

---@param source_path string path to the opencode schema source: a compiled binary/JS
---file, or a directory holding the *.ts schema (event definitions live across
---sibling files, so a single file is not the full union)
---@return string[] event_types sorted `session.*` event type literals found in the source
function M.extract_session_events(source_path)
  -- The [a-z.] identifier charset matches the upstream naming convention;
  -- event names with digits or uppercase would be silently missed here.
  local chunks = {}
  if vim.fn.isdirectory(source_path) == 1 then
    for _, file_path in ipairs(vim.fn.globpath(source_path, '**/*.ts', false, true)) do
      local file = io.open(file_path, 'r')
      if file then
        chunks[#chunks + 1] = file:read('*a')
        file:close()
      end
    end
  else
    local file = io.open(source_path, 'r')
    if not file then
      error('cannot open opencode schema source: ' .. source_path, 0)
    end
    chunks[#chunks + 1] = file:read('*a')
    file:close()
  end
  local source = table.concat(chunks, '\n')

  -- Anchor on the schema shape (`type: "session.xxx"`), not on the bare string:
  -- the compiled distribution also contains TUI command names like
  -- `session.copy.id` that are not event types.
  local found = {}
  for event_type in source:gmatch('[\'"]?type[\'"]?%s*:%s*[\'"](session%.[a-z.]+)[\'"]') do
    found[event_type] = true
  end

  local types = {}
  for event_type in pairs(found) do
    types[#types + 1] = event_type
  end
  table.sort(types)
  return types
end

---@param handled table<string, boolean> event types with a registered handler
---@param upstream_events string[] event types extracted from the opencode distribution
---@return string[] unknown_in_source handler keys that are not upstream session events
---@return string[] unadjudicated upstream events that are neither handled, exempt, nor a known gap
---@return string[] stale_adjudications exempt/gap entries whose event no longer exists upstream
function M.check(handled, upstream_events)
  local upstream = {}
  for _, event_type in ipairs(upstream_events) do
    upstream[event_type] = true
  end

  local unknown_in_source = {}
  for event_type in pairs(handled) do
    -- Other event families (form.*, filesystem.*) are out of contract scope.
    if event_type:match('^session%.') and not upstream[event_type] then
      table.insert(unknown_in_source, event_type)
    end
  end
  table.sort(unknown_in_source)

  local unadjudicated = {}
  for _, event_type in ipairs(upstream_events) do
    if not handled[event_type] and not M.EXEMPT[event_type] and not M.KNOWN_GAPS[event_type] then
      table.insert(unadjudicated, event_type)
    end
  end
  table.sort(unadjudicated)

  local stale_adjudications = {}
  for _, table_ in ipairs({ M.EXEMPT, M.KNOWN_GAPS }) do
    for event_type in pairs(table_) do
      if not upstream[event_type] then
        table.insert(stale_adjudications, event_type)
      end
    end
  end
  table.sort(stale_adjudications)

  return unknown_in_source, unadjudicated, stale_adjudications
end

return M
