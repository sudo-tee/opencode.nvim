# Three-state layout toggle

[Recipes](../README.md) / Three-state layout toggle

Two keys to move between three layouts: code only, panel beside the code, and
panel filling the window.

![Three-state layout toggle demo](./three-state-toggle.gif)

## When to use it

`<leader>og` only hides and restores the panel, always in the same position.
If you sometimes want the conversation to take over the whole window, for
example to read a long answer, this recipe adds a key for that. If a wider
split is enough, try `<leader>oz` (zoom) first.

The three layouts:

| Layout | Panel |
| --- | --- |
| Focused | Hidden |
| Side by side | Split on the right (`ui.position = 'right'`) |
| Full window | Replaces the current window (`ui.position = 'current'`) |

## Try it

From a checkout of the plugin, read [`demo.lua`](demo.lua), then run:

```vim
:luafile docs/recipes/three-state-layout/demo.lua
```

The script maps `zl` and `zL` in normal mode, overriding Neovim's built-in
horizontal scroll keys:

| Key | From focused | From side by side | From full window |
| --- | --- | --- | --- |
| `zl` | Side by side | Focused | Side by side |
| `zL` | Full window | Full window | Focused |

To keep it, copy the contents of `demo.lua` into your config, and change the
keys if you use `zl`/`zL` for scrolling.

## Caveats and undo

The script changes `ui.position` at runtime, so the panel opens in the last
layout you chose until you restart Neovim. To undo, remove the mappings (or
restart Neovim if you only ran the demo).

Related: [TUI/Neovim sync](../bidirectional-sync/README.md).
