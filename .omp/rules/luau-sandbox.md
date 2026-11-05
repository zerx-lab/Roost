---
description: Tern 的 Luau 沙箱中没有 io/os.execute/loadstring/debug,也不能写插件目录
condition:
  - "\\b(os\\.execute|os\\.exit|os\\.remove|os\\.rename|io\\.[a-z]+|loadstring|getfenv|setfenv|debug\\.[a-z]+)\\s*\\("
  - "tern\\.fs\\.(write|mkdir|remove|rename)\\s*\\([^\\n]*tern\\.plugin\\.dir"
scope: "tool:edit(*.luau), tool:write(*.luau)"
interruptMode: always
---
Tern 插件运行在受限的 Luau 沙箱里,与外界交互只能通过 `tern.*`:
- 进程:`tern.process.run(argv, { timeout_ms = … }, cb)`
- 文件:`tern.fs.read/write/exists/mkdir`(用 `pcall` 包裹)
- 网络:`tern.fetch(url, opts, cb)`

`os.execute`、`io.*`、`loadstring`、`debug.*` 等在沙箱里不存在,调用就会报错。

只能写 `tern.plugin.data` 或 `tern.kv`,不要写 `tern.plugin.dir`:插件目录下任何文件变化都会让 Tern 重载全部插件,自升级逻辑如果写进插件目录,会陷入"写入 → 重载 → 再写入"的循环。新版本应该先下载到 data 目录,校验通过后再走受控的替换流程。
