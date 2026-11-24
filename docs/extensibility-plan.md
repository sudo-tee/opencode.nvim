# Recipe-oriented extensibility plan

## Goal

Let users build recipes without modifying core files or reaching into state,
renderer, or protocol internals.

Recipes should compose focused, documented APIs. They should not require a
generic plugin loader or extension framework.

## Existing extension points

These surfaces already cover many recipe use cases:

- slash commands
- command lifecycle hooks
- keymaps and configuration
- topbar and footer rendering hooks
- `User` autocmds for server events
- `prompt_guard`
- public session and workflow APIs

No additional generic event bus is needed.

## Proposed extension points

### Phase 1: Completion sources

The completion registry already exists in `lua/opencode/ui/completion.lua`.

Add public registration functions:

```lua
opencode.register_completion_source(source)
opencode.unregister_completion_source(name)
```

Support:

- custom trigger characters
- asynchronous completion
- custom item metadata
- selection callbacks
- duplicate-name validation
- per-source error isolation

First recipe: issue or reference completion.

### Phase 2: Tool formatters

Tool dispatch already selects formatters by tool name in
`lua/opencode/ui/formatter.lua`.

Add:

```lua
opencode.register_tool_formatter(name, formatter)
opencode.unregister_tool_formatter(name)

opencode.register_tool_formatter('bash', formatter, { replace = true })
```

Limit the first version to tool names. Registration should reject duplicate
names by default, including built-in formatter names. Replacing a built-in must
be explicit with `replace = true`, and only one active override should be
allowed per tool. Unregistering an override must restore the built-in
formatter.

Do not allow replacing message-role or message-part formatters yet. Core
rendering continues to own:

- borders
- folds
- streaming behavior
- errors
- renderer lifecycle

Do not expose arbitrary message-part formatters yet.

First recipes: specialized MCP or test-result formatter, or an explicit
built-in tool override such as a custom Bash presentation.

### Phase 3: Layout presets

Existing configuration supports side panels, full-window mode, floats, input
orientation, and configurable dimensions. Add independent floating input
placement so the output can remain in a split or float while the input uses its
own float. The three-state layout recipe already demonstrates demand for
runtime layout switching.

Add declarative presets:

```lua
opencode.register_layout('deep', {
  position = 'current',
  input_position = 'bottom',
})

opencode.register_layout('floating-input', {
  position = 'right',
  input_position = 'float',
  input_float = {
    width = 0.8,
    height = 0.2,
    row = 0.75,
    col = 0.1,
    border = 'rounded',
  },
})

opencode.apply_layout('deep')
```

`apply_layout()` should own:

- hide and reopen behavior
- cursor restoration
- buffer preservation
- renderer state
- footer and tab-strip lifecycle
- resize handling

When `input_position = 'float'`, `input_float` controls input geometry and
window options independently from output geometry. The input float must retain
its buffer, cursor, completion behavior, and focus transitions when output or
panel layout changes.

Do not expose arbitrary window-creation callbacks. That would create a second
window manager. Keep custom layouts limited to supported declarative layout
fields initially.

Refactor `docs/recipes/three-state-layout/` to use layout presets.

### Phase 4: Context providers and visibility

Context is the highest-risk extension point. Current context crosses automatic
deduplication, session/tab state, V1 encoding, V2 file attachments, and separate
main-chat and quick-chat paths. More importantly, silently attaching custom
context can leak information because users have no preview or visual indication
of what will be sent.

Do not ship automatic context providers until the visibility contract exists.
Every provider must be explicitly enabled and visible before submission.

Required visibility:

- context-bar entry showing provider name and current state
- `#` picker entry for enable, disable, remove, and inspect
- pre-send preview of the exact generated payload
- clear sent, pending, stale, and provider-error states

After those surfaces exist, add a provider registry with a protocol-neutral
contract:

```lua
opencode.register_context_provider({
  name = 'git_branch',
  label = 'Git branch',
  collect = function(ctx)
    return {
      key = 'git_branch',
      name = 'git-branch.txt',
      media_type = 'text/plain',
      text = 'branch: ' .. current_branch(),
      preview = function(text)
        return text
      end,
    }
  end,
})
```

The provider system should own:

- stable fingerprints
- per-session deduplication
- V1/V2 conversion
- optional-provider failure handling
- preview generation and visibility state

The initial transport should use portable text attachments. Defer custom context
kinds until real recipes require them. Explicit user actions may add existing
context types before automatic providers are available.

Status: the first slice ships `register_context_provider`,
`unregister_context_provider`, and `refresh_context` (see
[Extensions](extensions.md#context-providers)). `collect` returns a list of
`{ id, name, text }` items, sent as `text/plain` files; preview is the exact
text, so there is no `preview` callback yet. The paste-as-attachment recipe is
the first consumer. Moving built-in context onto the registry is a follow-up.

## API shape

Use focused functions:

```lua
register_completion_source()
register_tool_formatter()
register_layout()
apply_layout()
register_context_provider()
```

Avoid a catch-all API such as:

```lua
register_extension({
  on_everything = ...,
})
```

Avoid exposing raw internal state, renderer objects, protocol adapters, or a
dynamic recipe loader.

## Documentation

Update or add:

- `docs/extensions.md` — stable extension contracts
- `docs/recipes/TEMPLATE.md` — extension-based recipe guidance
- `docs/recipes/three-state-layout/` — layout preset usage
- completion-source recipe
- tool-formatter recipe

Each recipe should document prerequisites, V1/V2 assumptions, setup, cleanup,
and failure behavior.

## Testing

Each extension point needs coverage for:

- registration and unregistration
- duplicate names
- callback failures
- fallback behavior
- lifecycle cleanup
- V1/V2 compatibility where relevant

Run standard repository checks:

```sh
make check
make topology-check
```

## Suggested Implementation order

1. Completion sources
2. Tool formatters
3. Layout presets
4. Context providers
