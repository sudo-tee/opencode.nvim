# Contributing

Small, focused changes are easiest to review. For a bug report, start with
[Troubleshooting](docs/troubleshooting.md#reporting-a-bug). For a feature or
architecture change, describe the workflow first so we can agree on its scope.

## Development

Run commands from the repository root. `make help` lists targets and examples.

| Command | Purpose |
| --- | --- |
| `make check` | Formatting checks, Lua type checks, and all tests |
| `make format-check` | Check Lua formatting without changing files |
| `make typecheck` | Check Lua types |
| `make test` | Run all tests |
| `make test-minimal` / `make test-unit` | Run a smaller suite |
| `make test-replay` | Run V1/V2 snapshot replay tests |
| `make replay` | Launch the interactive replay tester |
| `make replay-regenerate` | Regenerate expected snapshots with confirmation |
| `make topology` | Scan dependency topology |
| `make topology-diff` | Compare dependency topology snapshots |

Use `TEST` for a suite or file, `FILTER` for test-name filtering, and `ARGS` for
underlying tool options:

```sh
make test TEST=tests/unit/formatter_spec.lua
make test TEST=unit FILTER="Timer"
make typecheck ARGS="-f github"
make replay ARGS="-c ReplayAll"
make replay-regenerate FILE=v2/formatters.json
make topology ARGS="--json"
make topology-diff ARGS="--from main --to HEAD --json"
```

For replay regeneration, `FILE` is relative to `tests/data`. See
[dependency topology docs](scripts/dependency-topology/README.md) for scanner
options and policy details.

Read [`AGENTS.md`](AGENTS.md) and any instructions in the directory you change.
For Lua changes, format **changed files only** with `stylua`, run
`make format-check`, and get `make typecheck` to zero errors. Run relevant tests
and report missing tools or unrelated failures rather than silently fixing
unrelated files. `make format` formats the whole project; do not use it for a
small patch.

## Documentation

Documentation lives in this repository, not a wiki. Update it in the same PR as
the code it describes.

### Where a change belongs

- **README:** what the plugin does, installation, a quick start, and links.
  No defaults table or full action list.
- **Guides in `docs/`:** explain a task in the order someone performs it.
- **Reference pages:** exact settings, command/API contracts, and caveats.
- **Recipes:** optional, self-contained workflows with prerequisites and undo
  instructions. Start from the [template](docs/recipes/TEMPLATE.md).
- **`doc/opencode.txt`:** a short `:help` entry point that points to `docs/`.

### Writing and examples

Write for someone in the middle of a task. Say what to press and what happens.
Skip adjectives like “seamless” or “powerful”; an example says more. Label
experimental and V1-only behavior in the section that describes it.

Describe what the user sees, not how the code works. Internal names, state
fields, and protocol details belong in code comments or the PR description.
Add a warning only when an action can lose work or leak data, and say it once.

Check defaults and keys against [`config.lua`](lua/opencode/config.lua), API
names against [`api.lua`](lua/opencode/api.lua), and commands against their
[handlers](lua/opencode/commands/handlers). The full defaults table lives only in
[`docs/configuration.md`](docs/configuration.md); update it when `config.lua`
changes. Provider, agent, and server settings belong to OpenCode, so link to its
docs instead of repeating them.

Lua examples should run as pasted. Say whether a block goes in a lazy.nvim spec
or in `setup()`. When showing a remap, disable the old key explicitly.

### Screenshots and videos

Capture the real plugin, not a mockup:

- Use a small project with readable code. Keep one theme and font size across
  a set of images, and crop empty space rather than context.
- Show the action and its result. Cut install waits and long model thinking;
  aim for 15–30 seconds per clip.
- Remove secrets, personal paths, private prompts, and URLs that contain
  credentials. `<leader>oDu` copies such a URL.
- Write alt text that describes what the image shows. Give a video a one-line
  summary in the surrounding text.
- Upload recordings as GitHub attachments and put the URL on its own line
  instead of using a `<video>` tag. Small, stable images can go in `docs/assets/`.
- Do not add a screenshot that shows the same state as an existing one.

Missing media is better than a broken link. If a page needs a capture you
cannot make, describe it in the PR instead of adding a placeholder.

### Before submitting a docs change

- Preview Markdown on GitHub or a compatible renderer.
- Check relative links, heading anchors, and code fences.
- Compare commands, keys, API names, and defaults with the current source.
- Test executable examples where practical; note anything not exercised.
- For vimdoc edits, run `:helptags doc` in a checkout and open `:help opencode.nvim`.
  Do not commit generated `doc/tags`.

Docs-only changes do not need the test suite. In the PR, say which examples you
ran and which you only read through.
