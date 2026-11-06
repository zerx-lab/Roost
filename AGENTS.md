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
- 步骤编排与费用:shell 步骤拿 `ROOST_OUTPUT=runs/<id>/s<i>.out`,wrapper 结束时删掉非普通文件,host 在 `step_done` 读入 `run.outputs`(`take_outputs`:≤64 KiB、≤64 键、值 ≤4 KiB),之后的步骤用 `{{out.x}}` / `ROOST_OUT_X`;`stop=<原因>` 让运行以 `skipped` 结束(`core` 不为 skipped 弹 toast)。`start_step` 先过 `held`:`when`(`model.When`,out/input,可取反)为假则跳过该步,omp 步骤遇到工作流 `daily_budget` 用尽(`stats.cost_since` 按本机日)则以 skipped 结束运行。agent 步骤 exit 后、`step_done` 前跑 `tally_agent`(`runner.TALLY`:find + grep + awk 汇总会话目录全部 JSONL 的 `"cost":{…"total"}` 与 `totalTokens`,JSON 字符串里的引号已转义所以不会误计),写 StepRec `cost`/`tokens`。
- GitHub 身份:`[github] identity`(默认 `app`)/ 工作流 `identity`。有仓库的 App 运行在最前插入 `auth` 步骤(`runner.start_auth`):经 `core.app_token` 调 `POST /api/v1/github/token`,令牌经 stdin 写入 `runs/<id>/app-token`(umask 077),同时装 `<data>/bin/gh` 包装(`runner.GH_SHIM`,每次读当前令牌);`run.app` 记 bot 与到期时间,`M.tick` 内 `renew` 在到期前 15 分钟续期;`finish` 删令牌。用户步骤(非 prepare/cleanup)拿 `app_vars`:`GIT_CONFIG_*`(github.com 凭据助手清空后换成读令牌文件、ssh→https)、bot 作者;shell 步骤另有 `GH_TOKEN` 与 PATH 前置;omp 步骤经 `agent.with_env` 用 `/bin/sh` source `s<i>.env`(无令牌)后 exec omp。`match` 的 ignore_self 也忽略 `ctx.bot`。
- 保留与清理:`roost.toml [retention]`(`runs`/`run_age`/`events`/`event_age`;`runs` 只计已结束的运行)。`core.housekeep` 在启动、每小时、策略首次生效或变化后与手动时执行;拿到有效 roost.toml 之前(`store.policy` 为 false)不按策略删除任何东西(事件页只按 2000 条硬上限裁剪)。`store.prune` 只丢弃已结束的运行(索引立即更新,`runs/<id>` 与 `worktrees/<id>` 进 `store.trash`),`store.sweep` 把无主目录也放进 trash(runs.json 读不出或 `runs.json.unreadable` 存在时停用);`store.drain` 每批 8 个路径用一次 `/bin/rm -rf --` 在进程外删除(不占调用预算、不跟随符号链接,只接受绝对数据目录下的 `runs/<名>`、`worktrees/<名>`),仍存在的路径最多重试 3 次。事件页历史在 `events.json`(`lib/eventlog.luau`,同样先写 `.bak`);去重集 `seen`(2000)在启动时由 runs.json 的 `trigger.delivery` 与 events.json 回填;首次连接中继或还没有 `events.json` 时,`relay` 拉取游标之前(含游标)的最近 20 条作为 `history` 行,只展示不运行,并按 `trigger.delivery` 关联已有运行。手动操作(删除运行、清空事件、清空中继缓存/统计、忘记 App 凭据)在 UI 中都要两次独立点击(间隔 0.8–5 s,`st.confirm`/`confirm_at`),按键和选择会取消。
- 订阅同步:`model.subscriptions(workflows)`(仓库筛选为空 → `"*"`)→ `PUT /api/v1/subscriptions`(`base_revision` 乐观并发,上次版本存 kv `subs`);失败时 UI 给出 `model.subscriptions_toml` 手动回退。
- host → window 只经 kv:`status`(window 每 2 s 读取,刷新状态栏)与 `agent_jobs`(window 每 1 s 读取);window → host 只经运行目录里的文件。host block 通过 `cx:open("roost://…")` 让 window 的 `tern.route.link` 打开会话侧栏或会话。window 同时把 plugin-data 下的 `theme.css` 经 `tern.css` 注入。
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
plugin.toml          # id = "roost",blocks console + sessions
host.luau            # 运行时 + roost.console / roost.sessions block
window.luau          # 命令、状态栏、theme.css 注入、agent 启动器、roost:// 路由
roost.css            # 主题钩子(data-role = roost.*)
lib/core.luau        # 运行时编排与给视图的动作 API
lib/runner.luau      # 运行引擎(高风险:状态机/进程/持久化,主会话维护)
lib/agent.luau       # omp agent 步骤的 host↔window 文件协议(主会话维护)
lib/launcher.luau    # window 侧:认领/打开/结束 agent 步骤,会话侧栏与 roost:// 链接(主会话维护)
lib/relay.luau       # 中继客户端(wire 协议,主会话维护)
lib/model.luau      # 两个配置文件的解析与校验、订阅计算
lib/store.luau       # runs.json 历史、保留策略与分批删除(高风险:持久化,主会话维护)
lib/eventlog.luau    # events.json:事件页历史(高风险:持久化,主会话维护)
lib/loginenv.luau    # 登录 shell(fish 等)环境的读取与合成:shell 步骤和 gh/omp 调用的环境底座(只放内存)
lib/match.luau lib/template.luau lib/cron.luau lib/toml.luau lib/util.luau lib/stats.luau   # 纯函数(stats:概览的按日统计与工作流健康度)
lib/ui.luau lib/editor.luau lib/sidebar.luau lib/field.luau  # 面板视图、自动化编辑器、会话侧栏与文本输入
tests/               # run.py + fake_tern.luau + harness.luau + test_*.luau
agent/               # roost-agent(Rust):src/{api,store,github,event,config,secret}.rs,deploy/
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
