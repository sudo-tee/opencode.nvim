# Review a session diff

Add inline feedback to changes from an OpenCode V2 session diff, then include that feedback as context in your next prompt.

1. Run `:Opencode diff open`, select a file, and move into its preview.
2. Place cursor on a line or visually select lines, then press `c`. Type feedback and press `<C-s>` (or `:w`).
3. Use `]r` / `[r` to revisit comments, `c` to edit, or `dc` to remove. A comment can refer to either side or to a deleted file.
4. Press `q` to close the diff. Input receives focus with pending comments. Write a prompt and send it; comments are attached automatically.

The input context bar shows the new **Review comments** context item and count. Type `#` to toggle the whole group or select a comment to remove it individually. Disable automatic inclusion with `context.review_comments.enabled = false`.

Line numbers refer to the reviewed session snapshot. Comments on the same file share one attachment and one locating instruction; each keeps its own feedback and original snippet. Neighboring lines and diff range stay local to resolve drift. Before sending, it checks current file contents, including unsaved edits. Only changed, moved, removed, or missing code adds current-file details to the payload.
