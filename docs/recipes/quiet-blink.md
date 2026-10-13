# Quiet Blink completion

[Recipes](README.md) / Quiet Blink completion

Keep automatic completion useful for mentions without opening a menu for every
word of a prompt. This recipe requires lazy.nvim and an existing blink.cmp setup.

It changes automatic presentation only for the `opencode` input filetype. All
configured sources stay available; explicit trigger characters and manual
completion still work. Other buffers keep their existing behavior.

Add this to your lazy.nvim specs:

```lua
return {
  {
    'saghen/blink.cmp',
    optional = true,
    opts = function(_, opts)
      opts.completion = opts.completion or {}
      opts.completion.menu = opts.completion.menu or {}
      opts.completion.ghost_text = opts.completion.ghost_text or {}

      local inherited_auto_show = opts.completion.menu.auto_show
      local inherited_ghost_text_enabled = opts.completion.ghost_text.enabled

      opts.completion.menu.auto_show = function(ctx, items)
        if vim.bo[ctx.bufnr].filetype == 'opencode' then
          return ctx.trigger.kind == 'trigger_character'
        end
        if type(inherited_auto_show) == 'function' then
          return inherited_auto_show(ctx, items)
        end
        return inherited_auto_show ~= false
      end

      opts.completion.ghost_text.enabled = function()
        local ghost_text_enabled = type(inherited_ghost_text_enabled) == 'function'
            and inherited_ghost_text_enabled()
          or inherited_ghost_text_enabled == true
        if vim.bo.filetype == 'opencode' then
          return ghost_text_enabled and require('blink.cmp').is_menu_visible()
        end
        return ghost_text_enabled
      end

      return opts
    end,
  },
}
```

Open input and type a sentence: no automatic menu should interrupt it. Type a
mention trigger or invoke manual completion to confirm completion still works.
Ghost text remains off unless you enabled it already and the menu is open.

This uses Blink's completion-context API; check your installed Blink version if
the recipe does not match its settings. To undo it, remove this spec extension.
