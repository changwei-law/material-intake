#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""材料代办录入 · 命令行工具（仅用 Python 标准库）。

子命令：
  doctor        环境与配置诊断
  init-config   生成配置模板
  init          新建任务目录与录入台账
  scan          逐件哈希、判定类型、检出批内重复
  dedupe        与既有库比对，排查重复
  archive       归档到白名单目录并登记归档台账（缺省只预演）

设计约束：不删除任何文件；不覆盖同名文件；只允许写入配置中的白名单根目录。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

SKILL_DIR = Path(__file__).resolve().parent.parent
ASSETS_DIR = SKILL_DIR / "assets"
DEFAULT_CONFIG_PATH = Path.home() / ".material-intake" / "config.json"
DEFAULT_DIRS = {
    "inbox": "待处理",
    "work": "代办录入",
    "processed": "已处理",
    "pending": "待归档",
}
TYPE_MAP = {
    ".pdf": "pdf",
    ".doc": "docx",
    ".docx": "docx",
    ".xls": "xlsx",
    ".xlsx": "xlsx",
    ".csv": "表格",
    ".txt": "文本",
    ".md": "文本",
    ".jpg": "图片",
    ".jpeg": "图片",
    ".png": "图片",
    ".heic": "图片",
    ".zip": "压缩包",
    ".rar": "压缩包",
    ".7z": "压缩包",
    ".mp3": "录音",
    ".mp4": "视频",
    ".wav": "录音",
}
CHUNK = 1024 * 1024

# 权限被系统拦下时的可执行提示（macOS 的文件与文件夹隐私保护最常触发）。
FILE_PERMISSION_HINT = (
    "提示：macOS 可能拦住了对该目录的访问。到「系统设置 → 隐私与安全性 → 文件与文件夹」为当前应用"
    "（Codex／WorkBuddy／千问办公／常威律师 DSH）放行，跨目录批量操作时可能需要开「完全磁盘访问权限」；"
    "Windows 上多半是文件被其他程序占用或当前账户权限不足。改完重试。"
)
# 扫描时被跳过的不可读路径，由调用方汇总提示。
SKIPPED_PATHS: List[str] = []


# ---------------------------------------------------------------- 基础工具


def emit_json(payload: object) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def fail(message: str, code: int = 1) -> "None":
    print("错误：" + message, file=sys.stderr)
    raise SystemExit(code)


def human_size(num: int) -> str:
    value = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return ("%.0f %s" % (value, unit)) if unit in ("B", "KB") else ("%.1f %s" % (value, unit))
        value /= 1024
    return "%.1f TB" % value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def guess_type(path: Path) -> str:
    return TYPE_MAP.get(path.suffix.lower(), "其他")


def is_noise(path: Path) -> bool:
    name = path.name
    return name.startswith("._") or name in {".DS_Store", "Thumbs.db", "desktop.ini"}


def collect_files(target: Path) -> List[Path]:
    if not target.exists():
        return []
    if target.is_file():
        return [target]
    found: List[Path] = []

    def on_error(err: OSError) -> None:
        # 目录读不进去（多为权限拦截）时记下路径，由调用方提示，不静默跳过。
        SKIPPED_PATHS.append(str(getattr(err, "filename", "") or err))

    for root, dirs, files in os.walk(str(target), onerror=on_error):
        dirs[:] = [d for d in sorted(dirs) if not d.startswith(".")]
        for name in sorted(files):
            item = Path(root) / name
            if is_noise(item):
                continue
            if not os.access(str(item), os.R_OK):
                SKIPPED_PATHS.append(str(item))
                continue
            found.append(item)
    return found


def sanitize_slug(text: str) -> str:
    slug = (text or "").strip().replace("　", " ")
    slug = re.sub(r"[\s/\\:：*?\"<>|]+", "-", slug)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug or "未命名任务"


def resolve_under(path: Path, roots: Sequence[Path]) -> bool:
    target = Path(path).expanduser().resolve()
    for root in roots:
        base = Path(root).expanduser().resolve()
        if target == base or base in target.parents:
            return True
    return False


# ---------------------------------------------------------------- 配置


def config_candidates(explicit: Optional[str]) -> List[Path]:
    candidates: List[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    env_path = os.environ.get("MATERIAL_INTAKE_CONFIG")
    if env_path:
        candidates.append(Path(env_path).expanduser())
    candidates.append(Path.cwd() / ".material-intake.json")
    candidates.append(DEFAULT_CONFIG_PATH)
    return candidates


def load_config(explicit: Optional[str]) -> Tuple[Optional[dict], Optional[Path]]:
    for candidate in config_candidates(explicit):
        if candidate.is_file():
            try:
                with candidate.open(encoding="utf-8-sig") as handle:
                    return json.load(handle), candidate
            except json.JSONDecodeError as exc:
                fail("配置文件不是合法 JSON：%s（%s）" % (candidate, exc))
    return None, None


def config_dirs(config: Optional[dict]) -> Dict[str, str]:
    merged = dict(DEFAULT_DIRS)
    if config and isinstance(config.get("dirs"), dict):
        for key, value in config["dirs"].items():
            if isinstance(value, str) and value.strip():
                merged[key] = value.strip()
    return merged


def config_list(config: Optional[dict], key: str) -> List[str]:
    if not config:
        return []
    value = config.get(key)
    if isinstance(value, list):
        return [str(item) for item in value if str(item).strip()]
    return []


def workspace_of(config: Optional[dict], override: Optional[str]) -> Optional[Path]:
    raw = override or (config or {}).get("workspace")
    if not raw:
        return None
    return Path(str(raw)).expanduser().resolve()


def ledger_of(config: Optional[dict], workspace: Optional[Path], override: Optional[str]) -> Optional[Path]:
    if override:
        return Path(override).expanduser().resolve()
    name = (config or {}).get("archive_ledger") or "归档台账.md"
    if not workspace:
        return None
    path = Path(str(name)).expanduser()
    return path if path.is_absolute() else (workspace / path)


def asset_text(name: str, fallback: str) -> str:
    path = ASSETS_DIR / name
    if path.is_file():
        return path.read_text(encoding="utf-8-sig")
    return fallback


# ---------------------------------------------------------------- doctor


def cmd_doctor(args: argparse.Namespace) -> int:
    print("材料代办录入 · 环境诊断")
    print("  脚本位置 ：%s" % Path(__file__).resolve())
    print("  技能目录 ：%s" % SKILL_DIR)
    print("  Python  ：%s（%s %s）" % (platform.python_version(), platform.system(), platform.release()))
    print("  运行目录 ：%s" % Path.cwd())
    print("")

    searched = config_candidates(args.config)
    config, config_path = load_config(args.config)
    if config_path:
        print("配置文件：%s" % config_path)
    else:
        print("配置文件：未找到，已按顺序查找下列位置")
        for candidate in searched:
            print("  - %s%s" % (candidate, "（存在）" if candidate.exists() else ""))
        print("  → 用 init-config 生成模板后填写")

    problems: List[str] = []
    if not config_path:
        problems.append("未找到配置文件，先运行 init-config 生成模板")
    if config_path:
        workspace = workspace_of(config, args.workspace)
        if not workspace:
            problems.append("配置缺少 workspace")
        elif not workspace.is_dir():
            problems.append("workspace 目录不存在：%s" % workspace)
        else:
            dirs = config_dirs(config)
            print("工作区  ：%s" % workspace)
            for key, label in (("inbox", "收件"), ("work", "任务"), ("processed", "已处理"), ("pending", "待归档")):
                sub = workspace / dirs[key]
                status = "存在" if sub.is_dir() else "缺失"
                print("  %-6s %s（%s）" % (label, sub, status))
                if not sub.is_dir():
                    problems.append("工作区子目录缺失：%s" % sub)
            ledger = ledger_of(config, workspace, args.ledger)
            if ledger and ledger.is_file():
                print("归档台账：%s" % ledger)
            else:
                print("归档台账：缺失（%s）" % ledger)
                problems.append("归档台账缺失：%s" % ledger)

        roots = config_list(config, "allowed_roots")
        if roots:
            for root in roots:
                ok = Path(root).expanduser().is_dir()
                print("允许根目录：%s（%s）" % (root, "存在" if ok else "不存在"))
                if not ok:
                    problems.append("allowed_roots 指向的目录不存在：%s" % root)
        else:
            print("允许根目录：未配置 → archive 将拒绝执行")
            problems.append("allowed_roots 未配置，归档不可用")

        destinations = config.get("destinations")
        print("去向对照：%s 条" % (len(destinations) if isinstance(destinations, list) else 0))

    print("")
    print("可选能力（缺省走人工或降级处理）：")
    for module, purpose in (
        ("docx", "Word 解析"),
        ("openpyxl", "Excel 解析"),
        ("fitz", "PDF 页级处理"),
        ("pdfplumber", "PDF 文本抽取"),
        ("easyocr", "扫描件 OCR"),
        ("PIL", "图片处理"),
    ):
        try:
            __import__(module)
            print("  可用   %-12s %s" % (module, purpose))
        except Exception:
            print("  未安装 %-12s %s" % (module, purpose))

    print("")
    if problems:
        print("结论：还有 %d 项待处理" % len(problems))
        for item in problems:
            print("  - %s" % item)
    else:
        print("结论：配置完整，可以开工")
    print("")
    print("本技能需要的系统授权（本模块只在本机读写，不联网；Windows 钉钉通道的联网说明见 安装说明）：")
    print("  1. 读取受保护目录：工作区或案件库若在桌面／文稿／下载等位置，macOS 会拦读取，")
    print("     到「系统设置 → 隐私与安全性 → 文件与文件夹」放行（跨目录批量操作可能要开「完全磁盘访问权限」）")
    print("  2. 写入系统「日历」「提醒事项」：仅日程写入模块需要，入口同上 → 日历／提醒事项，权限选「完全访问」")
    print("  3. 宿主沙箱的可写范围：WorkBuddy／千问办公归档到工作区以外的目录时，需先在宿主设置中放行")
    print("  归档写入本技能自己的白名单目录不需要任何系统授权；Windows 上除日历外无其他授权要求。")
    emit_json({"ok": not problems, "config": str(config_path) if config_path else None, "problems": problems})
    return 0 if not problems else 2


# ---------------------------------------------------------------- init-config


def cmd_init_config(args: argparse.Namespace) -> int:
    out = Path(args.out).expanduser() if args.out else DEFAULT_CONFIG_PATH
    if out.exists() and not args.force:
        fail("配置文件已存在，未覆盖：%s（需要重写时加 --force）" % out)
    template = json.loads(asset_text("config.example.json", "{}") or "{}")
    if args.workspace:
        template["workspace"] = str(Path(args.workspace).expanduser().resolve())
    template.setdefault("dirs", dict(DEFAULT_DIRS))
    if not template.get("allowed_roots"):
        template["allowed_roots"] = []
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(template, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("已生成配置模板：%s" % out)
    print("请填写 workspace、allowed_roots 与 destinations，然后运行 doctor 复查。")
    emit_json({"config": str(out), "applied": True})
    return 0


# ---------------------------------------------------------------- init


def cmd_init(args: argparse.Namespace) -> int:
    config, config_path = load_config(args.config)
    workspace = workspace_of(config, args.workspace)
    if not workspace:
        fail("未确定工作区：请先 init-config 填写 workspace，或用 --workspace 指定")
    if not workspace.is_dir():
        if not args.create_workspace:
            fail(
                "工作区目录不存在：%s\n"
                "  如需代建，加 --create-workspace：将创建该目录、四个子目录与归档台账" % workspace
            )
        # 代建：只新建目录与台账模板，不动任何既有内容。
        dirs_created = config_dirs(config)
        for key in ("inbox", "work", "processed", "pending"):
            (workspace / dirs_created[key]).mkdir(parents=True, exist_ok=True)
        # init 子命令没有 --ledger 参数，用 getattr 兜住，避免代建时报 AttributeError。
        workspace_ledger = ledger_of(config, workspace, getattr(args, "ledger", None))
        if workspace_ledger and not workspace_ledger.exists():
            workspace_ledger.parent.mkdir(parents=True, exist_ok=True)
            workspace_ledger.write_text(asset_text("归档台账模板.md", "# 归档台账\n"), encoding="utf-8")
        print("已创建工作区：%s" % workspace)

    stamp = args.date or datetime.now().strftime("%Y%m%d")
    if not re.fullmatch(r"\d{8}", stamp):
        fail("日期格式应为 YYYYMMDD，收到：%s" % stamp)
    slug = sanitize_slug(args.task)
    dirs = config_dirs(config)
    task_dir = workspace / dirs["work"] / ("%s-%s" % (stamp, slug))
    if task_dir.exists() and not args.force:
        fail("任务目录已存在，未改动：%s（确需复用加 --force）" % task_dir)

    source_dir = task_dir / "源文件"
    output_dir = task_dir / "产出"
    created = datetime.now().strftime("%Y-%m-%d %H:%M")
    ledger_path = task_dir / "录入台账.md"

    if args.apply:
        source_dir.mkdir(parents=True, exist_ok=True)
        output_dir.mkdir(parents=True, exist_ok=True)
        if not ledger_path.exists():
            body = asset_text(
                "录入台账模板.md",
                "# 录入台账｜{TASK}\n\n- 任务建立：{CREATED}\n- 来源：{SOURCE}\n- 处理人：{OPERATOR}\n- 当前状态：待处理\n",
            )
            body = (
                body.replace("{TASK}", "%s-%s" % (stamp, slug))
                .replace("{CREATED}", created)
                .replace("{SOURCE}", args.source or "待补充")
                .replace("{OPERATOR}", args.operator or "来福")
            )
            ledger_path.write_text(body, encoding="utf-8")
    payload = {
        "task_dir": str(task_dir),
        "source_dir": str(source_dir),
        "output_dir": str(output_dir),
        "ledger": str(ledger_path),
        "config": str(config_path) if config_path else None,
        "applied": bool(args.apply),
    }
    if args.apply:
        print("已建立任务目录：%s" % task_dir)
    else:
        print("预演（未写入，加 --apply 执行）：将建立任务目录 %s" % task_dir)
    emit_json(payload)
    return 0


# ---------------------------------------------------------------- scan


def scan_payload(src: Path) -> dict:
    files = collect_files(src)
    rows = []
    for item in files:
        digest = sha256_file(item)
        stat = item.stat()
        rows.append(
            {
                "name": item.name,
                "path": str(item),
                "rel": str(item.relative_to(src if src.is_dir() else src.parent)),
                "type": guess_type(item),
                "size": stat.st_size,
                "size_human": human_size(stat.st_size),
                "mtime": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
                "sha256": digest,
            }
        )
    seen: Dict[str, List[str]] = {}
    for row in rows:
        seen.setdefault(row["sha256"], []).append(row["name"])
    duplicates = [{"sha256": key, "files": value} for key, value in seen.items() if len(value) > 1]
    return {"src": str(src), "count": len(rows), "files": rows, "duplicates": duplicates}


def cmd_scan(args: argparse.Namespace) -> int:
    src = Path(args.src).expanduser()
    if not src.exists():
        fail("路径不存在：%s" % src)
    payload = scan_payload(src)
    print("扫描：%s（%d 件）" % (payload["src"], payload["count"]))
    print("")
    print("| 序号 | 文件 | 类型 | 大小 | 修改时间 | SHA256（前12） |")
    print("|---|---|---|---|---|---|")
    for index, row in enumerate(payload["files"], start=1):
        print(
            "| %d | `%s` | %s | %s | %s | `%s` |"
            % (index, row["name"], row["type"], row["size_human"], row["mtime"], row["sha256"][:12])
        )
    if payload["duplicates"]:
        print("")
        print("批内重复（同一 SHA256）：")
        for group in payload["duplicates"]:
            print("  - %s…%s ：%s" % (group["sha256"][:8], group["sha256"][-5:], "、".join(group["files"])))
    else:
        print("")
        print("批内无重复。")
    emit_json(payload)
    return 0


# ---------------------------------------------------------------- dedupe


def cmd_dedupe(args: argparse.Namespace) -> int:
    config, _ = load_config(args.config)
    src = Path(args.src).expanduser()
    if not src.exists():
        fail("路径不存在：%s" % src)
    roots = [Path(item).expanduser() for item in (args.root or config_list(config, "dedupe_roots"))]
    if not roots:
        fail("未指定查重范围：用 --root 指定库根，或在配置中填写 dedupe_roots")
    for root in roots:
        if not root.is_dir():
            fail("查重范围不存在或不是目录：%s" % root)

    sources = collect_files(src)
    if not sources:
        fail("待查路径下没有可读取的文件：%s" % src)
    wanted_size: Dict[int, List[dict]] = {}
    for item in sources:
        size = item.stat().st_size
        wanted_size.setdefault(size, []).append(
            {"path": item, "name": item.name, "sha256": sha256_file(item), "size": size}
        )

    scoped = {size: [row["sha256"] for row in rows] for size, rows in wanted_size.items()}
    scanned = 0
    matches = []
    for root in roots:
        for candidate in collect_files(root):
            try:
                size = candidate.stat().st_size
            except OSError:
                continue
            if size not in scoped:
                continue
            scanned += 1
            digest = sha256_file(candidate)
            if digest in scoped[size]:
                for row in wanted_size[size]:
                    if row["sha256"] == digest:
                        matches.append(
                            {
                                "source": str(row["path"]),
                                "match": str(candidate),
                                "size_human": human_size(size),
                                "sha256": digest,
                            }
                        )
    print("查重：来源 %d 件，范围内同尺寸候选 %d 件，命中重复 %d 处" % (len(sources), scanned, len(matches)))
    for hit in matches:
        print("  - %s …%s %s" % (hit["sha256"][:8], hit["sha256"][-5:], hit["size_human"]))
        print("      来源：%s" % hit["source"])
        print("      已有：%s" % hit["match"])
    if not matches:
        print("  未发现重复，可继续归档。")
    emit_json({"sources": [str(item) for item in sources], "matches": matches})
    return 0


# ---------------------------------------------------------------- archive


def append_ledger(ledger: Path, row: str) -> None:
    if ledger.is_file():
        lines = ledger.read_text(encoding="utf-8-sig").splitlines()
    else:
        lines = asset_text("归档台账模板.md", "# 归档台账\n").splitlines()
    insert_at = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("|") and stripped.strip("|-: ") == "" and "-" in stripped:
            insert_at = index
            break
    if insert_at is None:
        lines.append(row)
    else:
        lines.insert(insert_at + 1, row)
    ledger.parent.mkdir(parents=True, exist_ok=True)
    ledger.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")


def cell(text: str) -> str:
    return re.sub(r"[|\r\n]+", " ", str(text)).strip()


def cmd_archive(args: argparse.Namespace) -> int:
    config, _ = load_config(args.config)
    sources = [Path(item).expanduser() for item in args.src]
    missing = [str(item) for item in sources if not item.exists()]
    if missing:
        fail("来源不存在：%s" % "、".join(missing))

    dest_dir = Path(args.dest).expanduser()
    if dest_dir.exists() and not dest_dir.is_dir():
        fail("归档目标不是目录：%s" % dest_dir)

    roots = [Path(item).expanduser() for item in (args.root or config_list(config, "allowed_roots"))]
    if not roots:
        fail("未配置允许根目录：请在配置中填写 allowed_roots，或用 --root 显式指定")
    if not resolve_under(dest_dir, roots):
        fail("归档目标不在允许范围内：%s\n允许根目录：%s" % (dest_dir, "、".join(str(item) for item in roots)))

    ledger = ledger_of(config, workspace_of(config, args.workspace), args.ledger)
    stamp = args.date or datetime.now().strftime("%Y-%m-%d")
    plan = []
    for item in sources:
        if item.is_dir():
            fail("暂不支持整目录归档，请先打包或逐个指定：%s" % item)
        target = dest_dir / item.name
        action = "move" if args.move else "copy"
        if target.exists():
            if args.rename:
                suffix = datetime.now().strftime("%Y%m%d-%H%M%S")
                target = dest_dir / ("%s-%s%s" % (item.stem, suffix, item.suffix))
            else:
                fail("目标已存在，未覆盖：%s（另存请加 --rename）" % target)
        plan.append({"source": str(item), "target": str(target), "action": action})

    if not args.apply:
        print("预演（未写入，确认后加 --apply）：")
        for row in plan:
            print("  %s → %s（%s）" % (row["source"], row["target"], "移动" if row["action"] == "move" else "复制"))
        if ledger:
            print("  归档台账：将追加 1 行 → %s" % ledger)
        emit_json({"applied": False, "plan": plan, "ledger": str(ledger) if ledger else None})
        return 0

    dest_dir.mkdir(parents=True, exist_ok=True)
    done = []
    for row in plan:
        source = Path(row["source"])
        target = Path(row["target"])
        before = sha256_file(source)
        if row["action"] == "move":
            shutil.move(str(source), str(target))
        else:
            shutil.copy2(str(source), str(target))
        after = sha256_file(target)
        if before != after:
            fail("写入校验失败，哈希不一致：%s" % target)
        done.append({"source": row["source"], "target": row["target"], "sha256": after, "action": row["action"]})

    if ledger:
        for row in done:
            material = "%s（%s）" % (Path(row["target"]).name, human_size(Path(row["target"]).stat().st_size))
            note = "；".join(
                part
                for part in [
                    args.note or "",
                    "SHA256 `%s…%s`" % (row["sha256"][:8], row["sha256"][-5:]),
                    (args.source_note or "由材料代办录入技能归档"),
                ]
                if part
            )
            append_ledger(
                ledger,
                "| %s | %s | %s | %s | %s | %s |"
                % (
                    cell(stamp),
                    cell(args.origin or "本次收件"),
                    cell(material),
                    cell(str(Path(row["target"]).parent)),
                    cell(args.status),
                    cell(note),
                ),
            )
        print("已登记归档台账：%s" % ledger)
    for row in done:
        print("已归档：%s → %s" % (row["source"], row["target"]))
    emit_json({"applied": True, "done": done, "ledger": str(ledger) if ledger else None})
    return 0


# ---------------------------------------------------------------- 入口


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="material_intake", description="材料代办录入工具（不删原件、不覆盖、白名单内写入）")
    parser.add_argument("--config", help="配置文件路径，缺省按约定顺序查找")
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="环境与配置诊断")
    doctor.add_argument("--workspace", help="临时指定工作区")
    doctor.add_argument("--ledger", help="临时指定归档台账路径")
    doctor.set_defaults(func=cmd_doctor)

    init_config = sub.add_parser("init-config", help="生成配置模板")
    init_config.add_argument("--out", help="输出路径，缺省 ~/.material-intake/config.json")
    init_config.add_argument("--workspace", help="预填工作区路径")
    init_config.add_argument("--force", action="store_true", help="已有配置时覆盖")
    init_config.set_defaults(func=cmd_init_config)

    init = sub.add_parser("init", help="新建任务目录与录入台账")
    init.add_argument("--task", required=True, help="任务简称，如 张某代位权开庭传票")
    init.add_argument("--date", help="任务日期 YYYYMMDD，缺省今天")
    init.add_argument("--source", help="材料来源说明")
    init.add_argument("--operator", help="处理人，缺省 来福")
    init.add_argument("--workspace", help="临时指定工作区")
    init.add_argument("--create-workspace", action="store_true",
                      help="工作区不存在时自动创建（含四个子目录与归档台账模板）")
    init.add_argument("--force", action="store_true", help="任务目录已存在时复用")
    init.add_argument("--apply", action="store_true", help="真正写入，缺省只预演")
    init.set_defaults(func=cmd_init)

    scan = sub.add_parser("scan", help="逐件哈希、判定类型、检出批内重复")
    scan.add_argument("--src", required=True, help="待扫描的文件或目录")
    scan.set_defaults(func=cmd_scan)

    dedupe = sub.add_parser("dedupe", help="与既有库比对排查重复")
    dedupe.add_argument("--src", required=True, help="待查文件或目录")
    dedupe.add_argument("--root", action="append", help="查重范围，可重复", default=None)
    dedupe.set_defaults(func=cmd_dedupe)

    archive = sub.add_parser("archive", help="归档并登记台账（缺省只预演）")
    archive.add_argument("--src", action="append", required=True, help="待归档文件，可重复")
    archive.add_argument("--dest", required=True, help="目标目录，必须落在允许根目录内")
    archive.add_argument("--ledger", help="归档台账路径，缺省取配置")
    archive.add_argument("--workspace", help="临时指定工作区")
    archive.add_argument("--root", action="append", help="允许根目录，可重复（覆盖配置）")
    archive.add_argument("--origin", help="台账「来源」列，如「微信收到截图」")
    archive.add_argument("--note", help="台账备注")
    archive.add_argument("--source-note", help="追加在备注末尾的补充说明")
    archive.add_argument("--status", default="已归档", help="台账状态列，缺省 已归档")
    archive.add_argument("--date", help="台账日期 YYYY-MM-DD，缺省今天")
    archive.add_argument("--move", action="store_true", help="移动而非复制")
    archive.add_argument("--rename", action="store_true", help="目标同名时加时间戳另存")
    archive.add_argument("--apply", action="store_true", help="真正写入，缺省只预演")
    archive.set_defaults(func=cmd_archive)
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        code = args.func(args)
    except OSError as exc:
        target = getattr(exc, "filename", "") or ""
        detail = "（%s）" % exc.strerror if getattr(exc, "strerror", None) else ""
        fail("文件访问失败：%s%s\n%s" % (target, detail, FILE_PERMISSION_HINT))
    if SKIPPED_PATHS:
        print("")
        print("注意：以下路径无法读取，已跳过（不计入本次结果）：")
        for item in SKIPPED_PATHS:
            print("  - %s" % item)
        print(FILE_PERMISSION_HINT)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
