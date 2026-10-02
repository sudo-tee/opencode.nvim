# v2.0.1 原始 health fixture

- server: `~/.local/opt/opencode-v2/bin/opencode v2.0.1`
- request: `GET /api/health`，Basic Auth `opencode:testpass123`
- response: JSON `healthy=true, version=2.0.1`
- request: `GET /global/health`，同一认证
- response: HTTP 200 HTML（不能视为 V1 health）

`runtime-contracts-2.0.1.json` 记录同一 v2.0.1 进程的 endpoint 级 live
合同：query/body 位置、响应外壳和 mutation status。它不包含凭证或 provider
配置值，也不替代各 endpoint 的原始 response fixture。

## Shared tool-result renderer snapshots

These synthetic V2 message fixtures have matching `.expected.json` renderer snapshots:

- `execute-results.json`: running-to-completed execute input, ordered text results, and a local file attachment.
- `mcp-results.json`: running-to-completed MCP input, Markdown results, an HTTP attachment, and a named inline attachment.
- `generic-results.json`: custom-tool JSON input, local and unnamed inline attachments, an empty-input browser tool, and a namespaced session tool with partial results and an error.

Run `make test-replay` to compare buffer lines, extmarks, and actions across full rendering, incremental replay, and reset/replay.
