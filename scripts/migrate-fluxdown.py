#!/usr/bin/env python3
"""把 FluxDown 流水线迁到 Roost 管理的文件库。

plugin-data/roost/scripts/ 下的脚本和提示词移到文件库 library/fluxdown/(运行时经
$ROOST_LIB 取得副本),状态目录 fluxdown-issues/ 移到 state/fluxdown/(经 $ROOST_STATE),
四个工作流的 run 步骤改为 file 步骤。幂等:再跑一次不重复迁移。

有排队或正在执行的 fluxdown 运行时拒绝执行(它们的步骤还指向旧路径)。
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.home() / "Library/Application Support/Tern/plugin-data/roost"
LIB = ROOT / "library" / "fluxdown"
STATE = ROOT / "state" / "fluxdown"
OLD_SCRIPTS = ROOT / "scripts"
OLD_STATE = ROOT / "fluxdown-issues"

FILES = {
    "fluxdown-issues.py": "issues.py",
    "fluxdown-i18n.py": "i18n.py",
}
PROMPTS = ("triage.md", "verify.md", "fix.md", "review.md", "gate.md")

# 旧的 run 步骤(命令里带脚本路径)→ 文件步骤。按命令中的子命令匹配,避免误伤。
STEPS = {
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-i18n.py" scan': ("@fluxdown/i18n.py", ["scan"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-i18n.py" apply': ("@fluxdown/i18n.py", ["apply"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" triage-scan': ("@fluxdown/issues.py", ["triage-scan"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" triage-route': ("@fluxdown/issues.py", ["triage-route"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" triage-apply': ("@fluxdown/issues.py", ["triage-apply"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" fix-pick': ("@fluxdown/issues.py", ["fix-pick"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" fix-check': ("@fluxdown/issues.py", ["fix-check"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" fix-publish': ("@fluxdown/issues.py", ["fix-publish"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" gate': ("@fluxdown/issues.py", ["gate"]),
    'python3 "$ROOST_RUN_DIR/../../scripts/fluxdown-issues.py" gate-record': ("@fluxdown/issues.py", ["gate-record"]),
}

PATHS = '''DATA = Path(os.environ.get("ROOST_RUN_DIR", ".")).resolve().parents[1]
HOME = DATA / "fluxdown-issues"
STATE = HOME / "state.json"
RUN_ID = re.sub(r"[^\\w-]", "_", os.environ.get("ROOST_RUN_ID") or "manual")
CTRL = HOME / "runs" / RUN_ID
PROMPTS = DATA / "scripts" / "fluxdown-issues"'''

PATHS_NEW = '''# 由 Roost 在运行开始时准备:状态目录跨运行保留,文件库是本次运行的副本。
HOME = Path(os.environ["ROOST_STATE"])
STATE = HOME / "state.json"
RUN_ID = re.sub(r"[^\\w-]", "_", os.environ.get("ROOST_RUN_ID") or "manual")
CTRL = HOME / "runs" / RUN_ID
PROMPTS = Path(os.environ["ROOST_LIB"]) / "fluxdown"'''


def live_runs() -> list[str]:
    runs = json.loads((ROOT / "runs.json").read_text(encoding="utf-8"))
    return [f"{r['id']} {r['workflow']} {r['state']}" for r in runs
            if r.get("workflow", "").startswith("fluxdown-") and r.get("state") in ("queued", "running")]


def toml_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def rewrite_workflows(text: str) -> tuple[str, int]:
    """run 步骤换成 file 步骤;四个工作流加上 state 与 libs。已迁移过的文件原样返回(0 处)。"""
    if all(f"file = {toml_quote(f)}" in text for f, _ in STEPS.values()) and not any(
        f"run = '{old}'" in text for old in STEPS
    ):
        return text, 0
    n = 0
    for old, (file, args) in STEPS.items():
        pat = re.compile(r"run = '" + re.escape(old) + r"'")
        repl = "file = " + toml_quote(file) + "\nargs = [" + ", ".join(toml_quote(a) for a in args) + "]"
        text, k = pat.subn(repl, text)
        if k != 1:
            raise SystemExit(f"期望恰好 1 处 `{old}`,实际 {k} 处;没有做任何修改")
        n += k
    for wf in ("fluxdown-i18n", "fluxdown-issue-triage", "fluxdown-issue-fix", "fluxdown-merge-gate"):
        header = f'id = "{wf}"\n'
        if header + 'state = "fluxdown"\nlibs = ["fluxdown"]\n' in text:
            continue
        if header not in text:
            raise SystemExit(f"找不到工作流 {wf};没有做任何修改")
        text = text.replace(header, header + 'state = "fluxdown"\nlibs = ["fluxdown"]\n', 1)
    # 描述里指向旧位置的说明
    text = text.replace("确定性部分在 plugin-data/roost/scripts/fluxdown-i18n.py。", "确定性部分在文件库 fluxdown 的 i18n.py。")
    text = text.replace(
        "确定性部分在 plugin-data/roost/scripts/fluxdown-issues.py,提示词在 scripts/fluxdown-issues/。",
        "确定性部分和提示词在文件库 fluxdown(issues.py、*.md)。",
    )
    return text, n


def main() -> int:
    live = live_runs()
    if live:
        print("有正在执行的 FluxDown 运行,等它们结束后再迁移:")
        print("\n".join("  " + s for s in live))
        return 1

    # 1. 先在内存里算好全部结果:任何一处对不上就退出,磁盘上什么都不动。
    wf = ROOT / "workflows.toml"
    old_text = wf.read_text(encoding="utf-8")
    new_text, n = rewrite_workflows(old_text)

    writes: list[tuple[Path, str]] = []  # 文件库里新增的文件(已存在的一律不覆盖)
    for src_name, dst_name in FILES.items():
        src, dst = OLD_SCRIPTS / src_name, LIB / dst_name
        if dst.exists():
            print(f"文件库已有 {dst_name},保留(不覆盖)")
        elif src.exists():
            text = src.read_text(encoding="utf-8")
            if src_name == "fluxdown-issues.py":
                if PATHS not in text:
                    raise SystemExit("issues.py 里找不到预期的路径常量,脚本已被手改?没有做任何修改")
                text = text.replace(PATHS, PATHS_NEW, 1)
            writes.append((dst, text))
        else:
            raise SystemExit(f"缺少 {src} 与 {dst};没有做任何修改")
    for name in PROMPTS:
        src, dst = OLD_SCRIPTS / "fluxdown-issues" / name, LIB / name
        if dst.exists():
            print(f"文件库已有 {name},保留(不覆盖)")
        elif src.exists():
            writes.append((dst, src.read_text(encoding="utf-8")))
        else:
            raise SystemExit(f"缺少提示词 {src};没有做任何修改")

    # 2. 写文件库 → 搬状态 → 最后改 workflows.toml(出问题时旧步骤仍指向旧位置,旧脚本仍可用)。
    LIB.mkdir(parents=True, exist_ok=True)
    for dst, text in writes:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(text, encoding="utf-8")
        print(f"文件库: {dst.relative_to(ROOT)}")

    if n > 0 and OLD_STATE.exists():
        STATE.mkdir(parents=True, exist_ok=True)
        for child in OLD_STATE.iterdir():
            target = STATE / child.name
            if target.exists():
                print(f"状态已存在,跳过: {child.name}")
                continue
            shutil.move(str(child), str(target))
            print(f"状态: {child.name} → state/fluxdown/")
        if not any(OLD_STATE.iterdir()):
            OLD_STATE.rmdir()

    if n == 0:
        print("workflows.toml 已经是文件步骤,无需改动")
        return 0
    bak = wf.with_suffix(".toml.pre-files.bak")
    if not bak.exists():
        bak.write_text(old_text, encoding="utf-8")
    wf.write_text(new_text, encoding="utf-8")
    print(f"工作流: {n} 个步骤改为 file 步骤,已备份 {bak.name}")
    print("确认 Roost 重载无误后,可删除 plugin-data/roost/scripts/(含 __pycache__)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
