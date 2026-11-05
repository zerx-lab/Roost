---
description: 项目记忆文件中禁止出现明文凭据
condition: "(?i)(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(api[_-]?key|secret|password|passwd|token)\\s*[:=]\\s*[^\\s<]{8,})"
scope: "tool:edit(.omp/memory/**), tool:write(.omp/memory/**)"
interruptMode: always
---
`.omp/memory/` 会提交进仓库,并在每次会话启动时注入上下文,因此不能写入任何明文凭据(API key、token、密码、私钥)。

只记录"凭据存放在哪里、叫什么名字",例如"PG 密码见用户级 AGENTS.md"或"环境变量 `FOO_TOKEN`",不要记录凭据的值。
