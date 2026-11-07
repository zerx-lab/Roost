# Repository Guidelines

## Project Overview

Roost 是一个 **Tern 插件**,目标是做成一个**可自升级、可自我迭代的工作台**。

当前状态:v0.1 已实现。omp 在**本机**(插件 host)执行;cron 是插件核心;服务器上的 `roost-agent`(Rust,`agent/`)是监控探针式的事件中继,不运行工作流。架构详见下文「Architecture & Data Flow」与 `README.zh-CN.md`。下文同时保留 Tern 插件平台的既有事实(manifest、SDK、CLI、测试惯例)。

参考插件(只读,同级目录 `../`):

| 目录 | 插件 id | 可借鉴点 |
|---|---|---|
| `../omp子代理` | `omp-fleet` | 进程轮询、SVG blob、`resize`、复杂 `ui.node` |
| `../claude订阅` | `claude-usage` | `tern.fetch`、`tern.kv` 主机→窗口发布、`tern.chrome.status` |
| `../office预览` | `office-preview` | `tern.route.open`、原生 sidecar(Rust)、`scripts/{build,package}.sh`、版本戳 |

## Project Memory

项目记忆只放在仓库内,协议见 `.omp/RULES.md`(每次请求都会携带,subagent 也能收到),omp 用户级记忆在 `.omp/config.yml` 中已关闭。

| 层 | 路径 | 加载方式 |
|---|---|---|
| 索引 | `.omp/memory/MEMORY.md` | 通过下方 `@` 导入,在会话启动时注入;上限 150 行 |
| 主题 | `.omp/memory/topics/<slug>.md` | 按 MEMORY.md「主题索引」按需阅读 |
| 日志 | `.omp/memory/journal/YYYY-MM.md` | 只追加,不注入 |

写入用 `/remember <内容>`,整理用 `/memory-tidy`(都定义在 `.omp/commands/`)。`scripts/check.sh` 会检查行数预算和明文凭据;TTSR 规则 `memory-no-secrets` 在写入时就会拦截凭据。

@.omp/memory/MEMORY.md

## Architecture & Data Flow

**Roost 的数据流**:

- `host.luau` 在 daemon worker 启动时创建唯一的 `lib/core.luau` 运行时:每 3 s 读取 plugin-data 下的 `roost.toml`/`workflows.toml`(`lib/model.luau` 校验,出错保留上一份有效配置);每分钟边界检查定时触发器(`schedule`,编译成 cron;`once` 按 `at` 只触发一次);`lib/relay.luau` 对中继长轮询 `/api/v1/events`,游标存 `tern.kv` 的 `cursor`;`lib/runner.luau` 执行运行。
- 自动化编辑器(`lib/editor.luau`,Grok 式表单):`core.workflow_raw` 取原始表 → 表单编辑 → `core.check_workflow`/`save_workflow`(`model.encode_workflow` + `model.splice_workflow` 只替换该 `[[workflow]]` 块,写前备份 `.bak`,`model.parse_workflows` 校验);建议项经 `core.gh` 走中继的 GitHub App 接口。完成的运行经 kv `status.done` 让 window 弹 toast(`notify`)。
- 运行引擎:shell 步骤经 `runner.WRAPPER`(`sh -c`,`set -m` 独立进程组)启动,pid/退出码写入 `runs/<id>/s<i>.pid|.exit`;omp 步骤走 agent 协议(`lib/agent.luau`):host 写 `s<i>.job.json` 并把活跃步骤发布到 kv `agent_jobs`,window(`lib/launcher.luau`)用 `mkdir s<i>.claim` 认领,在固定会话(默认 `Roost`)新开标签页 `cx.agents:start`,记 `s<i>.pane`,本轮结束(或关闭/停止)后写 `s<i>.exit` 与 `s<i>.reply.txt` 并关闭 agent;omp 会话存于 `s<i>.session/`(`--session-dir`),随运行目录按 `[retention]` 清理。agent 运行中 host 每 2 s 按字节偏移读会话 JSONL(`agent.progress`,只处理完整行,偏移存 StepRec `tail`),把说明、工具调用、失败结果和最终回复追加进 `log.txt`;exit 出现后先读到末尾再结束该步,日志已含最终回复(`replied`)时不再追加 `reply.txt`。两类步骤的进度都靠读文件推进,因此插件重载后能接管。历史在 `runs.json`(先写 `.bak` 再写主文件)。
- 步骤编排与费用:shell 步骤拿 `ROOST_OUTPUT=runs/<id>/s<i>.out`,wrapper 结束时删掉非普通文件,host 在 `step_done` 读入 `run.outputs`(`take_outputs`:≤64 KiB、≤64 键、值 ≤4 KiB),之后的步骤用 `{{out.x}}` / `ROOST_OUT_X`;`stop=<原因>` 让运行以 `skipped` 结束(`core` 不为 skipped 弹 toast)。`start_step` 先过 `held`:`when`(`model.When`,out/input,可取反)为假则跳过该步,omp 步骤遇到工作流 `daily_budget` 用尽(`stats.cost_since` 按本机日)则以 skipped 结束运行。agent 步骤 exit 后、`step_done` 前跑 `tally_agent`(`runner.TALLY`:find + `grep -oH` + awk 汇总会话目录全部 JSONL 的 `"cost":{…"total"}` 与 `totalTokens`,并列出 `"api":…,"provider":…,"model":…` 的去重用法:子目录里的 JSONL 是子代理(文件名即名字),前面紧跟 `"role":"…"` 的是 `model_usage` 旁路调用;JSON 字符串里的引号已转义所以不会误计),写 StepRec `cost`/`tokens`/`models`(`store.ModelUse`,≤32 条,`runner.parse_tally` 解析)。agent 运行中 `peek_agent` 每 20 s 用同一脚本刷新 `models`;创建运行时 omp 步骤记下 `model` 设置(nil = omp 默认角色);UI 打开已结束运行时 `core.fill_models` 为没有 `models` 的旧步骤补读一次(每个运行每 VM 一次)。运行详情的「模型」行按模型聚合,没有会话记录的进行中步骤用 `core.omp_models` 的角色表换算设置;`fleet` 摘要带 `model`/`models`。
- GitHub 身份:`[github] identity`(默认 `app`)/ 工作流 `identity`。有仓库的 App 运行在最前插入 `auth` 步骤(`runner.start_auth`):经 `core.app_token` 调 `POST /api/v1/github/token`,令牌经 stdin 写入 `runs/<id>/app-token`(umask 077),同时装 `<data>/bin/gh` 包装(`runner.GH_SHIM`,每次读当前令牌);`run.app` 记 bot 与到期时间,`M.tick` 内 `renew` 在到期前 15 分钟续期;`finish` 删令牌。用户步骤(非 prepare/cleanup)拿 `app_vars`:`GIT_CONFIG_*`(github.com 凭据助手清空后换成读令牌文件、ssh→https)、bot 作者;shell 步骤另有 `GH_TOKEN` 与 PATH 前置;omp 步骤经 `agent.with_env` 用 `/bin/sh` source `s<i>.env`(文件里不写令牌,但它会从令牌文件导出 `GH_TOKEN`,所以 agent 同样拿得到)后 exec omp。`match` 的 ignore_self 也忽略 `ctx.bot`。
- 保留与清理:`roost.toml [retention]`(`runs`/`run_age`/`events`/`event_age`;`runs` 只计已结束的运行)。`core.housekeep` 在启动、每小时、策略首次生效或变化后与手动时执行;拿到有效 roost.toml 之前(`store.policy` 为 false)不按策略删除任何东西(事件页只按 2000 条硬上限裁剪)。`store.prune` 只丢弃已结束的运行(索引立即更新,`runs/<id>` 与 `worktrees/<id>` 进 `store.trash`),`store.sweep` 把无主目录也放进 trash(runs.json 读不出或 `runs.json.unreadable` 存在时停用);`store.drain` 每批 8 个路径用一次 `/bin/rm -rf --` 在进程外删除(不占调用预算、不跟随符号链接,只接受绝对数据目录下的 `runs/<名>`、`worktrees/<名>`),仍存在的路径最多重试 3 次。事件页历史在 `events.json`(`lib/eventlog.luau`,同样先写 `.bak`);去重集 `seen`(2000)在启动时由 runs.json 的 `trigger.delivery` 与 events.json 回填;首次连接中继或还没有 `events.json` 时,`relay` 拉取游标之前(含游标)的最近 20 条作为 `history` 行,只展示不运行,并按 `trigger.delivery` 关联已有运行。手动操作(删除运行、清空事件、清空中继缓存/统计、忘记 App 凭据)在 UI 中都要两次独立点击(间隔 0.8–5 s,`st.confirm`/`confirm_at`),按键和选择会取消。
- 订阅同步:`model.subscriptions(workflows)`(仓库筛选为空 → `"*"`)→ `PUT /api/v1/subscriptions`(`base_revision` 乐观并发,上次版本存 kv `subs`);失败时 UI 给出 `model.subscriptions_toml` 手动回退。
- 工作流文件与导出:脚本/提示词由插件管理,不写在 workflows.toml 里。布局(`lib/files.luau` 头部注释):`workflows/<id>/files/` 工作流私有文件(编辑器里编辑,随 `core.save_workflow(.., wfiles)` 先于 workflows.toml 写入;改 id 时跟随,删工作流时进 `store.trash`)、`library/<库>/` 共享文件库(工作流用 `libs` 声明或 `file = "@库/路径"` 引用;`core.delete_library` 在仍被使用时拒绝)、`state/<组>/` 跨运行状态(`$ROOST_STATE`,工作流 `state` 键,默认为工作流 id,**永不自动删除**,界面「自动化 › 文件库」可手动删)。步骤种类 `file`:`file = "<路径>"` 或 `"@库/路径"` + `args`,按扩展名选解释器(`model.INTERPRETERS`:py→python3、sh、bash、js/mjs/cjs→node),路径各段以字母数字或 `_` 开头(`model.valid_file_path`,挡掉隐藏文件与 `..`)。`runner.pump` 在运行开始时 `files.stage` 把工作流文件与用到的库复制进 `runs/<id>/files`、`runs/<id>/lib/<库>`(运行中改文件不影响在跑的运行;缺库则以 failed 结束),步骤拿 `ROOST_FILES/ROOST_LIB/ROOST_STATE/ROOST_TMP`,`PYTHONPYCACHEPREFIX` 指向 `runs/<id>/tmp/pycache`;`finish` 把 `runs/<id>/tmp` 交给 `store.discard`(`owned` 只放行 `runs|worktrees|workflows|library|state|exports/<名>` 与 `runs/<id>/tmp`),副本随运行目录按 `[retention]` 清理。单文件 ≤512 KiB、≤200 个、总计 ≤4 MiB,列目录跳过隐藏名与 `__pycache__`。导出(`lib/bundle.luau`):`core.export_workflows` 把所选工作流、其私有文件、用到的库、仓库的 branch/worktree(不含本机路径)写成 `exports/<时间>-<名>.roost.toml`(`[roost] format=1` + `[[workflow]]` + `[[file]]`),只留最新 50 个(`housekeep`);`core.import_workflows` 先全部校验再写文件库/私有文件,最后写 workflows.toml(带 .bak),导入的工作流一律停用,已存在的工作流与内容不同的库只在 overwrite 时替换。`scripts/migrate-fluxdown.py` 是把旧 `scripts/` 目录与 `fluxdown-issues/` 状态迁进文件库 `fluxdown` 的一次性脚本。
- 标签页步骤(`lib/tabs.luau` 协议,`lib/launcher.luau` 执行):`start_tab` 写 `tabs/ops/<run>-s<i>.json` 并发布 kv `tab_ops`(运行结束时为 `keep` 关闭的已开标签页再排 `<run>-end<i>` 关闭操作,`only_run` 防止关掉后来运行接管的同键标签页);只有显示本机的窗口认领(`mkdir .claim`)并写 `.done`,`watch_tab` 读结果、记日志再写 `s<i>.exit`,120 s 无窗口认领则失败。窗口把打开的标签页登记在 `tabs/open/<wf>.<key>.json`(pane + 块类型,上限 200),关闭前核对 pane 仍在且类型不变,`pane_closed` 与窗口首次 tick 清理失效登记;键按工作流划分。
- 工作流自迭代(`lib/evolve.luau`):`evolve` 工作流的运行在用户步骤前插入 `evolve` 步骤(`core` 的 `evolve_prepare` 同步写 `runs/<id>/evolve/{README.md,digest.*,scope.json,context/,base/,edit/}`,日志末尾由 `runner.EVOLVE_LOGS` 复制;`context/` 是只读背景:`evolve.redact` 过的 roost.toml(键名含 token/secret/password/key/auth/env 的值与 `*env*` 节整体隐藏,注释行与多行值同样处理,URL 里的凭据打码)、`repos.md`、最近 10 份成功迭代运行的 `suggestions.md`)。运行结束经 `env.finished` → `core.on_finished`(`tern.timer(0)` 延后,避开 runner 自身的调用):成功的迭代者 `evolve.apply`(edit≠base 且磁盘仍等于 base 才应用,走 `core.save_workflow`/`save_library_tree`,快照 `revisions/<n>/before|after`,应用后再 `check` 一遍,失败则撤销),再 `evolve.report`(`evolve/suggestions.md` 读 ≤256 KiB、截到 8000 字 → 运行日志 + 通知);`evolve.observe` 计入观察中的修订(≥2 次失败且失败率高于基线 0.25 → `rollback`,磁盘已不等于 after 则不回滚);`evolve.fire` 按 `roost` 触发器启动迭代者:`run_failed`(失败/超时,`streak`)与 `run_succeeded`(成功运行的抽查,`sample` 百分比按运行 id 哈希固定取样,迭代者有运行在跑或排队时不触发,免得留下 skipped 记录),各自 30 分钟冷却与每日上限(触发器的 `daily`,默认与最大 `model.ROOST_DAILY` = 20;计数在账本 `day[<迭代者>]` 与 `day[<迭代者>/check]`,抽查的冷却键也带 `/check` 后缀,不挡失败修复)(`Request.evolve` → `run.evolve_target/evolve_run`,模板变量 `evolve_dir/evolve_target/evolve_run`,另有通用的 `tmp` = `runs/<id>/tmp`)。账本 `revisions.json`(先写 .bak),修订最多 100 个。界面调试(启动被测程序、截图、Windows 调试机)不在插件代码里:由本机文件库 `uidebug`(`plugin-data/roost/library/uidebug/uidebug.py`)负责锁、登记与 begin/end/sweep 清理,FluxDown 工作流经 `libs` 引用、提示词 `{{UI_DEBUG}}` 由 issues.py 换成 `fluxdown/ui-debug.md`。
- Roost 自升级(`lib/upgrade.luau`):`upgrade` 步骤以 shell 步骤运行 `upgrade.CHECK`(`tern` 在 PATH、worktree HEAD 须是插件目录 HEAD 的后续、插件目录干净且在分支上(`git --no-optional-locks status`,不碰插件的 .git/index)、在新 worktree 里用**插件当前版本**的 `scripts/check.sh` 检查提交),再 `set -m; nohup` 启动该运行专属的 `upgrade/<run>.apply.sh`(`upgrade.APPLY`,host 在步骤开始时写入,结束自删):fetch 临时分支 → `merge --ff-only` → `tern plugin reload roost` → 等 `boot.txt` 变化(`core.booted`,host.luau 最后一行写入)→ 否则 `reset --keep` 回旧提交;结果 `upgrades/<run>.json`,`core.watch_upgrades`(启动时与 upgrade 步骤成功后,每 3 s 看一次,最多 5 分钟)用 kv `upgrade_seen` 只报一次最终结果。这是唯一写插件目录的路径。tab 登记在 Tern daemon 换了(kv `daemon` = 父进程 pid + 启动时间)时整体清空,避免 pane id 复用后误关。
- 工作流分组(`lib/groups.luau`):只影响「自动化 › 工作流」的展示,存 `groups.json`(`{groups:[{id="g<n>",name,collapsed}], of:{<工作流 id>=<组 id>}}`,先写 `.bak` 再写主文件,读取回退 `.bak`),不进 workflows.toml、evolve 看不到。导出按名字带分组:`core.export_workflows` 按页面顺序(分组顺序 → 组内 toml 顺序 → 未分组)写工作流,并写 `[[group]] name, workflows`(只含本次导出的工作流;导出全部时空分组也写);`bundle.decode` 拒绝同一工作流进多个组、引用文件外的工作流、重名;导入用 `groups.merge`:同名分组合并、没有就新建(空分组也建),只给本次导入的工作流归组,且本机已在分组里的不动。`core.group_*` 都经 `edit_groups`(改副本、写成功才替换 `c.groups`);文件存在但两份都解析不了时 `c.groups_err` 置位,一切修改拒绝、绝不覆盖。`core.save_workflow` 改 id 时分组跟随、`delete_workflow` 时移除(`regroup`)。界面:没有分组时是单一卡片网格(卡片 `end` = `main.body.workflows.cards.<id>.end`),有分组时每组 `g_<组id>` / `ungrouped` 一个 col(`end` 多一层),卡片「分组」菜单(`mv:<wf>:<组id>`,空为未分组;`grp-new-for:<wf>`)、组标题的收起/上移/下移/重命名/删除(`grp-*`)、`[`/`]` 键;j/k 按页面顺序(跳过收起的组)。Tern 没有节点拖拽事件。
- 两个 block(`lib/ui.luau` 顶部 `PAGES`):`roost.console` 工作台三页「首页 / 自动化 / 活动」,`roost.settings` 设置四页「通用 / 中继与设备 / GitHub App / 存储与清理」;二者共用 host 里同一个 core 与同一套 `do_action`,`st.kind` 区分。`st.tab` 是视图 id(overview、workflows、files、runs、events、config、relay、github、storage),页签显示它所属的页;一页多个视图时在工具栏左侧放分段切换(节点 key `sub`,`bar_start`),`st.last` 记每页上次的视图(随 `save` 保存)。工作台跳设置用动作 `settings=<视图>`:host 先把已打开的设置 block(`settings_open`)切到该视图,再 `cx:open("roost://settings/<视图>")`,window 聚焦已有设置标签页或 `new_block("roost.settings", {视图}, "tab")`;设置回工作台是 `roost://console`。首页「待处理」(`attention`)只用 core 已有的状态(配置错误、中继/设备、订阅、淘汰、App 权限、各工作流最近一次失败),条目 key `set_<视图>` / `run_<运行 id>` 决定去向。
- bot 工作台:**内置运行**(`lib/tasks.luau`,`store.Task`,工作流 id `task.<hex>`):`runner.resolve` 对 `run.task` 用 `tasks.workflow` 重建,不进 workflows.toml;`core.followup`(追问)/`open_pr`(kind `pr`,`tasks.PR_SCRIPT`)/`make_branch`(`tasks.BRANCH_SCRIPT`,临时 worktree,不动检出)。**改动**:`PREPARE_WORKTREE` 写 `base.txt`(追问:`ROOST_BASE_SHA` 起点 + `ROOST_BASE_PATCH` 补丁),`CLEANUP_WORKTREE` 删前 `git add -A` + diff 出 `changes.patch`/`changes.numstat`(>8 MiB 只留 numstat、`changes.too_big`),`read_changes` 写 `run.changes`。**追问**:内部步骤 `resume`(`RESUME_SESSION` 复制父会话目录与补丁,写 `s<j>.resume`:文件名、大小、已有费用),首个 omp 步骤加 `--resume <副本>`,StepRec `cost_base/tokens_base` 在 `tally_agent` 扣除,`tail` 从副本大小开始;最终回复由 host 从会话写 `s<i>.answer.md`(`core.answer`)。**收件箱**(`lib/inbox.luau`):shell/file 步骤的 `$ROOST_INBOX`(wrapper 删非普通文件),`step_done` 读 ≤64 KiB → `core.inbox_report` → `inbox.json`(.bak);`fleet.summaries` 带 `inbox` 给其他设备,`core.inbox_items` 对每个工作流取负责它的设备上报的那份。**提及/回复**(`match.handles/request`,`lib/reply.luau`):`reply = true` 时插入内部步骤 `ack`(前缀)与 `report`(像 cleanup 一样在失败/取消后仍跑,`next_step`/`check` 不杀)。**API 触发**:`api = "<sha256>"`,`model.dispatch` → `relay` 推订阅带 `dispatch`(参与 fingerprint),中继公开 `POST /hooks/dispatch/{id}` → `roost_dispatch` 事件 → `core.dispatch_event`。**环境**:roost.toml `[environments.<名>]`,内部步骤 `env`(`ENV_SCRIPT` 写 0600 `environment.sh` 并跑 setup),`step_env` 叠加 vars/path,omp 步骤经 `s<i>.env` source,`finish` 删除。内部步骤前缀顺序:auth → resume → prepare → evolve → env → ack(`definition` 跳过),末尾 report → cleanup。
- 多设备(`lib/fleet.luau` 纯函数、`relay.luau` 协议、`core.luau` 末尾「Devices」节;中继 `agent/src/fleet.rs`):中继 `<data>/fleet.json` 的 `owners` 记分配历史:`"*"` 是默认设备,其余键是工作流 id;每条 `{client|null, name, seq, at}` 的 `seq` 是指派时事件存储的 head,事件 `seq` 大于它才归这一条(`fleet.owner(f, wf, seq)`:工作流自己的条目为 client 就是它,否则看默认设备那一时刻的条目,都没有 = 每台设备都跑)。`PUT /fleet/executor`(默认设备)与 `PUT /fleet/assign`(工作流)都按 `revision` 比较后写入,只接受中继见过或记录里有的 client;历史按最老的存储事件裁剪(每键 ≤8 条、≤512 个工作流),store_id 变了只留当前条目;旧格式的 `executor` 迁成 `owners["*"]`,`executor` 字段保留为当前默认设备。每台设备都长轮询全部事件:`core.on_events` 对每个命中的工作流按事件 seq 判归属,别人的只在事件行写「由「X」运行」;`cron_tick` 只在当前负责的设备提交(各设备都记为已触发);`fleet.json` 读不出(`error`)时谁都不运行、不读新事件、不改配置(`run_block`/`config_block`),中继对 token/订阅/配置写入/转发返回 503 `fleet_broken`,直到重新指定默认设备。手动运行:`core.dispatch`/`dispatch_pr` 对别的设备负责的工作流走 `relay.post_run` → 中继 `POST /fleet/run` 存 `roost_run` 事件(`sender = "device"`、payload 带 `target`/`from`),目标设备 `run_forwarded` 在本机运行(`run_here` 带 delivery 去重);内置运行与迭代者都在本机。共用配置:中继 `PUT /fleet/config {text, base}` 按版本 CAS(与现有正文相同总是接受,否则 409 `config_conflict`);`dev_loop` 每 5 s `sync_config`:`build_text`(`make_bundle` 全部工作流+全部仓库+空分组,`exported_at = 0`、env 清空;`cfg_dirty` 或 30 s 重建),中继版本 ≠ kv `sync.revision` → `fetch_shared`(先 `reload_files` 重建本机文本,与中继正文相同只记同步;本机文本 ≠ `sync-base.roost.toml`(内存缓存 `base_text`)即有未同步修改 → `apply_shared` 前 `backup_before_sync` 另存 `workflows.toml.before-sync-<时间>`(留 10 份)并导出;`fleet.mirror_text` 只写共用配置里的仓库,保留本机 `path` 与 env 值;删配置里没有的工作流文件;分组按名字保留折叠),否则本机文本变了 → `upload_shared(text, base = 中继版本)`;失败的版本 60 s 后再试。订阅:各设备由同一配置算出同样订阅,中继对与现有相同的订阅不看 base 直接接受;`relay` 的 `behind`(本机配置落后,或还不知道中继记录)时不自动推送(`hold` → 状态 behind,从没连上则 offline),`note_fleet` 收到记录后恢复。运行:每台设备 `fleet.summaries`(最近 100 条,最新 20 条带 `tail -c` 读的日志尾 4 KiB,超 480 KiB 先丢尾巴再减条数)`PUT /fleet/runs`,中继按设备存 `fleet-runs-<hex>.json`(最多 16 台);`fetch_runs` 按 `fleet.uploads` 的版本 `GET /fleet/runs/{client}`,`core.remote_runs` 合并(`Run.device`),UI「运行」页与本机运行合并显示、其他设备的只读。
- host → window 只经 kv:`status`(window 每 2 s 读取,刷新状态栏)、`agent_jobs` 与 `tab_ops`(window 每 1 s 读取);window → host 只经运行目录与 `tabs/` 里的文件。host block 通过 `cx:open("roost://…")` 让 window 的 `tern.route.link` 打开会话侧栏或会话。window 同时把 plugin-data 下的 `theme.css` 经 `tern.css` 注入。
- `agent/`:axum 服务,以 GitHub App 运行(`github.rs`:manifest 注册(`APP_PERMISSIONS`,含 administration)、RS256 JWT、中继自用安装令牌、凭据 `<data>/github-app.json`);`POST /api/v1/github/token` 为单次运行签发只限一个仓库、去掉 administration 的令牌,签发前 `guard` 确认默认分支禁止强推与删除(没有就建规则集 `GUARD_NAME`,建不了则 409 拒绝,结果缓存 10 分钟);`/hooks/github` 用 App 密钥验签 → 按 `subscriptions.toml` 过滤 → `store.rs` 持久化事件(按数量/时间/字节上限淘汰,`DELETE /api/v1/events` 手动清空且不回退序号);每次投递按 (outcome, event, repo) 计数(内存,256 组上限,未验签的 rejected 合为一组),`GET|DELETE /api/v1/deliveries` 查看/清空;`/api/v1/*` Bearer 鉴权;`restart` 优雅关闭后 `exec` 自身。

平台层面已有的约束:

- 插件分两半,至少要有一个入口:
  - `host.luau`:跑在会话 daemon worker 里;负责 `tern.block.define` / `tern.lens.define`、`tern.pane.*`、`tern.on(spawn|command_*|cwd|title|pane_exited)`。每次调用预算 **2 s**。
  - `window.luau`:跑在每个窗口的 UI 线程里;负责 `tern.command`、`tern.bind`、`tern.override`、`tern.route.*`、`tern.chrome.*`、`tern.css`、`tern.secrets`,以及 `cx.layout/session/...`。每次调用预算 **50 ms**(chrome/`available` 为 **4 ms**)。
- 两半之间**没有 RPC**,共享状态只能通过 `tern.kv`(按插件划分作用域)以及 `tern.plugin.data` 下的文件来传递。现有惯例是 host 写 kv,window 用 timer 轮询后调用 `tern.chrome.refresh()`。
- Block 生命周期:`init(cx, args, saved) → state`,然后 `view(state, cx) → {main, dock?, layer?}`;另有 `key`、`event`、`resize`、`save`。渲染是**手动的**:修改 state 后调用 `cx:render()`。`view` 的根节点必须是容器(`col`/`row`)。
- 重载时 host worker 会被回收,block 通过 `save` 拿到的数据在 `init(..., saved)` 里恢复;window VM 会整体重建。`tern.kv` 和 `plugin-data/` 在重载、重装、移除之后都会保留。

**与"自升级/自迭代"目标直接相关的平台事实:**

- Tern **没有插件更新机制**:没有 registry,也没有 `tern plugin update`;`version` 字段只用于显示,Tern 从不比较版本。更新的方式只有 `tern plugin install SRC --force`(只能替换 copy 安装,不能替换 link 安装),或者在 link 的 checkout 里执行 `git pull`。
- Tern 监听插件目录(FSEvents,约 300 ms 合批),**插件目录下任何文件变化都会重载该上下文中的全部插件**。所以运行时产物、缓存、构建输出一律写到 `tern.plugin.data`,不能写进插件目录(`office预览/scripts/build.sh` 把 `CARGO_TARGET_DIR` 指到 data 目录,就是为了这个)。
- 版本新鲜度由插件自己负责,可参考 `office预览/lib/native.luau`:`bin/VERSION` 与 data 目录下的 `.version` 戳做比对,不一致就重建。
- 沙箱里没有 `io`/`os.execute`,对外只能走 `tern.*`(`tern.process.run`、`tern.fetch`、`tern.fs.*`)。插件**没有权限系统**,以当前用户身份运行,沙箱也**不是**安全边界。

## Key Directories

```text
plugin.toml          # id = "roost",block console + settings
host.luau            # 运行时 + roost.console / roost.settings 两个 block
window.luau          # 命令(打开工作台、设置)、状态栏、theme.css 注入、agent 启动器、roost:// 路由
roost.css            # 主题钩子(data-role = roost.*)
lib/core.luau        # 运行时编排与给视图的动作 API
lib/runner.luau      # 运行引擎(高风险:状态机/进程/持久化,主会话维护)
lib/agent.luau       # omp agent 步骤的 host↔window 文件协议(主会话维护)
lib/launcher.luau    # window 侧:认领/打开/结束 agent 步骤,roost://session 链接(主会话维护)
lib/relay.luau       # 中继客户端(wire 协议,主会话维护)
lib/model.luau      # 两个配置文件的解析与校验、订阅计算
lib/store.luau       # runs.json 历史、保留策略与分批删除(高风险:持久化,主会话维护)
lib/files.luau       # 工作流私有文件/文件库/状态目录的读写、校验与运行副本(高风险:删除与持久化,主会话维护)
lib/bundle.luau      # 导出文件格式(.roost.toml)的编码与解码
lib/eventlog.luau    # events.json:事件页历史(高风险:持久化,主会话维护)
lib/loginenv.luau    # 登录 shell(fish 等)环境的读取与合成:shell 步骤和 gh/omp 调用的环境底座(只放内存)
lib/tabs.luau        # tab 步骤的 host↔window 文件协议与标签页登记(主会话维护)
lib/groups.luau      # 「自动化 › 工作流」的分组(groups.json):纯函数 + 读写
lib/fleet.luau       # 多设备:按工作流/事件 seq 判归属、运行摘要编解码、共用配置落到本机的 workflows.toml(纯函数)
lib/tasks.luau       # 内置运行(任务/追问/开 PR)的合成工作流、改动 numstat 解析、建分支与开 PR 脚本
lib/inbox.luau       # 收件箱:$ROOST_INBOX 协议解析、按工作流归档、忽略、inbox.json 读写
lib/reply.luau       # 「在评论中回复」的 ack/report 脚本与回复正文
lib/evolve.luau      # 工作流自迭代:材料、应用、修订快照、观察与回滚、触发(高风险:持久化与改写用户文件,主会话维护)
lib/upgrade.luau     # Roost 自升级:检查与进程外应用脚本、boot 标记、结果(高风险:写插件目录,主会话维护)
lib/match.luau lib/template.luau lib/cron.luau lib/toml.luau lib/util.luau lib/stats.luau   # 纯函数(stats:概览的按日统计与工作流健康度)
lib/ui.luau lib/editor.luau lib/field.luau  # 两个 block 的视图(工作台、设置)、自动化编辑器与文本输入
tests/               # run.py + fake_tern.luau + harness.luau + test_*.luau
agent/               # roost-agent(Rust):src/{api,store,fleet,github,event,config,secret}.rs,deploy/
```

仓库内已有的开发配置(不涉及插件架构):

| 路径 | 作用 |
|---|---|
| `.omp/config.yml` | omp 项目配置:yolo、TTSR(after-gap/8)、关闭用户级记忆和 autolearn |
| `.omp/RULES.md` | 常驻硬规则:记忆协议 + Luau/Rust 运行时红线 |
| `.omp/rules/*.md` | TTSR 规则:`luau-sandbox`、`luau-budget`、`rust-no-panic`、`rust-memory-bounds`、`memory-no-secrets` |
| `.omp/commands/*.md` | `/remember`、`/memory-tidy` |
| `.omp/lsp.json` | omp LSP:`luau-lsp` 加载 `tern.d.luau`;rust-analyzer 用 clippy 检查,构建目录放在仓库外 |
| `.luaurc` | Luau strict 模式,lint/类型错误一律按错误处理 |
| `.cargo/config.toml` | 任何 crate 都生效:clippy 的 deny 规则(防 panic、防内存失控),`target-dir=/tmp/roost-cargo-target` |
| `clippy.toml` | 测试代码豁免 unwrap/expect/panic/下标;栈上大数组、大 future 的阈值 16 KiB |
| `scripts/check.sh` | 统一检查入口;Rust 检查在 `/tmp/roost-rust` 镜像中执行(本机 cargo 忽略 target-dir) |

运行时路径(macOS):

| 用途 | 路径 |
|---|---|
| 插件目录 | `tern plugin dir` → `~/Library/Application Support/Tern/plugins/`(link 安装会生成 `<id>.path` 指针文件) |
| 可写数据 | `tern.plugin.data` → `~/Library/Application Support/Tern/plugin-data/<id>/`(含 `kv.json`) |
| 启用/禁用 | `~/Library/Application Support/Tern/settings.json` 中的 `"plugins"` 与 `"plugins_disabled": [id]` |

## Development Commands

```sh
tern plugin link .            # 原地开发,改动后自动重载
tern plugin reload [ID]       # 手动重载;插件失败时 exit 1
tern plugin list [--json]     # 查看加载状态与 problems
tern plugin types .           # 生成 ./tern.d.luau(与当前 Tern 版本匹配)
tern plugin unlink <id>
tern plugin install <dir|github.com/OWNER/REPO[/PATH]|git-url> [--force]
tern plugin remove <id>       # 保留 plugin-data/

# 统一检查:Luau(luau-lsp strict + tests/run.py)、Rust(fmt/clippy/test)、项目记忆预算
scripts/check.sh

# 调试日志
STENCIL_LOG=warn,stencil=info,tern::plugin=debug
```

本机已有:`tern`(0.9.12,`~/.local/bin/tern`)、`luau`/`luau-analyze`(`/opt/homebrew/bin`)、`luau-lsp` 1.70.1(`~/.local/bin`,从 GitHub release 安装,brew 没有)、`python3`、`cargo`/clippy/rust-analyzer。没有:`lune`、`selene`、`stylua`。`luau-analyze` 无法加载 `tern.d.luau`,类型检查只能用 `luau-lsp`。

## Code Conventions & Common Patterns

兄弟插件的惯例,Roost 可以沿用,不强制:

- Luau 文件开头写 `--!strict`;`lib/*.luau` 返回模块表 `M`;纯函数和 I/O 模块分开,方便测试。
- 有副作用的调用用 `pcall` 包住:`tern.fs.*`、`tern.kv.*`、`tern.json.decode`、`tern.process.run`。进程结果检查 `status` / `timed_out` / `stderr`;fetch 结果检查 `error` / `timed_out` / `status`。
- 异步回调防竞态:用 `state.gen` 计数器丢弃过期回调;在 `tern.pane.list()` 里已找不到对应 pane 时停掉 timer(`timer:cancel()`)。
- 命名规则:block kind 为 `<plugin-id>.<block-id>`;surface 为 `plugin.<id>.<block>`;命令 action 为 `plugin.<id>.<cmd-id>`。manifest 里的 `id` 必须满足 `^[a-z][a-z0-9-]{0,31}$`。
- 点击事件:`p.actions = { click = "act=value" }`,在 `event` 中收到的是 `ev.ev == "action"` 加上 `ev.act` / `ev.value`。列表/标签页触发的是 `ev.ev == "select" | "activate"`。
- 样式:**不允许内联 style**。CSS 是子集,所有 styles 合计不超过 256 KiB。用 `[data-surface='plugin.<id>.<block>']` 限定作用域;主题变量用 `--accent --t1..--t4 --l1..--l4 --ok --warn --bad --card --raise --live`;节点的 `p.role` 会映射为 `[data-role=…]`。
- 图片走 `cx:blob(bytes, mime)` 再交给 `ui.node("image", {blob=…})`;`assets/` 目录只放 README 截图与 GitHub App 头像(`app-logo.svg` 源文件 → `rsvg-convert -w 512` 生成 `app-logo.png`)。
- 没有 i18n API,UI 文案直接硬编码。README 采用 `README.md`(英文)+ `README.zh-CN.md` 双份。
- `plugin.toml` 出现未知字段会直接报错;声明的每个 `[[blocks]]` / `[[lenses]]` 都必须在 host 里 define。

## Important Files

| 文件 | 说明 |
|---|---|
| `plugin.toml` | 待建。字段:`schema id name version description icon host window styles [[blocks]] [[lenses]]` |
| `tern.d.luau` | 由 `tern plugin types .` 生成,已加入 gitignore,运行时会忽略它。`scripts/check.sh` 在内容变化时自动刷新;luau-lsp 与 omp LSP 都依赖它 |
| SDK 文档 | https://docs.stencil.so/tern/ (每页加 `.md` 可取 Markdown 版;重点看 `reference/{manifest,api-host,api-window,ui,events,cli,limits}.md`) |
| SDK 仓库 | https://github.com/stencil-hq/tern-sdk(`plugins/tern.d.luau`、`plugins/examples/*`) |

文档与运行时不一致时,**以运行时为准**。API 没有版本号,新成员要先做特性检测(`if tern.x then … end`)。

## Runtime/Tooling Preferences

- 语言:Luau(Tern 内置 VM,每个 VM 内存上限 256 MiB)。不需要包管理器,也不能引入外部 Luau 依赖。
- 需要原生能力时,参考 `office预览` 的 sidecar 模式:Rust 二进制构建到 `plugin-data/<id>/bin`,通过 `tern.process.run` 调用。
- 构建输出不得落在插件目录内,否则会触发重载风暴。本机 cargo(huacnlee/cargo 分支)忽略 `.cargo/config.toml` 的 `target-dir`、总写 `./target`,所以 Rust 构建一律在仓库外的镜像里做(`scripts/check.sh` 用 `/tmp/roost-rust`);不要设置 `RUSTFLAGS`,否则会覆盖其中的 clippy 规则。
- link 开发期间,`.omp/memory/` 或其他仓库文件的写入同样会触发 Tern 重载全部插件。这是预期行为,不要为了避开它把记忆移出仓库。
- omp 在本项目使用 yolo 模式(`.omp/config.yml`)。TTSR 违规时丢弃已流出的输出后重试;同一规则隔 8 轮后可再次触发。`luau-budget`、`rust-*` 是事后提醒(`interruptMode: never`),`luau-sandbox`、`memory-no-secrets` 会直接打断。
- 全局配置禁用了 `typesafe` 这个 provider,所以 `question` 类(由模型判定的)TTSR 规则不会生效;新规则只用 `condition`/`astCondition`,并先用 `omp ttsr test --rule .omp/rules/<名>.md --source tool --path <文件> '<片段>'` 验证。

## Testing & QA

兄弟插件统一采用的方案,Roost 已沿用(测试里用 `require("./harness").fresh(env)` 代替裸 `__fresh`,以便 luau-lsp 能检查测试文件):

```sh
brew install luau
python3 tests/run.py                       # 跑全部 tests/test_*.luau
python3 tests/run.py tests/test_foo.luau   # 跑单个文件
```

- `tests/run.py` 把各模块打包成工厂函数,注入共享的 `tern` upvalue 后调用 `luau` CLI 执行。之所以这样做,是因为 CLI 沙箱没法注入全局变量。
- `tests/fake_tern.luau` 中的 `fake.new(opts)` 返回 `env`,包含 `env.tern`、内存文件系统 `env.files`、`env.process` / `env.fetch` 钩子、`env.drain()`、`env.advance(ms)`、`env.cx(pane)`,以及 `env.blocks` / `env.commands`。测试中先调用 `__fresh(env)`,再 `require("../host")`。
- 断言方式:没有引入测试框架,用本地 `eq` / `assert` + `error`;任一文件失败则以非零码退出。
- 不设覆盖率门槛。UI 改动以"测试通过 + `tern plugin reload` 无 problems"为交付标准,实际界面由用户目视确认。
- **交付门槛**:`scripts/check.sh` 退出码为 0。脚本会根据仓库中实际存在的文件自动启用对应检查:有 `*.luau` 就跑 luau-lsp(并按需刷新 `tern.d.luau`),有 `tests/run.py` 就跑 Luau 测试,每个 `Cargo.toml` 都跑 `fmt --check`、`clippy -D warnings`、`test`,最后检查项目记忆。
