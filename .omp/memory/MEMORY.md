# Roost 项目记忆

维护规则见 `.omp/RULES.md` 中的「项目记忆」一节。本文件随根目录 `AGENTS.md` 在会话启动时注入,上限 150 行(`scripts/check.sh` 会检查),超出后运行 `/memory-tidy` 整理。
条目格式:`- [YYYY-MM-DD] 结论 — 依据:<路径|命令|"用户确认">`。新条目写在所属小节的最前面。

## 目标

- [2026-11-05] Roost 是 Tern 插件,目标是做一个能自我升级、自我迭代的工作台。架构尚未确定,不要把猜测写成决策 — 依据:用户确认

## 决策(当前有效)

- [2026-11-05] 架构:omp 在本地(Tern 插件 host)执行;cron 是插件核心,在插件内调度。服务器上的 `roost-agent`(Rust)是监控探针式的中继节点,不是 AI 运行时:只接 GitHub webhook、验签、按订阅过滤、缓存事件供本地长轮询拉取,外加 GitHub hook 注册、远程 reload/重启 — 依据:用户确认
- [2026-11-05] 配置分层:本地 `plugin-data/roost/roost.toml`(中继地址/令牌绑定)+ `workflows.toml`(repos 本地路径、工作流、cron/github 触发、步骤);服务器 `agent.toml`(监听、密钥,不同步)+ `subscriptions.toml`(repo→事件,由插件推送,推送失败时在服务器手改后远程 reload) — 依据:用户确认「本地优先、云端同步、失败回退云端手动」
- [2026-11-05] 运行安全默认:用户可写内容事件只接受 OWNER/MEMBER/COLLABORATOR(`associations = ["*"]` 放开);shell 步骤不做模板替换,只给 `ROOST_*` 环境变量 — 依据:lib/match.luau、lib/runner.luau(主会话设计,未经用户另行确认)
- [2026-11-05] 记忆只放在仓库内的 `.omp/memory/`,不使用 omp 用户级记忆(`.omp/config.yml` 设了 `memory.backend: off`、`autolearn.enabled: false`) — 依据:用户确认
- [2026-11-05] omp 在本项目使用 yolo 模式,TTSR 设为 after-gap 且间隔 8 轮;Luau/Rust 的防 panic、防内存失控由 TTSR 规则加 `scripts/check.sh` 共同把关 — 依据:用户确认

## 约束与陷阱

- [2026-11-05] `tern.json.array(t)` 会就地给 t 加受保护元表,`tern.json.decode` 出来的数组也带;之后 `table.clone(t)` 直接抛错。序列化时给副本打标签(`table.move(t, 1, #t, 1, {})`);fake_tern 已同样模拟 — 依据:Tern daemon 日志实测(lib/store.luau save)
- [2026-11-05] Luau strict 下 `pcall(fn)` 若 fn 无返回值,只能接 1 个返回值;要拿错误信息就包一层 `pcall(function(): string? ...; return nil end)` — 依据:luau-lsp 实测(lib/runner.luau)
- [2026-11-05] `tern.process.run` 无法启动时会直接抛错(不是回调报错),调用处必须 pcall,否则会打断调用方的 timer 循环 — 依据:tern.d.luau process.run 注释、ReviewFixes 审查
- [2026-11-05] Luau 长字符串 `[[ ]]` 里出现 `[[workflow]]` 会提前结束,TOML 模板要用 `[==[ ]==]` — 依据:lib/core.luau DEFAULT_WORKFLOWS
- [2026-11-05] 测试不要直接写全局 `__fresh`(luau-lsp 报未知全局),改用 `require("./harness").fresh(env)`,由 tests/run.py 替换为真实实现 — 依据:tests/run.py
- [2026-11-05] GitHub 的 check_suite/check_run 负载不一定带 head_repository,fork 闸门对来源不明的 CI 事件默认拒绝,需要 `forks = true` — 依据:lib/match.luau、agent/src/event.rs
- [2026-11-05] Tern 递归监听 link 安装的插件目录(包括 `.omp/`、`.git/`),任何文件变化都会重载全部插件。开发期间写记忆或构建都会触发重载;构建产物一律放到 `/tmp/roost-cargo-target` 或 `tern.plugin.data` — 依据:docs.stencil.so/tern/concepts/lifecycle.md#watching
- [2026-11-05] Tern 没有插件更新机制,`version` 只用于显示;要实现自升级只能由插件自己完成,或者 `tern plugin install --force` — 依据:docs.stencil.so/tern/guides/distribution.md
- [2026-11-05] `luau-analyze` 无法加载 `tern.d.luau`,类型检查必须用 `luau-lsp analyze --definitions=@tern=tern.d.luau` — 依据:本机实测
- [2026-11-05] 全局配置 `disabledProviders` 含 `typesafe`,导致 `ttsr.judge: auto` 不生效,`question` 类 TTSR 规则不会触发;只用 condition/astCondition — 依据:~/.omp/agent/config.yml

## 被否方案

- [2026-11-05] 使用 omp 的 local / sharpshooter 记忆后端:数据存在 `~/.omp/agent/memories`,不随仓库走,所以不用 — 依据:用户确认

## 主题索引

(暂无。复杂主题放在 `.omp/memory/topics/<slug>.md`,并在这里加一行 `- <slug>:一句话说明`)
