# Recipes

[Documentation](../README.md) / Recipes

Optional setups for specific workflows. None of them are needed to use the
plugin; read [Usage](../usage.md) first if you are new.

| Recipe | Use it when… |
| --- | --- |
| [TUI/Neovim sync](bidirectional-sync/README.md) | You want both frontends to resume the same conversation |
| [Worktree sessions](worktree.md) | You want one panel tab per worktree without changing Neovim's directory |
| [Three-state layout toggle](three-state-layout/README.md) | You move between code-only, split, and conversation-focused layouts |
| [Change-by-change review](change-by-change-review/README.md) | You use V1 snapshots and prefer diffview-plus and gitsigns |
| [Review a session diff](review-session-diff.md) | You want to comment on V2 changes and send the comments with your next prompt |
| [Quiet Blink completion](quiet-blink.md) | The completion menu pops up while you type a prompt |
| [GitHub issue references](completion-source.md) | You want issue references available from a custom completion source |
| [opencode-pty tools](tool-formatter.md) | You want readable output for tools added by a server plugin |

## Keep a recipe in its own file

A recipe that needs both options and code can live in a Lua module on your
`runtimepath` and be listed in `recipes`:

```lua
-- ~/.config/nvim/lua/my_recipes/hello.lua
local M = {}

M.opts = {
  keymap = {
    editor = {
      ['<leader>oH'] = { function() vim.notify('hello from a recipe') end, desc = 'Say hello' },
    },
  },
}

function M.setup(opencode)
  opencode.register_slash_command({
    name = 'hello',
    desc = 'Say hello',
    fn = function() vim.notify('hello from a recipe') end,
  })
end

return M
```

```lua
require('opencode').setup({
  recipes = { 'my_recipes.hello' },
})
```

Each entry is a module name passed to `require()` or a recipe table. Recipe
`opts` merge in list order beneath your own options, so anything you set in
`setup()` wins, including `false`. Later recipes override earlier recipes;
callbacks are replaced, not chained. Both `opts` and `setup` are optional.
Each recipe's `setup(opencode)` then runs in the same order, after plugin
initialization. Keep registrations and other side effects in this hook, not at
module scope. Repeated calls to the plugin's `setup()` do not rerun recipes.

With lazy.nvim, put `recipes` in the plugin's `opts`; no custom `config`
function is needed:

```lua
{
  'sudo-tee/opencode.nvim',
  opts = {
    recipes = { 'my_recipes.hello' },
  },
}
```

The loader does not bundle recipes or install their dependencies. Use the full
Lua module name, such as `custom.opencode_recipes.paste_as_attachment` for
`lua/custom/opencode_recipes/paste_as_attachment.lua` in your Neovim config.

A missing module raises an error before plugin initialization, so you can fix
its name or path and call `setup()` again. Errors inside a recipe module also
propagate; restart Neovim after fixing one because `require()` caches failed
loads. An error inside a recipe's `setup` stops the remaining hooks; the plugin
stays initialized and already-run hooks are not rolled back. Fix the recipe
and restart Neovim.

## Share a recipe

Copy the [template](TEMPLATE.md). Say what problem it solves, what it needs
(plugins, V1 or V2), the full setup, and how to try it. See the
[documentation conventions](../../CONTRIBUTING.md#documentation).
