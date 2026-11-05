---
description: Rust 生产代码禁止 panic 路径
condition: "(\\.unwrap\\(\\)|\\.expect\\(|\\bpanic!\\s*\\(|\\btodo!\\s*\\(|\\bunimplemented!\\s*\\(|\\bunreachable!\\s*\\(|\\bdbg!\\s*\\()"
scope: "tool:edit(*.rs), tool:write(*.rs)"
interruptMode: never
---
如果刚写的代码属于生产路径(不在 `#[cfg(test)]`/`tests/` 中),panic 会直接让 sidecar 进程退出,插件侧只能拿到 `status ~= 0` 和一段 stderr。

- 用 `?` 加 `Result<_, E>` 把错误向上传递;在边界处(`main`/命令入口)统一转成结构化的错误输出,例如 `{"ok":false,"error":…}`,然后以非 0 码退出。
- `Option` 用 `ok_or(...)`/`ok_or_else(...)` 转成错误;下标访问改用 `.get(i)`;字符串切片改用 `.get(a..b)`,否则在非字符边界处会 panic。
- 真正不可能发生的分支,也要返回错误,而不是 `unreachable!`。
- 测试代码可以使用这些写法,`clippy.toml` 已对测试豁免。

`scripts/check.sh` 中的 clippy(规则在 `.cargo/config.toml`)会把这些用法当作错误拦截。
