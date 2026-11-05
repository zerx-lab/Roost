---
description: Rust 读取外部输入必须有大小上限,禁止泄漏内存
condition: "(\\bread_to_end\\s*\\(|\\bread_to_string\\s*\\(|\\bfs::read(_to_string)?\\s*\\(|\\bBox::leak\\s*\\(|\\bmem::forget\\s*\\(|\\bVec::with_capacity\\s*\\(|\\bvec!\\[[^\\]]*;\\s*[a-z_][a-z0-9_.]*\\s*\\])"
scope: "tool:edit(*.rs), tool:write(*.rs)"
interruptMode: never
---
核对刚写的 Rust 代码是否会因外部输入导致内存失控:
- **读取有上限**:文件、stdin、网络数据先检查长度(`metadata().len()`),或用 `reader.take(LIMIT)` 后再 `read_to_end`;超出上限返回错误。大文件改为流式或分块处理,不要整个读进内存。
- **容量来自外部时要先限制**:`Vec::with_capacity(n)`、`vec![x; n]` 中的 `n` 如果来自外部(文件头、长度前缀、参数),必须先 `min(n, MAX)`,否则一个恶意长度就能让分配直接失败或被 OOM kill。
- **不泄漏**:不用 `Box::leak` / `mem::forget` 绕过所有权;需要全局状态时用 `std::sync::LazyLock`。
- **缓存有界**:内存里的缓存、队列必须有容量上限或淘汰策略;输出结果写到 `tern.plugin.data`,不要一直留在进程里。
