# Roost 硬规则

## 项目记忆

本项目只用仓库内的 `.omp/memory/` 做记忆。不要使用 omp 用户级记忆(`learn`/`retain`/`manage_skill`、`~/.omp/agent/memories`),也不要把本项目的事实写进用户级 AGENTS.md 或 RULES.md。

文件分三层:
- `MEMORY.md`:精选索引,启动时会注入,上限 150 行;
- `topics/<slug>.md`:单个主题的细节,按需阅读;
- `journal/YYYY-MM.md`:只追加的工作日志,不注入。

使用规则:
- **读**:改动前看 MEMORY.md 中相关的「约束与陷阱」;涉及某个主题时先读对应的 topics 文件。记忆只是线索,与仓库现状或用户指令冲突时,以现状和用户为准,并当场修正那条记忆。
- **写**:只记录长期有效、无法从代码或 git 直接读出的信息,包括用户确认的决策、被否方案及原因、踩过的坑、外部平台事实。每条都要带日期和依据。临时调试状态、推测、密钥、个人偏好一律不写。
- **时机**:做出决策、否掉方案、或解决了一个非显而易见的问题之后,立即写入(用 `/remember`)。每完成一个阶段,往 journal 追加一行。
- **只有主会话能写**。subagent 只读;subagent 有值得记录的发现时,写在返回结果里,由主会话代为写入。
- **维护**:MEMORY.md 超过 150 行或出现重复、过期条目时,运行 `/memory-tidy`。过期条目直接删除或移到「被否方案」,不要留着互相矛盾的内容。

## 运行时红线(Luau / Rust)

- 插件运行时只能写 `tern.plugin.data` 和 `tern.kv`。不要写插件目录:写入会触发 Tern 重载全部插件,自升级逻辑尤其要注意。
- Luau:每次调用必须在预算内返回(host 2 s、window 50 ms)。不要用无界循环,长任务用 `tern.timer` 分片。`tern.process.run` 必须带 `timeout_ms`。可能失败的 I/O 用 `pcall` 包裹。缓存、日志这类表必须有上限(VM 内存上限 256 MiB)。
- Rust:生产代码不允许 `unwrap`/`expect`/`panic!`/`todo!`/下标越界式访问,改为返回 `Result`。外部输入必须限制读取大小(`Read::take`、分块读取)。构建产物不能放在插件目录内。
- 提交前必须跑 `scripts/check.sh`,全部通过才算完成。
