# Roost 项目记忆

维护规则见 `.omp/RULES.md` 中的「项目记忆」一节。本文件随根目录 `AGENTS.md` 在会话启动时注入,上限 150 行(`scripts/check.sh` 会检查),超出后运行 `/memory-tidy` 整理。
条目格式:`- [YYYY-MM-DD] 结论 — 依据:<路径|命令|"用户确认">`。新条目写在所属小节的最前面。

## 目标

- [2026-11-05] Roost 是 Tern 插件,目标是做一个能自我升级、自我迭代的工作台。架构尚未确定,不要把猜测写成决策 — 依据:用户确认

## 决策(当前有效)

- [2026-11-06] 工作流以 Grok 式表单编辑(对标 grok.com/automations):workflows.toml v2 用 `schedule = once|hourly|daily|weekly|monthly|yearly|cron` 与 `github = <语义种类>`(各种类筛选器固定,至少一个筛选器);编辑器只替换对应 `[[workflow]]` 块,`model.parse_workflows` 是唯一校验器 — 依据:用户确认「toml 可变更,对标 grok,只做 GitHub 与定时」
- [2026-11-06] roost-agent 以 GitHub App 运行:manifest 一键创建,凭据存 `<data>/github-app.json`(0600),只申请只读权限;移除 PAT 与逐仓库 webhook 同步;写 GitHub 的动作仍由本机 `gh` 完成,不下发安装令牌 — 依据:用户要求「agent 安装为 GitHub 自定义 app」;只读权限为主会话取舍
- [2026-11-06] omp 步骤以 Tern 原生 agent block 运行:window 用 `cx.agents:start` 在固定会话(`[runner] session`,默认 Roost)新开 tab,不抢焦点,无论成败结束后都关闭;会话经 `--session-dir` 存进运行目录,随 keep_runs 清理,不进 `~/.omp`;历史会话用独立 block `roost.sessions` 左分屏查看。被否:终端 tab 跑 `omp -p`、控制台内嵌左栏、失败 tab 保留 — 依据:用户确认
- [2026-11-06] agent 步骤协议:host 写 `s<i>.job.json` + kv `agent_jobs`;window `mkdir s<i>.claim` 认领、写 `.pane`/`.exit`/`.reply.txt`;未认领时的停止、认领后 30 s 仍无 pane 由 host 自己写 exit。agent 命令不加 `env K=V` 前缀,所以 omp 步骤拿不到 `env`/`ROOST_*` — 依据:lib/agent.luau(主会话设计,未经用户另行确认)
- [2026-11-05] 架构:omp 在本机执行(2026-11-06 起由 window 打开 agent block,见上条);定时在插件内调度。服务器上的 `roost-agent`(Rust)是中继节点,不是 AI 运行时:以 GitHub App 接 webhook、验签、按订阅过滤、缓存事件供本地长轮询拉取,外加编辑器建议查询、远程 reload/重启 — 依据:用户确认
- [2026-11-05] 配置分层:本地 `plugin-data/roost/roost.toml`(中继地址/令牌绑定)+ `workflows.toml`(repos 本地路径、工作流、cron/github 触发、步骤);服务器 `agent.toml`(监听、密钥,不同步)+ `subscriptions.toml`(repo→事件,由插件推送,推送失败时在服务器手改后远程 reload) — 依据:用户确认「本地优先、云端同步、失败回退云端手动」
- [2026-11-05] 运行安全默认:用户可写内容事件只接受 OWNER/MEMBER/COLLABORATOR(`associations = ["*"]` 放开);shell 步骤不做模板替换,只给 `ROOST_*` 环境变量 — 依据:lib/match.luau、lib/runner.luau(主会话设计,未经用户另行确认)
- [2026-11-05] 记忆只放在仓库内的 `.omp/memory/`,不使用 omp 用户级记忆(`.omp/config.yml` 设了 `memory.backend: off`、`autolearn.enabled: false`) — 依据:用户确认
- [2026-11-05] omp 在本项目使用 yolo 模式,TTSR 设为 after-gap 且间隔 8 轮;Luau/Rust 的防 panic、防内存失控由 TTSR 规则加 `scripts/check.sh` 共同把关 — 依据:用户确认

## 约束与陷阱

- [2026-11-06] Tern UI 没有通用拖拽事件(只有 split 把手、slider、悬浮窗、文件拖入区),列表排序只能用按钮/按键 — 依据:docs.stencil.so/tern/elements(index/lists/layout)
- [2026-11-06] toml.luau 支持 `"""` 多行字符串;编辑器写回含换行的字符串用它,splice 时必须跳过多行字符串里形似 header/注释的行 — 依据:lib/model.luau mlquote、in_string
- [2026-11-06] `cx.agents`/`cx.sessions`/`cx.layout` 只在 window 可用;host block 想让窗口做事只能 `cx:open("roost://…")`,由 window 的 `tern.route.link` 认领 — 依据:tern.d.luau(EffectCx.open、LinkRequest)
- [2026-11-06] `omp --session-dir D` 是平铺布局:D 下直接是 `<ISO时间>_<id>.jsonl`,另有隐藏的 `.….jsonl.lock.os` — 依据:本机 `omp -p --session-dir /tmp/roost-sd-probe` 实测
- [2026-11-06] `cx.sessions:create` 会切换到新会话,需要手动 `switch` 回原会话;`cx.agents:start` 只能在当前会话开 tab,换到其他会话要靠 `layout:move_to_new_tab(pane, session, {focus=false})` — 依据:docs.stencil.so/tern/reference/api-window.md
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

- [2026-11-06] 拖拽式工作流画布:Tern 没有拖拽 API;Grok 本身也是表单流程 — 依据:Tern 文档、grok.com/automations 实测
- [2026-11-06] GitHub 触发器沿用原始事件名 + actions 过滤:与 Grok 的语义种类对不上,表单无法按种类给出正确筛选器;保留为 `github = "event"` 逃生口 — 依据:用户确认对标 grok
- [2026-11-05] 使用 omp 的 local / sharpshooter 记忆后端:数据存在 `~/.omp/agent/memories`,不随仓库走,所以不用 — 依据:用户确认

## 主题索引

(暂无。复杂主题放在 `.omp/memory/topics/<slug>.md`,并在这里加一行 `- <slug>:一句话说明`)
