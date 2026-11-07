# Roost

[English](README.md)

Roost 是一个 Tern 插件形式的本地自动化工作台:在**本机**按固定流程运行 omp。新建和编辑自动化的方式对标 grok.com/automations:在面板里点「新建自动化」或从模板开始,用表单选触发器、写指令,保存即生效。触发方式有两种:

- **主动**:定时,包括一次、每小时、每天、每周、每月、每年和自定义 cron,由插件在本机调度,无需服务器;也可以在面板上手动运行,可带输入参数。
- **被动**:GitHub 事件,如 PR 打开/推送/合并、评论、审查、标签、分支推送、CI 完成等。GitHub 无法直接访问本机,所以服务器上放一个小型**中继** `roost-agent`(Rust)。它以 **GitHub App** 的身份接收所装仓库的 webhook,验签、按订阅过滤并缓存,本机插件长轮询拉取。

`roost-agent` 不运行任何工作流,也不是 AI 运行时;它只是事件中继节点。

```mermaid
flowchart LR
  GH[GitHub App 所装仓库] -- webhook + HMAC --> A[roost-agent<br/>服务器]
  P[Roost 插件<br/>本机 Tern] -- 长轮询 /api/v1/events --> A
  P -- 推送订阅 / 仓库与人员建议 --> A
  A -- 安装令牌(中继自用 / 每次运行一个) --> GH
  P -- 定时 / 手动 / 事件 --> R[omp 与 shell 步骤<br/>git worktree]
```

## 安装插件

```sh
tern plugin install github.com/<owner>/<repo>    # 或开发时:tern plugin link .
```

命令面板运行 **Roost:打开工作台**(设置是单独的 **Roost:设置**)。首次启动会在 `tern.plugin.data`(macOS:`~/Library/Application Support/Tern/plugin-data/roost/`)生成两个配置文件,保存即生效;运行产生的数据也放在这里:

| 文件 | 作用 |
|---|---|
| `roost.toml` | 本机绑定:中继地址与令牌、runner 设置(omp 参数、agent 会话名、并发、超时、PATH)、`[retention]` 保留策略、`[github] login`(可选,你的 GitHub 用户名) |
| `workflows.toml` | 仓库(GitHub 名 → 本机路径)、自动化、触发器、步骤;面板的表单编辑器读写的就是它 |
| `runs.json`、`runs/<run>/`、`worktrees/<run>/` | 运行历史;每个运行的日志、事件负载与 omp 会话;事件运行的临时 worktree |
| `events.json` | 「事件」页:收到的每个中继事件,以及它启动的运行或没有触发的原因 |
| `groups.json` | 「自动化」页的分组:名称、顺序、是否收起,以及每个工作流在哪个分组(只影响展示)。导出时按名字带上分组:单独导出只带该工作流所在的分组;导出全部按页面上的分组顺序排列工作流,并带上全部分组(包括空分组)。导入时同名分组合并、没有就新建;本机已经在某个分组里的工作流保持原分组 |
| `theme.css`(可选) | 自定义样式,实时注入,见「外观定制」 |

### 在面板中新建自动化

「自动化」页每个工作流一张卡片,可以按分组归类(见下方「面板」一节);卡片右上角的「编辑」打开表单。「新建自动化」会打开一个表单,也可以从旁边的「从模板」菜单开始(还没有工作流时,页面直接显示模板库)。表单内容:

- **名称与图标**。
- **触发器**:点「＋添加触发器」,菜单按「定时」和「GitHub」分组。
  - 定时触发器显示成一句话,例如「每周 ▾ 在 一 三 五 于 09:00」「每小时 ▾ 在 工作日 9:00–18:00 之间」。
  - GitHub 触发器显示成一张卡片,列出该种类支持的筛选器,空着表示「任意」。仓库、作者、负责人、标签、分支、工作流名称这几项会通过 GitHub App 给出建议。
  - 每个 GitHub 触发器至少要设一个筛选器。
- **指令**:即 omp 提示词,可以选模型;另外可以追加更多 omp 或 shell 步骤。模型下拉框来自本机 omp(`omp config get modelRoles` 与 `omp models --json`,PATH 含 `[runner] extra_path`,缓存 5 分钟):**Auto**(不传 `--model`,即 omp 的 `default` 角色)、角色 `@<角色>`(由 omp 按 `modelRoles` 解析,改了 omp 的角色配置就跟着变)、各 provider 的聊天模型 `provider/id`;`workflows.toml` 里手写的值(例如带 `:high` 思考后缀)照样保留可选。
- **通知**:运行结束时在 Tern 弹出通知。
- **高级**:id、并发、工作区、超时、时区、外部贡献者与 fork 的放行。

保存时整份文件用同一套校验规则检查。只有这一条自动化对应的 `[[workflow]]` 块会被替换,文件里的其他内容和注释保持不变,旧文件备份为 `workflows.toml.bak`。

### workflows.toml

```toml
[repos."acme/web"]
path = "~/code/web"     # 可选:本机检出;没声明的仓库在临时目录中运行
branch = "main"         # 定时/手动运行检出的分支
worktree = true         # 运行在临时 git worktree 中(默认);false 则直接用 path

[[workflow]]
id = "pr-review"
name = "PR 审查"
icon = "eye"
notify = true           # 运行结束时弹出通知(默认)
concurrency = "queue"   # queue | skip | replace
timeout = "20m"

[[workflow.trigger]]    # GitHub(经中继)
github = "pr_opened"
repos = ["acme/web"]    # 支持 owner/*
authors = ["@me"]       # @me = 你自己

[[workflow.trigger]]    # 定时;默认本机时区,tz = "UTC" 可选
schedule = "weekly"
days = ["mon", "wed", "fri"]
time = "09:00"

[[workflow.step]]
omp = """
审查 {{repo}} 的 PR #{{number}}:{{title}}

{{url}}
"""
```

**定时**(`schedule`):

| 值 | 参数 |
|---|---|
| `once` | `at = "2026-11-06 08:30"`;错过时一小时内补跑一次 |
| `hourly` | `days`(可空 = 每天)、`between = ["09:00", "18:00"]`(整点,省略 = 全天),每个整点触发 |
| `daily` | `time` |
| `weekly` | `days`(`sun`…`sat`,至少一天)、`time` |
| `monthly` | `day`(1–31,没有这天的月份跳过)、`time` |
| `yearly` | `date = "MM-DD"`、`time` |
| `cron` | `cron = "0 9 * * 1-5"` |

所有定时都可以加 `tz`、`repo`(在哪个本机检出中运行)、`ref`。

**GitHub**(`github`,各种类只接受下表列出的筛选器):

| 值 | 何时触发 | 筛选器 |
|---|---|---|
| `pr_opened` | PR 打开(非草稿)或标记为可审查 | repos authors |
| `pr_draft` | PR 以草稿打开或转为草稿 | repos authors |
| `pr_pushed` | 新提交推送到 PR | repos authors skip_drafts |
| `pr_merged` | PR 合并 | repos authors include_closed |
| `comment` | PR 或议题上有新评论 | repos authors assignees comment ignore_bots ignore_self |
| `push` | 提交推送到分支 | repos authors branches |
| `label` | PR 或议题的标签被添加或移除 | repos authors assignees label_actions labels |
| `check_completed` | 检查套件完成 | repos authors conclusions forks |
| `issue_comment` | 纯议题(非 PR)上有新评论 | repos authors assignees comment ignore_bots ignore_self |
| `review_comment` | PR 上有新的审查评论 | repos authors assignees comment ignore_bots ignore_self |
| `review` | PR 审查提交 | repos authors assignees review_states ignore_bots ignore_self |
| `review_thread` | 审查线程被解决或重新打开 | repos authors thread_actions |
| `workflow_run` | Actions 工作流运行完成 | repos authors branches conclusions workflows forks |
| `issue_opened` | 新议题创建 | repos authors labels ignore_bots |
| `event` | 任意事件(`event = "release"`) | repos authors actions branches labels comment |

- 列表筛选器之间是「且」,同一个列表里的多个值是「或」,空着表示任意。
- 「作者」的含义:评论、审查事件里是写评论或审查的人,PR、议题事件里是 PR 或议题的作者,push 事件里是推送者。
- 开关项及默认值:`skip_drafts` 默认开,`include_closed` 默认关,`ignore_bots` 默认开,`ignore_self` 默认开。`ignore_self` 忽略你自己的活动,前提是 `roost.toml` 设了 `[github] login`,或者 App 归你个人所有;把自己(`@me`)写进 `authors` 就会放行你自己的活动。
- **安全默认值**:议题、评论、PR 这类「用户可写内容」事件,默认只接受 `OWNER`/`MEMBER`/`COLLABORATOR` 作者;设 `associations = ["*"]`(表单「高级」里的「允许外部贡献者」)才对所有人开放。`check_completed`/`workflow_run` 默认拒绝代码来自 fork(或无法确认来源)的事件,设 `forks = true` 才接受。omp 以 yolo 模式运行,放开前请想清楚提示词注入与执行外部代码的风险。
- **模板**只用于 omp 提示词:`{{repo}} {{event}} {{action}} {{number}} {{title}} {{body}} {{url}} {{ref}} {{sha}} {{branch}} {{sender}} {{comment}} {{label}} {{workflow}} {{run_id}} {{tmp}} {{trigger}} {{input.<名>}} {{payload.<路径>}}`(数组下标从 0 开始;`{{tmp}}` 是本次运行的临时目录,即 shell 步骤的 `$ROOST_TMP`,运行结束即删)。shell 步骤不做模板替换,改读环境变量 `ROOST_*`:`ROOST_REPO`、`ROOST_NUMBER`、`ROOST_SHA`、`ROOST_BRANCH`、`ROOST_SENDER`、`ROOST_URL`、`ROOST_EVENT_PATH`(完整 payload)、`ROOST_INFO_PATH`(归一化事件)、`ROOST_WORKSPACE`、`ROOST_INPUT_<名>` 等,事件文本不会被拼进命令行。
- **环境变量继承**:shell 步骤以及插件调用的本机工具(`gh`、`omp`)继承你登录 shell 的环境变量,不只是 Tern daemon 的精简环境。插件启动时和之后每 10 分钟,用账户的登录 shell(macOS 取目录服务记录,否则 `$SHELL`,fish 也支持)以 `-l -i -c` 运行一次,读取两个标记之间的 `env -0` 输出,启动文件打印的内容会被忽略;去掉 PWD/OLDPWD/SHLVL/_。结果只保存在内存里。优先级:登录环境 < `[runner] env` < 工作流 `env` < `ROOST_*`;PATH 为 `[runner] extra_path` 加上登录 shell 的 PATH(`env` 里显式设了 PATH 时以它为准)。第一次读取结束前(最多 10 秒),运行不会启动,也不会推进;读取失败会弹出通知,并沿用上一次读到的环境(一次都没读到时用 daemon 的环境)。以 App 身份运行的 shell 步骤不带登录 shell 里的 `GH_TOKEN`/`GITHUB_TOKEN`/`GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN`(你在 `env` 里显式设的保留);omp 步骤在 Tern 的 agent block 里运行,用的是 Tern 的登录环境,以 App 身份运行时会先 unset 后三个,再换上本次运行的 `GH_TOKEN`。
- **步骤输出与条件**:shell 步骤可以向 `$ROOST_OUTPUT` 追加 `键=值` 行(键为字母、数字、下划线,值一行),之后的步骤在提示词里用 `{{out.<键>}}`、在 shell 里用 `ROOST_OUT_<键大写>` 读取。步骤加 `when = "out.<键>"` 或 `when = "input.<名>"`(前面加 `!` 取反)时,只有该值为真(非空,且不是 `0`/`false`/`no`)才运行,否则记为「已跳过」并继续下一步。输出 `stop=<原因>` 会在该步骤成功后结束整个运行,运行记为「已跳过」(不弹通知),适合「没有要处理的东西」。`$ROOST_OUTPUT` 只接受普通文件,只在 shell 步骤里提供。
- **费用与预算**:omp 步骤结束后,插件汇总它会话目录里所有 JSONL(包括子代理)中的 `usage.cost.total` 与 `totalTokens`,记到步骤上,运行详情、步骤表与工作流卡片显示估算费用(按 omp 的标价估算,订阅类 provider 记为 0)。工作流设 `daily_budget = 5`(美元)后,当天(本机时区)该工作流 omp 步骤的累计费用达到预算时,后续 omp 步骤不再启动,运行记为「已跳过」并写明原因。
- **工作区**:在 `[repos]` 里声明了本机路径的仓库,事件运行在 `plugin-data/roost/worktrees/<run>` 的临时 worktree 中(检出 PR 的 `refs/pull/N/head`、push 的 sha 等),结束后自动清理;`workspace = "repo" | "temp"` 可改。没声明的仓库在临时空目录中运行。手动运行用触发器唯一指向的已声明仓库(定时的 `repo`、GitHub 触发器不含通配的 `repos`),否则用唯一声明的仓库;`workspace = "worktree" | "repo"` 却确定不了仓库时拒绝手动运行。
- **手动指定 PR**:有 PR 类触发器(PR 打开/草稿/推送/合并、审查、审查评论、审查线程)的工作流,点「运行」时表单多一个「拉取请求」字段,填 `owner/name#12`、PR 链接,或在触发器只指向一个仓库时只写编号;只有 PR 类触发器时必填,还有其他触发器时留空就是普通手动运行。插件用本机 `gh api repos/<仓库>/pulls/<编号>` 读取 PR(PATH 含 `[runner] extra_path`;中继不提供 PR 读取),把它整理成和 webhook 相同的事件字段(`action = "manual"`),`payload` 为 `{action, pull_request, repository}`,在 PR head(`refs/pull/N/head`)上运行;读取期间取消表单则不排队。
- 取消或超时时,shell 步骤会向整个进程组发送 SIGTERM,8 秒后 SIGKILL;omp 步骤直接关闭它的 agent 标签页。插件重载时,仍在运行的步骤会被重新接管。

### omp 步骤与会话

- omp 步骤以 **Tern 原生 agent block** 运行。Tern 窗口在固定会话(`roost.toml` 的 `[runner] session`,默认 `Roost`,不存在时自动创建)里新开一个标签页执行。打开时不会抢走焦点。这一轮结束后标签页自动关闭,成功或失败都会关;如果被人手动关掉,这一步按失败处理。
- agent 运行期间,插件每 2 秒读取它的会话文件,把进展写进运行日志:标签页打开、每段说明文字、每次工具调用(一行,取工具的意图说明或路径/命令)、失败的工具结果,最后是完整的最终回复和结束状态。会话文件里没有最终回复时(例如没能打开 agent),改为追加窗口记录的最后一条消息。
- agent 只能由窗口打开:插件 host 把任务写进运行目录和 kv,所有窗口用 `mkdir` 认领,保证只有一个窗口去打开。**没有打开的 Tern 窗口时,omp 步骤会一直等待,直到有窗口出现或超时**。agent 已经打开后如果所有窗口都关了,取消和超时要等有窗口重新打开后才会关掉它。
- omp 以交互式运行,会话保存在运行目录 `runs/<run>/s<步骤>.session/`(`--session-dir`),不会写入 `~/.omp`。这些会话随运行一起按 `[retention]` 清理。`-p`、`--session-dir`、`--resume`、`--continue` 等参数由 Roost 管理,写进 `omp_args` 或步骤 `args` 会报配置错误。
- omp 步骤收不到 `[runner] env`、工作流 `env` 以及 `ROOST_*` 环境变量,环境沿用 Tern 打开 agent 时的环境。需要的信息请通过提示词模板传入。
- **打开会话**:在运行详情的步骤时间线里双击 omp 步骤,或点详情里的「omp 会话」按钮(打开最后一个 omp 步骤),默认在控制台右侧分屏打开。还在运行的 agent 以**只读 collab 观看者**打开(`omp join`):实时同步,关掉分屏不影响这一步;agent 本身仍留在 Roost 会话里。为此 omp 步骤启动时带 `--config runs/<run>/s<i>.collab.yml`(`collab.autoStart = view`),会话经 omp 的 collab 中转(`collab.relayUrl`,默认 `wss://my.omp.sh`,链接里带密钥)同步。已结束的会话用 `omp --resume` 在分屏里续开。按钮旁的下拉箭头和步骤的右键菜单提供另一种方式:运行中的选「在 Roost 会话中打开」,跳到 agent 本身所在的标签页(可以操作,关掉会结束这一步);已结束的选「在新标签页打开」。
- **模型**:运行详情的事实表列出 omp 步骤用到的模型,每个模型一行,后面写明谁在用:步骤自己的回合、子代理(`子代理 <名字>`)和 omp 的旁路调用(如 `judge`),都取自会话文件(agent 运行中每 20 秒读一次,结束时再读一次)。还没有会话记录的步骤(待运行或刚开始)按它的 `model` 设置显示:`@角色` 和不写(omp 的 `default` 角色)用本机 `omp config get modelRoles` 换算成具体模型。这个功能之前结束的运行,打开详情时会补读一次。
- **日志文件**:在当前标签页上方以预览浮层(glimpse)打开该运行的 `log.txt`,点外面或按 Esc 关闭,拖动标题栏可保留。

### 任务、追问与改动

- **内置运行**:追问、开 PR 是内置运行(工作流 id 为 `task.<hex>`,不写进 workflows.toml,重载后照样接着跑);仓库有本机检出时一律在该仓库的临时 worktree 里做,不碰你的检出。首页「最近任务」列出最近 5 个。
- **结果**:运行详情在事实表下面用 Markdown 显示最后一个 omp 步骤的最终回复(前 16 KiB)。
- **改动**:每个 worktree 运行在「准备 worktree」时记下起点提交(`runs/<id>/base.txt`),在「清理 worktree」删除前把全部改动(含未提交、新文件)对起点做 diff,存成 `changes.patch`、`changes.numstat`(文件表,最多 2000 个文件)和 `changes.total`(全部改动的文件数与增删行数);补丁超过 8 MiB 时不保存补丁。改动只存在运行目录,随运行按保留策略清理,不往仓库写任何 ref。详情里有文件表和:
  - **查看 diff**:浮层显示补丁(前 512 KiB),可用编辑器打开全部;
  - **建本地分支**:在运行用的那个检出里用临时 worktree 建 `roost/<运行 id>` 并提交补丁,不切换当前分支、不改工作区;
  - **开 PR**:填标题、说明(默认是最终回复)、目标分支,启动一个内置「开 PR」运行:在起点提交上应用补丁、提交、推送 `roost/<运行 id>`(这个分支归 Roost 所有,重试会覆盖它)、`gh pr create`(默认以 App 身份),原运行会链接这个 PR;
  - **复制补丁路径**。
- **追问**:已结束且有 omp 会话的运行(工作流运行也可以),详情标题处点「追问」写下后续要求。追问是一个新运行,第一步「接续上一次运行」把上一次的会话目录和补丁复制过来;worktree 建在上一次的起点提交上并应用它的补丁,omp 用 `--resume` 接着那段对话。`workspace = "repo"` 的工作流运行的追问同样直接在本机检出里继续改。费用只计新增部分(复制来的历史从统计里扣除),日志也只追加新内容。详情里有「接续自」「追问 · 状态」链接。上一次运行已被清理、补丁过大或没能收集到改动时无法追问。运行进入「清理 worktree」或「回复」之后不能再取消。

### 收件箱

工作流可以把「需要人处理的事」报给首页的「待处理」。shell 与 file 步骤拿到 `$ROOST_INBOX`(一个文件路径),结束前写一个 JSON:

```json
{ "replace": true,
  "items": [ { "id": "pr-1073", "title": "PR #1073 等待批准", "detail": "C 级 · 审查通过",
               "url": "https://github.com/acme/web/pull/1073", "kind": "approve",
               "run": { "workflow": "merge-gate", "pr": "1073" } } ],
  "resolve": ["pr-1001"] }
```

- 条目归属于写它的工作流。`replace: true` 表示这个工作流的条目整体换成 `items`;省略时按 `id` 增改,`resolve` 里的删除。
- `kind`:failed、approve、decide、review、info(排序和颜色);`run` 可选,给出「运行」按钮(带 PR 或输入派发该工作流,输入合计最多 2000 字符)。长度按字符计:title 120、detail 400;每个工作流最多 100 条,全部工作流合计最多 200 条(超出时先删其他工作流最早上报的);文件最多 64 KiB,非法内容只在运行日志里记一行。同步给其他设备时内容过大会先舍弃收件箱。
- 每条可以「打开」链接、「运行」、「忽略」(只在本机隐藏,内容变化后再出现)。存在 `plugin-data/roost/inbox.json`;工作流删除后它的条目一并删除;各设备的收件箱随运行摘要同步,每个工作流显示负责它的设备上报的条目。

### @ 提及与评论回复

- GitHub 触发器「被 @ 提及」(`github = "mention"`):议题、PR 或审查评论里 @ 了 App(`@<App 名>`,或筛选器「另一个提及名」如 `@roost`)时触发,默认只接受 OWNER/MEMBER/COLLABORATOR,也不响应 App 自己的评论。提示词里 `{{request}}` 是去掉提及后的请求。
- 工作流开关「在评论中回复」(`reply = true`):由议题/PR 事件启动的运行,开始时在原处评论「Roost 收到,正在处理…」,结束后(失败、取消也会)把这条评论改成结果和最终回复;回复里的 @ 会被中和,不会提醒别人,也不会再次触发提及。模板库有「@ 提及就处理」。

### 用描述生成自动化

「自动化」页工具栏的「用描述生成」:写一句话描述,omp(不带工具、不留会话)按 workflows.toml 规范起草一个工作流,校验有问题会带着问题重试一次,然后在编辑器里以新建方式打开给你审阅;不会自动保存。

### API 调用

触发器「API 调用」(编辑器「添加触发器 › 其他」):点「生成令牌」得到一个只显示一次的令牌,workflows.toml 只存它的 SHA-256(`api = "<64 位十六进制>"`)。订阅推送时把哈希一起交给中继,外部系统这样调用:

```sh
curl -X POST https://<中继>/hooks/dispatch/<工作流 id> \
  -H "Authorization: Bearer <令牌>" -H "Content-Type: application/json" \
  -d '{"inputs":{"focus":"docs"}}'
```

令牌只能启动这一个工作流;未知工作流与错误令牌返回同样的 401;每个工作流每分钟最多 30 次;请求体最多 64 KiB、32 个输入。中继把它作为 `roost_dispatch` 事件交给各设备,由负责该工作流的设备运行,只接受工作流声明过的输入(缺必填输入则不运行,事件页写明原因)。重新生成令牌并保存后旧令牌失效。

### 环境

`roost.toml` 里定义只在本机的环境(不同步、不导出):

```toml
[environments.prod]
vars = { API_KEY = "…", REGION = "eu" }
path = ["/opt/prod/bin"]
setup = "make deps"
```

工作流的「环境」(高级设置,`environment = "prod"`)选用它。运行先执行「准备环境」:把变量和 `path` 写进运行目录的 `environment.sh`(权限 600,运行结束即删)供 omp 步骤 source,再在工作区里跑 `setup`;shell 步骤的环境里直接有这些变量,`path` 排在 PATH 最前面。设置「通用」页列出各环境的变量名(不显示值)。

### 脚本文件、文件库与导出

脚本和提示词不必写成「脚本位置 + 执行命令」,由 Roost 保管在插件数据目录,在编辑器的「文件」区直接编写:

| 位置 | 说明 |
|---|---|
| `workflows/<id>/files/` | 工作流自己的文件,随工作流保存;改 id 时一起搬走,删工作流时一起删除 |
| `library/<库>/` | 文件库:多个工作流共用的脚本和提示词。工作流用 `libs = ["库"]` 声明,或在步骤里写 `file = "@库/路径"`;仍被使用的库删不掉。在「自动化 › 文件库」管理 |
| `state/<组>/` | 跨运行保留的状态(`state = "组名"`,默认是工作流 id)。**不会自动删除**,在「自动化 › 文件库」手动删 |

```toml
[[workflow]]
id = "triage"
state = "triage"              # $ROOST_STATE 指向 state/triage/
libs = ["fluxdown"]

[[workflow.step]]
file = "@fluxdown/issues.py"  # 文件库里的脚本;"scan.py" 则是工作流自己的文件
args = ["triage-scan"]        # 作为命令行参数传给脚本
```

- 文件步骤按扩展名选解释器:`.py` → `python3`,`.sh` → `/bin/sh`,`.bash` → `bash`,`.js`/`.mjs`/`.cjs` → `node`(在步骤的 PATH 中查找)。其余类型不能作为步骤,但可以放在文件里被脚本读取(如提示词 `.md`)。路径各段只能以字母、数字或 `_` 开头(没有隐藏文件和 `..`),最多 8 层;单个文件 ≤512 KiB,每个目录树 ≤200 个文件、总计 ≤4 MiB。
- **运行用的是副本**:运行开始时,Roost 把工作流文件复制到 `runs/<run>/files/`,用到的库复制到 `runs/<run>/lib/<库>/`。运行期间再编辑文件不影响正在跑的运行;缺库则运行直接失败。副本随运行目录按 `[retention]` 清理。
- **环境变量**:`ROOST_FILES`(工作流文件副本)、`ROOST_LIB`(库副本的上级目录)、`ROOST_STATE`(状态目录)、`ROOST_TMP`(临时目录)。`PYTHONPYCACHEPREFIX` 指向 `$ROOST_TMP/pycache`,Python 的缓存不会落进文件里。`$ROOST_TMP` 在运行结束时删除;命令里的 `run` 步骤同样拿到这些变量。
- **导出**:工作流卡片的「导出」或工具栏的「导出全部」,生成 `plugin-data/roost/exports/<时间>-<名>.roost.toml`(路径自动复制)。文件自包含:工作流定义、它的私有文件、它用到的整个文件库、仓库的 `branch`/`worktree`(**不含本机路径**)。不含状态、运行历史和凭据。只保留最新 50 个导出文件,「存储与清理」可清空。
- **导入**:「导入」填路径或 exports 里的文件名,先预览再导入。导入的工作流一律**停用**,需检查后手动启用;已存在的工作流、内容不同的库只在「覆盖导入」时替换。仓库的本机检出路径需要自己在 `workflows.toml` 里填。校验全部通过才开始写,先写文件、最后写 `workflows.toml`(带 `.bak`)。
- 老的 FluxDown 流水线可以用 `scripts/migrate-fluxdown.py` 一次性迁入文件库 `fluxdown`(有排队或运行中的 FluxDown 运行时拒绝执行)。

### 标签页、自迭代与自升级

**标签页步骤**:工作流可以开关 Tern 标签页,但只能关 Roost 自己开的。

```toml
[[workflow.step]]
name = "打开日志"
tab = "open"                       # open | close
key = "logs"                       # 标签页的键,按工作流区分(别的工作流关不到它)
command = "tail -f \"$ROOST_RUN_DIR/log.txt\""   # 可选;留空则打开 shell
title = "运行日志"                 # 可选,默认步骤名
keep = false                       # 默认 false:运行结束时自动关闭;true 则保留到 tab = "close"
focus = false                      # 默认在 Roost 会话后台打开;true 则在当前会话打开并切过去

[[workflow.step]]
tab = "close"
key = "logs"
```

- 由 Tern 窗口执行:host 把操作写进 `tabs/ops/`,窗口用 `mkdir` 认领(多个窗口只有一个执行),120 秒内没有本机窗口处理则该步失败。
- 每个打开的标签页登记在 `tabs/open/<工作流>.<键>.json`(pane id 与块类型);关闭前核对 pane 仍在、类型没变,对不上就只删登记不关。手动关掉的标签页会从登记里移除。同一个键再次 open 会先关掉旧的。
- `command` 不做模板替换,经一个只含 `ROOST_*`(运行 id、目录、工作区、文件、状态、输入与输出)的环境文件启动,不含令牌。

**工作流自迭代**:设置了 `evolve` 的工作流是「迭代者」,可以改其他工作流的脚本、提示词和 `[[workflow]]` 块。

```toml
[[workflow]]
id = "doctor"
evolve = ["*"]                     # 或具体 id;不能包括自己,被迭代的工作流不能再有 evolve
concurrency = "queue"              # 失败排队处理;抽查只在迭代者空闲时触发

[[workflow.trigger]]
roost = "run_failed"               # 被迭代的工作流失败或超时时触发(中断、取消不算)
streak = 1                         # 连续这么多次才触发
# workflows = ["triage"]           # 可选:只对这些工作流

[[workflow.trigger]]
roost = "run_succeeded"            # 抽查:被迭代的工作流运行成功时触发
sample = 100                       # 抽查比例(1–100,默认 100;同一运行的结果固定)

[[workflow.trigger]]               # 也可以定时巡检
schedule = "daily"
time = "04:00"

[[workflow.step]]
omp = "迭代材料在 {{evolve_dir}},先读 README.md……触发的工作流 {{evolve_target}},运行 {{evolve_run}}"
```

- 迭代者的每次运行先有一步「准备迭代材料」,写进 `runs/<id>/evolve/`:`digest.md`/`digest.json`(第一行写明是失败、抽查还是巡检;最近 10 次运行、近 7 天健康度、以往修订)、`logs/`(触发本次的运行与近期失败运行的日志末尾,各 48 KiB)、`context/`(只读背景:令牌、密钥与 env 值已隐藏的 `roost.toml`,仓库与本机路径,近期迭代运行已提出的建议)、`base/` 与可编辑的 `edit/`(`workflows/<id>/workflow.toml` + `files/`,以及只被这些工作流使用的文件库)。
- **抽查**:`run_succeeded` 让迭代者复查成功的运行:结论是否正确、步骤是否多余、耗时与费用、日志与临时数据是否冗余、调试后是否清理干净、哪些人工环节能自动化。迭代者已有运行在跑或排队时不触发(连「已跳过」的运行记录都不留),冷却与每日上限与失败修复分开计,不会挡住失败的修复。
- 运行**成功**结束后,Roost 比较 `edit/` 与 `base/`,和编辑器保存走同一套校验后自动应用;期间被别处改过的工作流跳过,改 id、加 `evolve` 的改动丢弃。每次应用记为一个修订,修订前后的快照在 `revisions/<n>/`。
- **改进建议**:`edit/` 改不了、需要人处理的(系统配置、新的自动化、Roost 本身的代码等),迭代者写进 `runs/<id>/evolve/suggestions.md`;运行成功后 Roost 把它写进运行日志并弹通知,之后的迭代材料把最近 10 份建议放进 `context/suggestions.md`,避免重复提出。
- **自动回滚**:之后被改动工作流(和用到被改文件库的工作流)的运行会被观察:至少 2 次失败且失败率比修订前高 25% 以上就恢复修订前的快照(修订后又被别处改过的不自动恢复);观察 5 次运行或 7 天后保留。总览页「自迭代」卡片列出修订,可手动回滚。
- 防止空转:同一迭代者对同一工作流 30 分钟内只触发一次,每天最多 20 次(失败与抽查分开计);迭代者自己的运行不触发;刚被自动回滚的那次失败也不触发。费用用工作流的 `daily_budget` 限制。
- 模板库「自迭代」组里有现成的「工作流自迭代」(失败修复 + 30% 抽查 + 每日巡检)。迭代者也可以在 Roost 源码的 worktree 里运行并以 `upgrade = true` 结尾,同时改进 Roost 自己的代码(见下)。

**Roost 自升级**:`upgrade = true` 步骤把本次运行 worktree 里的新提交应用到 Roost 自己的插件目录,这是插件唯一会写插件目录的地方,而且只在插件进程外进行。

1. 先克隆插件目录作为源码仓库,并在 `workflows.toml` 声明:`git clone <插件目录> <plugin-data>/roost/repos/roost`(macOS 是 `~/Library/Application Support/Tern/plugin-data`,Linux 是 `~/.local/state/tern/plugin-data`),`[repos."local/roost"] path = "<上面的目录>"`、`branch = "main"`。
2. 工作流在这个仓库的 worktree 里运行(`workspace = "worktree"`,`identity = "local"`):omp 步骤改代码、跑 `scripts/check.sh`、`git commit`,最后一步 `upgrade = true`。模板「Roost 自升级」就是这样。
3. `upgrade` 步骤检查:`tern` 在 PATH 上,提交必须是插件目录当前 HEAD 的后续、插件目录没有未提交的修改且在分支上,然后在一个干净的 worktree 里用**插件当前版本**的 `scripts/check.sh` 检查这个提交(提交改不了评判自己的检查)。通过后交给后台脚本(`upgrade/<运行>.apply.sh`,结束时自删)。
4. 后台脚本 fast-forward 插件目录,执行 `tern plugin reload roost`,等新版本 host 加载完写出 `boot.txt`;重载失败或 90 秒内没有新的 boot,就 `git reset --keep` 回到旧提交并再重载。结果写进 `upgrades/<运行>.json`,下次启动时以通知报告,总览页「自迭代」卡片也列出最近的升级。

### 数据保留与清理

长期积累的数据都有自动清理和手动清理两种方式:

| 数据 | 自动清理 | 手动清理 |
|---|---|---|
| 运行记录、日志、事件负载、omp 会话、遗留 worktree | `[retention] runs = 200`、`run_age = "30d"`:超出数量或结束超过时长的**已结束**运行会被删除;没有对应运行的目录一并清掉 | 运行详情的「删除」;设置「存储与清理」页的「按策略清理」「删除全部已结束运行」 |
| 「事件」页记录(`events.json`) | `events = 200`、`event_age = "30d"` | 「事件」页或「存储与清理」的「清空记录」 |
| 中继的事件缓存(服务器 `events/`) | `agent.toml` 的 `[store] keep_events`、`max_age`、`max_total_bytes` | 设置「中继与设备」页的「清空中继事件缓存」 |
| 中继的投递统计(服务器内存) | 最近 200 条、统计 256 组,重启即清空 | 设置「中继与设备」页的「清空统计」 |

- 自动清理在插件启动时、每小时一次、`[retention]` 首次生效或修改之后执行。roost.toml 有错误时不按策略删除任何东西;旧的 `[runner] keep_runs` 会报错并提示改成 `[retention] runs`。时长写 `"0"` 表示不按时间清理,否则至少 `1h`。`runs` 只计已结束的运行,排队中和运行中的运行不会被删除。
- 目录在后台分批删除:每批最多 8 个,交给 `rm -rf` 在插件进程外执行,所以不会卡住面板,也不会跟随 worktree 里的符号链接删到外面。删除失败的目录会重试。「存储与清理」卡片显示各部分的磁盘占用、上次自动清理删了什么,以及还有多少目录在等待删除。如果 `runs.json` 曾无法读取(留有 `runs.json.unreadable`),就暂不清理无主目录,以免误删旧运行。
- 删除和清空都要点两次,两次点击之间要隔 0.8 到 5 秒,所以双击不会误删。第一次点击后按钮变成「确认…」,按键、切换选择或做别的操作都会取消。
- 「事件」页每行的「结果」列显示它启动的运行和运行状态,选中这一行会跳到对应的运行;运行已被清理的标为「记录已清理」。首次连接中继,或者还没有 `events.json` 时,会取回中继里最近 20 条已读事件作为历史,只展示不触发;如果当时启动过运行,会按投递 id 关联上。
- 设置「中继与设备」页底部的「Webhook 投递」按结果、事件和仓库统计 GitHub 发来的 webhook。「已忽略」表示没有任何工作流订阅这个事件,所以不会转发到本机,本机的「事件」页也看不到它。给工作流加上对应的 GitHub 触发器后,订阅会自动同步。

## 部署中继 roost-agent

```sh
cd agent && cargo build --release          # 产物在 /tmp/roost-cargo-target/release/roost-agent
scp /tmp/roost-cargo-target/release/roost-agent server:/usr/local/bin/
```

服务器上:

1. `agent/deploy/agent.example.toml` → `/etc/roost/agent.toml`(权限 600)。管理令牌写成 `env:NAME` 或 `file:/path`,并放进 `/etc/roost/env`:`ROOST_TOKEN=$(openssl rand -hex 24)`。
2. 在 TLS 反向代理(Caddy/Nginx)后暴露 `listen`,把 `server.public_url` 设为公网地址(GitHub 要用它回调和投递 webhook)。
3. `agent/deploy/roost-agent.service` → `/etc/systemd/system/`,`systemctl enable --now roost-agent`。
4. `roost-agent check --config /etc/roost/agent.toml` 校验配置。

本机 `roost.toml`:

```toml
[relay]
url = "https://roost.example.com"
token = "<ROOST_TOKEN 的值>"   # 或 token_env = "ROOST_TOKEN"
```

### 创建 GitHub App

中继以 GitHub App 的身份工作,不需要个人令牌,也不用逐个仓库配置 webhook:

1. Roost 设置的「GitHub App」页点「创建 GitHub App」。要建在组织下,先填组织名。
2. 浏览器打开中继的页面,页面会自动把 App 清单提交给 GitHub。GitHub 显示确认页,名称可以改,确认后点创建。
3. GitHub 回调中继。中继把 App 的 id、私钥和 webhook 密钥保存到 `<data>/github-app.json`(权限 600),然后跳转到安装页。在安装页选择要安装的仓库。
4. 以后要增减仓库,在 GitHub 的 App 安装设置里修改。

App 申请的仓库权限:actions、checks、contents、deployments、discussions、issues、pull_requests、statuses、workflows 为读写,metadata 只读,另有 administration 读写。中继用 App 接收事件、给表单提供仓库/人员/标签/分支/工作流名称的建议,并给每次运行签发令牌(见下一节)。「忘记本地凭据」只删除中继上的凭据,App 本身要到 GitHub 设置里删除。

2026-11-06 之前创建的 App 只有只读权限。GitHub 不允许通过 API 修改 App 权限,需要手动升级:设置「GitHub App」页点「权限设置」,在 Permissions 中按上面的列表开启读写,保存;再到每个安装(组织或个人账号的 Installed GitHub Apps)接受新权限。「GitHub App」页会列出还没生效的权限,工作台首页的「待处理」也会提示。

头像:GitHub 没有设置 App 头像的 API,只能在 App 设置页上传。「GitHub App」页点「设置头像」打开设置页,Roost 自带的头像在 `assets/app-logo.png`(512×512,源文件 `assets/app-logo.svg`)。

### 以 App 身份运行

运行在 GitHub 上的操作(评论、审查、推送、开 PR)默认以 App 的机器人账号 `<slug>[bot]` 进行。`roost.toml` 的 `[github] identity = "local"` 可改回本机 `gh` 身份,单个工作流可用 `identity = "app" | "local"` 覆盖。没有关联仓库的运行总是用本机身份,日志里会写明。

- 以 App 身份的运行,第一步是「获取 App 令牌」:插件调用 `POST /api/v1/github/token`,中继签发一个**只限该仓库**的安装令牌,包含安装授予的所有权限,唯独去掉 administration。令牌约一小时过期,运行期间插件会在到期前 15 分钟自动续期;运行结束后删除令牌文件。
- **禁止强推默认分支**:签发令牌前,中继检查仓库默认分支(通常是 main)是否已有禁止强推和删除的规则;没有就用 administration 权限加上规则集「Roost: protect default branch」(non_fast_forward + deletion,仓库管理员可绕过,App 不能)。规则加不上(例如私有仓库所在账号的套餐不支持规则集,或安装还没接受 administration 权限)时,中继拒绝签发令牌,运行失败并在日志中写明原因。其他分支的强推、rebase、合并、推送到 main(快进)都允许。
- 令牌保存在运行目录的 `app-token`(权限 600),只经标准输入写入,不出现在命令行或环境文件里。shell 步骤得到 `GH_TOKEN`;所有步骤都会把 `<plugin-data>/bin/gh` 放到 `PATH` 最前,这个包装每次调用都读取当前令牌再执行真正的 `gh`。git 通过 `GIT_CONFIG_*` 只对 github.com 使用该令牌(清掉你自己的凭据助手),ssh 远端改走 https,提交作者与提交者是 App 机器人(`<id>+<slug>[bot]@users.noreply.github.com`)。
- omp 步骤:`cx.agents:start` 不能传环境变量,所以 omp 通过 `/bin/sh` 先 source 运行目录里的 `s<i>.env`(只含上述变量,不含令牌)再启动。准备与清理 worktree 仍用你本机的 git 身份。之后从运行详情续开的历史会话也是本机身份。
- 工作流触发器的「忽略我自己的活动」同样忽略 App 机器人的活动,避免 Roost 回复自己的评论形成循环。
- 限制与注意:中继地址必须是 https(本机回环地址除外),否则不签发 App 令牌;令牌或身份丢失(例如插件恰好在令牌步骤后重载)时,后续步骤直接失败,不会退回你的身份。`$GH_TOKEN` 是步骤启动时的快照,超过一小时的步骤里直接读它的工具(curl 等)应改读 `$ROOST_GH_TOKEN_FILE`;`gh` 包装和 git 凭据总是读最新令牌。你的 git 配置里若有 `url.….pushInsteadOf` 把 github.com 推送改回 ssh,推送仍会用你的 ssh 密钥。

### 配置同步与回退

- **本地优先**:保存 `workflows.toml` 后,插件计算每个仓库需要的事件,推送到中继(`PUT /api/v1/subscriptions`,带版本号防覆盖)。仓库筛选为空的触发器订阅在 `"*"`(任意仓库)下。中继只保留订阅了的事件。
- **回退到云端手动设置**:推送失败时,设置「中继与设备」页给出完整的 `subscriptions.toml` 内容可复制;保存到服务器后点「重新加载」(或 `systemctl reload roost-agent`)。
- 服务器上手改过订阅后,本机再推送会提示冲突:可「以本地覆盖」或「采用云端」。
- 订阅状态以中继 `/status` 报告的版本为准:中继运行的正是本机上次推送的版本且本地没改 →「已同步」;采用云端后 →「沿用云端」(本地修改工作流后自动改推本地版本);还没拿到中继状态 →「待核对」。「推送订阅」总会发起一次推送,即使内容没变。
- **远程重启**:`agent.toml` 改动(或换了二进制)后,点「重启中继」即可,无需登录服务器。中继原地 `exec` 自身(PID 不变),已缓存的事件与游标保留。

### 多台设备:按工作流分配

同一个中继可以连多台装了 Roost 的电脑,GitHub App 不用重装(凭据在服务器上)。每台设备都读取全部事件,但每个工作流只在**负责它的设备**上运行:

- **默认设备**:在设置「中继与设备」页的「设备」卡片里把一台**设为默认**(点两次确认)。没单独指定设备的工作流都由它运行。没有默认设备时,和以前一样每台在线设备都会运行这些工作流(两台同时在线会执行两次)。
- **单独指定**:工作流卡片上的设备菜单,或「中继与设备」页的「工作流由谁运行」,可以把某个工作流交给某台设备,或改回「跟随默认设备」。改派按中继收到事件的顺序生效:改派之后到达的事件归新设备,之前的仍归当时负责的设备(那台设备离线时,上线后补跑),所以改派不会漏跑也不会重复。定时任务按当前分配在负责的设备上触发。
- **手动运行**:任何设备都能点「运行」。工作流归本机时在本机运行;归其他设备时经中继转发给那台设备(`roost_run` 事件),它离线就等它上线再跑。追问、开 PR 这类内置运行在点击的设备上运行;自迭代的迭代者在触发它的运行所在设备上运行。
- **共用配置**:全部工作流、它们的文件、用到的文件库、仓库的分支设置和分组按导出格式存在中继上(env 的值不上传),**任何设备都能修改**。本机保存后上传(以本机最后同步的版本为基准,中继按版本比较后写入);其他设备收到新版本后自动套用,保留本机各仓库的 `path` 与 env 的值,删除配置里已没有的工作流及其文件。`state/` 目录不同步。分配给本机的工作流用到的仓库要在本机 `workflows.toml` 填 `path`,否则「同步」卡片会提示。
- **冲突**:两台设备几乎同时修改时,先上传的生效;另一台在套用新版本前,把本机没同步出去的 `workflows.toml` 另存为 `workflows.toml.before-sync-<时间>`(保留最近 10 份)并导出工作流,再提示一次。设备第一次同步时若本机已有自己的配置,同样先备份。
- **运行同步**:每台设备把最近 100 条运行的摘要(状态、步骤、耗时、费用,最近 20 条带日志最后 4 KiB)和收件箱上传到中继。「运行」页合并显示所有设备的运行(多一列「设备」),其他设备的运行只读;收件箱里每个工作流的条目来自负责它的设备。
- **订阅**:各设备由同一份配置算出同样的订阅,中继收到与现有内容相同的订阅时不论基准版本都接受;本机配置落后于共用配置时暂不推送(状态「等待配置同步」)。
- 中继的设备记录(`fleet.json`)读不出来时,中继不当作「没有分配」,而是任何设备都不运行、不读新事件、不改配置,直到在「中继与设备」页重新指定默认设备。
- 升级中继后所有设备都要升级 Roost:旧版本的设备会把默认设备当成唯一执行者。
- 在 `roost.toml` 的 `[relay]` 设置 `client_name`,其他设备用这个名字称呼本机。

### 中继 API

除 `/healthz`、`/hooks/github`、`/hooks/dispatch/*`(用各工作流自己的令牌)和 `/github/app/*` 页面外,都需要 `Authorization: Bearer <token>`(中继的管理令牌)。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/hooks/github` | GitHub App webhook(用 App 的密钥验证 `X-Hub-Signature-256`) |
| POST | `/hooks/dispatch/{工作流 id}` | 外部启动工作流(`Authorization: Bearer <该工作流的令牌>`,`{"inputs":{…}}`);只认订阅里 `dispatch` 登记的令牌哈希 |
| GET | `/api/v1/events?after=&wait=&limit=` | 拉取事件,`wait` 秒长轮询(≤30) |
| GET/PUT | `/api/v1/subscriptions` | 读取/推送订阅(`repos`,以及 `dispatch`:工作流 id → 令牌 SHA-256;`base_revision` 不符返回 409) |
| POST | `/api/v1/reload` | 重新读取 `subscriptions.toml`(SIGHUP 同效) |
| POST | `/api/v1/restart` | 原地重启 |
| POST | `/api/v1/github/app/manifest` | 开始创建 App(`{"org"?, "name"?}`),返回要在浏览器打开的地址 |
| DELETE | `/api/v1/github/app` | 删除本地 App 凭据 |
| GET | `/api/v1/github/{repos,people,labels,branches,workflows}?repo=` | 表单建议 |
| POST | `/api/v1/github/token` | 为一次运行签发 App 令牌(`{"repo"}`):先确保默认分支禁止强推与删除,返回 `token`、`expires_in`、`login`、`email`、`permissions`、`branch`、`protection` |
| POST | `/api/v1/events/test` | 产生一条 `roost_test` 事件,验证全链路 |
| DELETE | `/api/v1/events` | 清空缓存的事件(序号继续递增,客户端游标仍然有效;还没读到的客户端会看到缺口提示) |
| GET | `/api/v1/status`、`/api/v1/deliveries` | 状态(含 App 信息、设备记录 `fleet`:默认设备、各工作流的分配历史 `owners`、共用配置与各设备运行摘要的版本);最近投递,以及按结果、事件、仓库的计数(内存中,从启动或上次清空开始) |
| PUT | `/api/v1/fleet/executor` | 指定默认设备(`{"client" 或 null, "base_revision"}`,版本不符返回 409,中继不认识的设备返回 404) |
| PUT | `/api/v1/fleet/assign` | 给工作流指定设备(`{"workflow", "client" 或 null, "base_revision"}`,从当前事件序号之后生效) |
| GET/PUT | `/api/v1/fleet/config` | 共用的工作流配置(导出格式,`?have=<版本>` 未变时不返回正文);写入带 `base`(上传者最后拿到的版本),不符返回 409 `config_conflict` |
| PUT | `/api/v1/fleet/runs`、GET `/api/v1/fleet/runs/{设备}` | 上传本机的运行摘要(≤512 KiB)/读取某台设备的 |
| POST | `/api/v1/fleet/run` | 请另一台设备手动运行(`{"workflow", "target", "inputs"?, "pr"?}`),以 `roost_run` 事件送达 |
| DELETE | `/api/v1/deliveries` | 清空投递记录与计数 |
| GET | `/github/app/new`、`/github/app/callback`、`/github/app/installed` | App 注册流程的浏览器页面 |

## 外观定制

面板分成两个 block,都按 Tern 设计规范组织:标题行、页签,再是当前视图;数字键切换页签。

- **工作台**(命令「Roost:打开工作台」):标题行只显示需要注意的状态(中继断开、多设备时本机运行几个工作流、配置错误),右侧是「重新读取配置」与「设置」。三个页签:
  - **首页**:4 个指标(运行中、24 小时运行数、24 小时成功率、下一次定时);「待处理」列出需要人处理的事——系统状态(配置错误、中继断开或设备记录损坏、订阅未同步、有事件被中继淘汰、App 权限未生效、各工作流最近一次运行失败,单击跳到对应的运行或设置页)和工作流上报的收件箱条目(打开/运行/忽略);「进行中」「最近任务」;然后是即将触发的定时、近 14 天的「运行次数」(成功 / 失败)与「运行耗时」(P50 / P95)折线图、通知和自迭代记录。
  - **自动化**:工具栏左侧的分段切换在「工作流」(见下文)与「文件库」(见「工作流文件」一节)之间切换。
  - **活动**:同样用分段切换在「运行」(见下文)与「事件」之间切换。页签记得上次看的是哪一个视图。
- **设置**(命令「Roost:设置」,或工作台标题行的「设置」):「通用」(roost.toml / workflows.toml 卡片并排,状态徽章与编辑按钮在卡片标题行;运行设置、环境、外观)、「中继与设备」(连接与维护、事件订阅与同步状态并排;设备与默认设备、各工作流由谁运行、Webhook 投递)、「GitHub App」(身份信息;管理与危险操作分开)、「存储与清理」(运行、事件、导出、脚本、状态目录的数量与体积;保留策略、按策略清理与删除类操作分组)。宽窗口两列,窄窗口自动叠成一列。工作台里指向设置的链接会打开设置并切到对应页;已经打开的设置标签页会直接切过去。
- **活动 › 运行**:左右分栏铺满整个面板,页面本身不滚动。左边是运行列表(状态、运行 ID、工作流与事件摘要、触发方式、估算费用(只有 omp 步骤有统计的运行才有)、时间、耗时;变窄时依次隐藏触发方式、ID 列、费用,悬停行可看完整 ID,右键菜单可复制),右边是选中运行的详情:标题行(工作流名、事件摘要、状态、耗时、重跑/取消),键值对齐的事实表(第一行是运行 ID,与磁盘上的 `runs/<ID>/` 同名,排查和沟通时直接引用;其后是失败原因、触发与事件链接、仓库与 ref、身份、输入、创建时间、用到的模型、估算费用),步骤时间线(每个步骤按开始时间和耗时画成条;双击 omp 步骤在右侧分屏打开它的会话,右键可选打开方式),omp 会话(带打开方式下拉)/ 日志文件 / 复制 ID / 自动换行 / 工作区按钮,最后是实时日志,占满详情的剩余高度并在其中滚动。「自动换行」默认打开,日志按窗格宽度换行;关闭后长行保持一行,只在日志区内横向滚动。
- **自动化 › 工作流**:每个工作流一张卡片平铺(宽窗口每行 2–3 张):标题右侧是「设备」(连了中继时:由哪台设备运行,可在菜单里改)、「分组」「编辑」「导出」「运行」,正文是描述(固定占 3 行,超出部分省略,鼠标悬停显示全文)、触发器、仓库(超过两个时折叠为「等 N 个」)、步骤与下次定时,底部固定在卡片最下方:最近一次运行、最近 24 次运行的结果条(按成败着色,悬停看时间与耗时)和近 14 天成功率。同一行的卡片等高。`j/k` 按页面顺序切换选中卡片,`r` 运行,`e` 编辑。
  - **分组**:工具栏「新建分组」;卡片的「分组」菜单把工作流移到某个分组、移回「未分组」,或新建分组并移入。分组标题行可收起/展开、上移/下移(调整分组顺序)、重命名、删除(点两次;其中的工作流回到「未分组」,工作流本身不受影响)。选中卡片后按 `[` / `]` 把它移到上一个/下一个分组。Tern 没有通用的拖拽事件,所以移动用菜单、按钮和按键完成。分组存在 `groups.json`;改工作流 id 时分组跟着走,删除工作流时一并移除;文件损坏时面板报错并拒绝覆盖它。

面板全部由 Tern 原生元素绘制(表格、分栏、图表、ANSI 日志、状态徽章),视图按节点 key 增量更新,日志只发送追加部分。`roost.css` 顶部列出了所有 `data-role` 钩子;在 `plugin-data/roost/theme.css` 中写样式即可覆盖,保存后实时生效,插件目录不会被改动。

## 开发

```sh
tern plugin link .
scripts/check.sh            # luau-lsp 严格检查、Luau 测试、cargo fmt/clippy/test、记忆预算
python3 tests/run.py        # 只跑 Luau 测试
```
