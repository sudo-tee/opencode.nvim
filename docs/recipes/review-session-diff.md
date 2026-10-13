# Review a session diff

[Recipes](README.md) / Review a session diff

Comment on the agent's changes line by line, then send the comments with your
next prompt. Requires OpenCode V2. For layouts, message ranges, and remapping,
see [Reviewing changes](../review.md).

1. Run `:Opencode diff open` (or `<leader>od`), pick a file, and move into its
   preview.
2. Put the cursor on a line, or select several lines, and press `c`. Type your
   comment and press `<C-s>` or `:w`.
3. Use `]r` / `[r` to jump between comments, `c` to edit one, and `dc` to
   delete it. You can comment on either side of the diff, including on a
   deleted file.
4. Press `q` in the file list or preview. The prompt opens with your comments
   attached. Write a follow-up, such as "Fix these, keep the public API the
   same", and send it.

![Saved review comment beside its changed line](https://github.com/user-attachments/assets/af202f79-8980-4f46-a967-638563555967)

The context bar shows a **Review comments** item with a count. Type `#` to turn
the group off or remove a single comment. To stop attaching comments
automatically, set `context.review_comments.enabled = false`.

![Review comments in the input context completion menu](https://github.com/user-attachments/assets/9d129d2e-0aeb-4304-8919-b7d564117469)

Line numbers in a comment refer to the reviewed snapshot. If the file has
changed since then, including unsaved edits, the plugin also sends the current
code around each comment so the agent can find the right place.
