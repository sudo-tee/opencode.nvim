# v2.0.1 原始 health fixture

- server: `~/.local/opt/opencode-v2/bin/opencode v2.0.1`
- request: `GET /api/health`，Basic Auth `opencode:testpass123`
- response: JSON `healthy=true, version=2.0.1`
- request: `GET /global/health`，同一认证
- response: HTTP 200 HTML（不能视为 V1 health）

`runtime-contracts-2.0.1.json` 记录同一 v2.0.1 进程的 endpoint 级 live
合同：query/body 位置、响应外壳和 mutation status。它不包含凭证或 provider
配置值，也不替代各 endpoint 的原始 response fixture。
