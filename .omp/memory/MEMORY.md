# Roost 项目记忆

维护规则见 `.omp/RULES.md` 中的「项目记忆」一节。本文件随根目录 `AGENTS.md` 在会话启动时注入,上限 150 行(`scripts/check.sh` 会检查),超出后运行 `/memory-tidy` 整理。
条目格式:`- [YYYY-MM-DD] 结论 — 依据:<路径|命令|"用户确认">`。新条目写在所属小节的最前面。

## 目标

- [2026-11-05] Roost 是 Tern 插件,目标是做一个能自我升级、自我迭代的工作台。架构尚未确定,不要把猜测写成决策 — 依据:用户确认

## 决策(当前有效)

- [2026-11-06] 编辑器模型下拉框取自本机 omp:`core.omp_models` 跑 `omp config get modelRoles` 与 `omp models --json`(缓存 5 分钟,失败 15 s 重试),选项为 Auto / `@<角色>` / `provider/id`,取代写死的 opus/sonnet/haiku。`omp --model @<角色>` 由 omp 按 modelRoles 解析 — 依据:`omp -p --model @smol --mode json` 实测解析为 grok-composer-2.5-fast;用户问「为什么只显示 claude 模型名」
- [2026-11-06] 合并闸门手动指定 PR:输入 `pr`(编号或链接,`ROOST_INPUT_PR`)时 `gate` 只处理该 PR(`gate_one` → 与扫描共用的 `assess`)。分级 A/B、CI、mergeable、否决窗口照旧;静默时段与每日上限只拦合并、不拦审查;同一提交审查未通过的也重审。PR 手动运行表单(`dispatch_pr`)不适用于它:它的触发器是 workflow_run/cron,不是 PR 类 — 依据:主会话取舍,用户要求「自动合并也需要支持指定手动运行」
- [2026-11-06] 手动对指定 PR 运行:有 PR 类触发器(`model.PR_KINDS`)的工作流,运行表单加「拉取请求」字段,`core.dispatch_pr` 用本机 `gh api repos/R/pulls/N` 读 PR,`match.pr_info` 按 event.rs 的字段构造事件(`action = "manual"`),在 `refs/pull/N/head` 运行。用本机 gh 而不是中继:中继没有 PR 读取接口,加接口要改 agent 并重新部署 — 依据:主会话取舍,用户要求「工作流支持手动运行给指定的 pr」
- [2026-11-06] FluxDown issue 自迭代在 Roost 内实现(不扩展服务器上的 ZerxLabBot),接受 Mac 必须开机:工作流 `fluxdown-issue-triage`/`-fix`/`fluxdown-merge-gate` + `plugin-data/roost/scripts/fluxdown-issues.py` 与 `scripts/fluxdown-issues/*.md` 提示词;UI 提案要 OWNER 在 issue 回复 `/approve` 才实现;Flutter 遗留问题直接关闭,确认真实存在的才索要信息/复测,需要本机启动界面复现的转维护者(`roost:maintainer`)不回复 — 依据:用户确认
- [2026-11-06] 模型分层与合并分级:composer-2.5 初判 → sonnet 复核(会关闭/修复/提案的一律复核)→ sonnet 修复(hard 用 opus)→ 异构模型独立审查;只有 A(文档/测试/非基线翻译)与 B(纯逻辑模块白名单、非测试 ≤150 行)自动合并,UI/客户端/依赖清单永不自动合并。合并闸门对**任何人的 PR** 开放:opus 必须实际验证(跑相关测试、证明 PR 测试在基线失败而在 PR 通过、缺测试就写临时测试),外部 PR 先通读会被执行的代码(build.rs/测试/脚本)再运行;禁止启动 GPUI 客户端/任何图形界面和默认端口/数据目录的 daemon;`review.json` 没有 `verification` 记录则不合并。费用不设限,修复每天上限 10 个只为不占满本机 — 依据:用户确认「合并任何人的 PR」「不能只靠 CI,要尽量测试,只禁止启动 GPUI 客户端」「不需要考虑预算」
- [2026-11-06] FluxDown 流水线的安全取舍:控制数据(本批名单、到期列表、基线/HEAD/分级)放 `plugin-data/roost/fluxdown-issues/runs/<运行id>/`,agent 只写 worktree 里的 `.roost-issues/` `.roost-fix/`;B 级是纯逻辑模块白名单(naming、queue_order 等),其余 native 一律 C;官网表单转发的匿名 issue 缺信息直接按 invalid 关闭、咨询答复后关闭;回复只允许项目链接并去掉 @ 与关闭关键词。残留风险:omp yolo 步骤带 App 令牌与本机凭据,issue 文本的提示词注入无法在进程内完全隔离 — 依据:两轮 reviewer(PipelineReview/PipelineReReview)后主会话取舍
- [2026-11-06] 步骤编排扩展:`$ROOST_OUTPUT` 的 `key=value` → `{{out.x}}`/`ROOST_OUT_X`,`when = "out.x"|"!input.y"`,`stop=原因` 以 skipped 结束运行(不弹通知);工作流 `daily_budget`(美元/本机日)按 StepRec `cost` 拦截 omp 步骤 — 依据:lib/runner.luau held/take_outputs/tally_agent(为 FluxDown 流水线设计)
- [2026-11-06] 运行默认以 GitHub App 身份写 GitHub(`[github] identity = "app"`,工作流可 `identity` 覆盖,无仓库的运行用本机 gh):App 申请 actions/checks/contents/deployments/discussions/issues/pull_requests/statuses/workflows 读写 + administration;中继每次运行签发只限一个仓库、去掉 administration 的令牌,签发前确认默认分支禁止强推与删除(没有就建规则集,建不了就拒发)。用户接受授权风险,要求权限尽量大,只禁止强推 main;rebase、冲突处理、推送 main 都允许 — 依据:用户确认
- [2026-11-06] 中继保管 administration 只为默认分支保护;ruleset 允许仓库管理员绕过(用户本人保留强推能力),App 不能 — 依据:agent/src/github.rs guard_ruleset(主会话取舍,未经用户另行确认)
- [2026-11-06] 长期数据一律自动+手动可清理:本地 `roost.toml [retention]`(runs/run_age/events/event_age,默认 200 条/30d,替代 `[runner] keep_runs`;`runs` 只计已结束运行)只删已结束运行,有效 roost.toml 出现前不按策略删任何东西;目录两阶段删除(索引立即更新→trash 交给进程外 `rm -rf` 分批);事件页落盘 `events.json`;中继 `DELETE /api/v1/events`(不回退序号)与 `GET|DELETE /api/v1/deliveries`(内存计数);UI 删除/清空需两次独立点击(0.8–5 s,低于此算双击) — 依据:用户要求「长时间存储的数据需要支持手动清理和自动清理」;实现细节为主会话设计,RetentionReview 两轮审查后补强
- [2026-11-06] 事件页历史回填:首次连接或还没有 `events.json` 时,只取游标之前(含)的最近 20 条作 history 行,不运行;取游标之后的会与实时处理的 dedup 冲突,导致事件不触发 — 依据:lib/relay.luau backfill、tests/test_core.luau「no events.json yet」
- [2026-11-06] 工作流以 Grok 式表单编辑(对标 grok.com/automations):workflows.toml v2 用 `schedule = once|hourly|daily|weekly|monthly|yearly|cron` 与 `github = <语义种类>`(各种类筛选器固定,至少一个筛选器);编辑器只替换对应 `[[workflow]]` 块,`model.parse_workflows` 是唯一校验器 — 依据:用户确认「toml 可变更,对标 grok,只做 GitHub 与定时」
- [2026-11-06] roost-agent 以 GitHub App 运行:manifest 一键创建,凭据存 `<data>/github-app.json`(0600);移除 PAT 与逐仓库 webhook 同步(写权限与运行令牌见上面「以 GitHub App 身份写 GitHub」) — 依据:用户要求「agent 安装为 GitHub 自定义 app」
- [2026-11-06] omp 步骤以 Tern 原生 agent block 运行:window 用 `cx.agents:start` 在固定会话(`[runner] session`,默认 Roost)新开 tab,不抢焦点,无论成败结束后都关闭;会话经 `--session-dir` 存进运行目录,随运行按 `[retention]` 清理,不进 `~/.omp`;历史会话用独立 block `roost.sessions` 左分屏查看。被否:终端 tab 跑 `omp -p`、控制台内嵌左栏、失败 tab 保留 — 依据:用户确认
- [2026-11-06] agent 步骤协议:host 写 `s<i>.job.json` + kv `agent_jobs`;window `mkdir s<i>.claim` 认领、写 `.pane`/`.exit`/`.reply.txt`;未认领时的停止、认领后 30 s 仍无 pane 由 host 自己写 exit。omp 步骤只拿到 App 身份变量(`agent.with_env` 用 /bin/sh source `s<i>.env` 再 exec omp),拿不到 `env`/`ROOST_*` — 依据:lib/agent.luau(主会话设计,未经用户另行确认)
- [2026-11-05] 架构:omp 在本机执行(2026-11-06 起由 window 打开 agent block,见上条);定时在插件内调度。服务器上的 `roost-agent`(Rust)是中继节点,不是 AI 运行时:以 GitHub App 接 webhook、验签、按订阅过滤、缓存事件供本地长轮询拉取,外加编辑器建议查询、远程 reload/重启 — 依据:用户确认
- [2026-11-05] 配置分层:本地 `plugin-data/roost/roost.toml`(中继地址/令牌绑定)+ `workflows.toml`(repos 本地路径、工作流、cron/github 触发、步骤);服务器 `agent.toml`(监听、密钥,不同步)+ `subscriptions.toml`(repo→事件,由插件推送,推送失败时在服务器手改后远程 reload) — 依据:用户确认「本地优先、云端同步、失败回退云端手动」
- [2026-11-05] 运行安全默认:用户可写内容事件只接受 OWNER/MEMBER/COLLABORATOR(`associations = ["*"]` 放开);shell 步骤不做模板替换,只给 `ROOST_*` 环境变量 — 依据:lib/match.luau、lib/runner.luau(主会话设计,未经用户另行确认)
- [2026-11-05] 记忆只放在仓库内的 `.omp/memory/`,不使用 omp 用户级记忆(`.omp/config.yml` 设了 `memory.backend: off`、`autolearn.enabled: false`) — 依据:用户确认
- [2026-11-05] omp 在本项目使用 yolo 模式,TTSR 设为 after-gap 且间隔 8 轮;Luau/Rust 的防 panic、防内存失控由 TTSR 规则加 `scripts/check.sh` 共同把关 — 依据:用户确认

## 约束与陷阱

- [2026-11-06] 插件 host 的 `tern.process.run` 继承的是 daemon 的精简环境(launchd),没有 fish 配置里的 PATH 与变量(omp 在 `~/.bun/bin`,直接调会 127)。现由 `lib/loginenv.luau` 在启动与每 10 分钟用登录 shell(dscl UserShell → $SHELL)`-l -i -c` 输出带标记的 `env -0`,shell 步骤与 gh/omp 调用都以它为底;首次读取结束前 runner 的 `pump`/`check` 不推进(不能在 `next_step`/`start_step` 里挡:exit 文件还在,下一轮 check 会重复 step_done)。只放内存,因为含 fish 导出的密钥。agent 步骤不受影响(Tern agent block 用登录环境) — 依据:编辑器模型下拉框报「exec: omp: not found」、`env -i … fish -l -i -c env -0` 实测、用户要求「继承系统变量和 fish 的变量」
- [2026-11-06] Tern 视图布局:`.sf-tbl` 自带 `margin: 0 -7px`,在不裁剪的容器里会让窗格轻微横向滚动,Roost 用 `roost.run { overflow-x: clip }` 兜住。让 split 铺满剩余高度、长内容只在内部滚动:Tern 的布局对直接挂在 `.sf-main` 下的 col 即使 `flex: 1 1 0; min-height: 0` 也按内容高度撑开(整页滚动),必须再加 `overflow: hidden`,下层(split、窗格 col、日志 scroll)才跟着收缩;节点 `grow`/`min` 属性同样无效。`ansi` 节点忽略自己的 `min` 属性,要给它套一层 col 设 `min.w` — 依据:headless `tern serve` + TSP 探针的 layout JSON 实测
- [2026-11-06] 不碰用户界面也能验证插件布局:`TERN_CONFIG_DIR=<tmp> TERN_DAEMON_SOCKET=<tmp> tern serve --control <sock>` 起隔离的无头实例,Python 脚本经 TSP(`tsp;q` hello → `o` screen surface,`role = "plugin.roost.console"` → `f` 节点树)画出同样的结构,`tern ctl --control <sock> css <名> roost.css` 以全局表注入真实样式(TSP `s` 表会被加 `[data-scope]` 前缀,`[data-surface]` 选择器匹配不到),再 `shot` 取 layout JSON。探针用 raw tty 时 Ctrl+C 杀不掉,要 pkill。`tern ctl dump` 只能看用户当前可见的 block — 依据:本次实测
- [2026-11-06] ZerxLabBot 已由用户关闭;脚本仍认它留下的 `fd-triage:needs-info` 标记(算作提问时间),`OTHER_BOTS` 的「两天内评论过就跳过」已无实际作用 — 依据:用户告知
- [2026-11-06] omp 会话费用:assistant 消息的 `usage` 与 `type:"model_usage"`(judge、cache-warm 等旁路调用)都要计;子代理会话在 `<会话名>/<Agent>.jsonl`;xai-oauth 的 cost 恒为 0。原始文本里 `"cost":{…}` 只会出现在真正的 usage 对象中(字符串内引号已转义) — 依据:本机会话 grep/awk 与 Python 解析对账
- [2026-11-06] 本机 huacnlee cargo 的构建目录固定在 `~/.cargo/targets/<仓库名>-<哈希>`(按 git 公共目录区分,`build.build-dir`/`CARGO_TARGET_DIR` 都被忽略,`./target` 只放锁与少量产物),依赖另存 `shared-deps`;同一仓库的所有 worktree 共用构建目录和锁。所以 Roost 的 FluxDown 工作流用专用克隆 `plugin-data/roost/repos/FluxDown`(独立构建目录,不阻塞维护者的开发构建),脚本 `check_isolated` 拒绝在开发仓库的 worktree 里运行。旧结论「worktree 每次从零编译」是误判 — 依据:`cargo test --no-run` 输出的 Executable 路径(开发仓库 worktree → FluxDown-0dd7a27c,克隆 → FluxDown-8e361165)
- [2026-11-06] `label` 触发器的 `label_actions` 取值是 `added`/`removed`(不是 GitHub 的 labeled) — 依据:model.parse_workflows 报错
- [2026-11-06] GitHub 没有设置 App 头像、修改 App 权限的 API:头像只能在 App 设置页上传(中继无法同步);权限改了以后每个安装还要手动接受,未生效的权限由 AppInfo `missing` 列出 — 依据:docs.github.com「Creating a custom badge for your GitHub App」
- [2026-11-06] 本机 `cargo` 是 huacnlee/cargo 分支(`~/.cargo/bin/cargo`),忽略一切 target-dir 设置、总写 `./target`;`.cargo/config.toml` 的 `/tmp/roost-cargo-target` 因此无效。`scripts/check.sh` 改为在 `/tmp/roost-rust` 镜像(带 `.cargo/config.toml`、`clippy.toml`)里跑 fmt/clippy/test,并在 `agent/target` 出现时报错;zigbuild 交叉编译也在镜像里做(`/tmp/roost-rust/agent/target/x86_64-unknown-linux-musl/release/roost-agent`) — 依据:cargo 输出 warning「this cargo always uses ./target」
- [2026-11-06] 从本机脚本访问 `https://roost.zerx.dev` 时,Python 默认 UA(Python-urllib)会被 Cloudflare 返回 403,需要显式设置 User-Agent。部署新 agent 时旧二进制备份为 `/usr/local/bin/roost-agent.prev` — 依据:本次部署冒烟实测
- [2026-11-06] `tern shot` 离屏渲染加载了插件 host(`tern plugin list` 显示 ready),但无头窗口不加载插件 window 半边,也不提供「New <block>」入口,所以截不到插件 block 的界面。界面效果只能让用户截图确认 — 依据:`TERN_CONFIG_DIR=… tern shot` 场景实测(palette 搜不到 Roost 命令和 block)
- [2026-11-06] Tern 视图规范:按钮行/工具栏 `gap = "sm"`(6px,`xs` 只有 2px 会显得挤在一起);card 不包表格、stats 或别的 card;card 头部控件 `["end"]` 填该子节点的完整 id(由各级 key 拼成,例如运行卡片是 main.body.runs.run 加 .end);没有甘特图,步骤时间线用 meter 的 parts,首段颜色名写 "track" 充当偏移 — 依据:docs.stencil.so/tern/guides/design.md、elements/motion.md、用户截图反馈
- [2026-11-06] 回合刚结束时 window 的 `cx.agents:transcript(pane,{last=1})` 可能还是上一条 assistant 消息,`s<i>.reply.txt` 因此会错;最终回复以会话 JSONL 为准(host 的 `agent.progress` 读取)。omp 会话 JSONL 是紧凑 JSON(`"role":"assistant"` 无空格),assistant 的 `stopReason` 取 toolUse|stop|error|aborted,error 时文本为空、原因在 `errorMessage` — 依据:run 006aed55ba0dd9 的 s3.reply.txt 与 jsonl 对比、`~/.omp/agent/sessions` 统计
- [2026-11-06] 中继部署:`root@<中继服务器>`(Ubuntu x86_64,root 默认 shell 是 fish,远程命令要包 `bash -c`)。`roost-agent` 用 systemd(`/etc/roost/{agent.toml,env}`,数据 `/var/lib/roost`)监听 127.0.0.1:8787;1Panel的 OpenResty 反代站点 `roost.zerx.dev`,用通配证书 `*.zerx.dev`;外层还有 Cloudflare 代理(`*.zerx.dev` 是橙云通配,源站没有证书的站点会返回 525)。本机 DNS 被代理软件劫持为 198.18.x,要查真实解析需在服务器上 `dig @1.1.1.1` — 依据:本次部署实测
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
- [2026-11-05] Tern 递归监听 link 安装的插件目录(包括 `.omp/`、`.git/`),任何文件变化都会重载全部插件。开发期间写记忆或构建都会触发重载;构建产物一律放到仓库外(本机 cargo 见上面 huacnlee 一条)或 `tern.plugin.data` — 依据:docs.stencil.so/tern/concepts/lifecycle.md#watching
- [2026-11-05] Tern 没有插件更新机制,`version` 只用于显示;要实现自升级只能由插件自己完成,或者 `tern plugin install --force` — 依据:docs.stencil.so/tern/guides/distribution.md
- [2026-11-05] `luau-analyze` 无法加载 `tern.d.luau`,类型检查必须用 `luau-lsp analyze --definitions=@tern=tern.d.luau` — 依据:本机实测
- [2026-11-05] 全局配置 `disabledProviders` 含 `typesafe`,导致 `ttsr.judge: auto` 不生效,`question` 类 TTSR 规则不会触发;只用 condition/astCondition — 依据:~/.omp/agent/config.yml

## 被否方案

- [2026-11-06] App 只读、写操作走本机 gh(不下发安装令牌):用户要求运行以 App 身份操作 — 依据:用户确认
- [2026-11-06] 拖拽式工作流画布:Tern 没有拖拽 API;Grok 本身也是表单流程 — 依据:Tern 文档、grok.com/automations 实测
- [2026-11-06] GitHub 触发器沿用原始事件名 + actions 过滤:与 Grok 的语义种类对不上,表单无法按种类给出正确筛选器;保留为 `github = "event"` 逃生口 — 依据:用户确认对标 grok
- [2026-11-05] 使用 omp 的 local / sharpshooter 记忆后端:数据存在 `~/.omp/agent/memories`,不随仓库走,所以不用 — 依据:用户确认

## 主题索引

(暂无。复杂主题放在 `.omp/memory/topics/<slug>.md`,并在这里加一行 `- <slug>:一句话说明`)
