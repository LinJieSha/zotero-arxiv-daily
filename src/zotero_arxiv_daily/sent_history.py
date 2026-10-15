"""已推送论文历史（sent history）：跨 run 去重的持久层。

问题：流水线本身不记得推过什么 —— feed/API 每次只按时间窗口取，无法区分
"这批论文上一封邮件已经推过"和"这是没推过的新论文"。回看窗口（max_lookback_hours）
只防"同一批在窗口内重复出现"，防不了"窗口内混着推过与没推过的批次"（例如 72h
宽窗口下，周二批和周四批同时出现在 API 结果里）。

方案：一个 JSON 文件（sent_history.json）记录每个已推送过的 arXiv 论文 ID 与
推送日期。检索层拿它过滤；发信成功后由调用方（executor / workflow）把当次邮件
里的论文 ID 记进去。文件由 GitHub Actions 的 workflow 步骤 commit 回仓库，
下次 run checkout 自然读到 —— 与 keep-alive 的保活 commit 同一机制。

文件格式（保持纯 JSON、无 BOM，Actions runner 是 Linux）：
{
  "version": 1,
  "sent": {
    "2610.12611v1": {"date": "2026-10-16"},
    ...
  }
}
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from loguru import logger

# 历史上限：按每次推送最多 30 篇、每周 2 次，一年约 3000 条；保留 4000 条
# 足以覆盖两年且文件保持在 ~200KB 以下。超出时按日期裁掉最旧的。
MAX_ENTRIES = 4000


def _now_date_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def load_sent_history(path: Path) -> dict[str, Any]:
    """读取历史文件；不存在或损坏时返回空历史（永不抛异常 —— 去重是尽力而为，
    历史文件坏了宁可重推一次，也不能让整条流水线失败）。"""
    if not path.exists():
        return {"version": 1, "sent": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("sent"), dict):
            raise ValueError("unexpected structure")
        return data
    except Exception as exc:
        logger.warning(f"sent history unreadable ({path}: {exc}); starting fresh")
        return {"version": 1, "sent": {}}


def filter_unsent(ids: list[str], history: dict[str, Any]) -> list[str]:
    """从候选 ID 列表中去掉已推送过的。"""
    sent: dict = history.get("sent", {})
    return [i for i in ids if i not in sent]


def record_sent(ids: list[str], history: dict[str, Any], date_str: str | None = None) -> dict[str, Any]:
    """把当次推送的论文 ID 记入历史（返回新历史，不落盘）。"""
    date = date_str or _now_date_str()
    sent: dict = history.setdefault("sent", {})
    for i in ids:
        sent[i] = {"date": date}
    return history


def prune_history(history: dict[str, Any], max_entries: int = MAX_ENTRIES) -> tuple[dict[str, Any], int]:
    """按日期裁剪最旧的条目，返回 (新历史, 裁掉的数量)。"""
    sent: dict = history.get("sent", {})
    if len(sent) <= max_entries:
        return history, 0
    # 按日期排序取最新的 max_entries 条
    ordered = sorted(sent.items(), key=lambda kv: kv[1].get("date", ""), reverse=True)
    kept = dict(ordered[:max_entries])
    removed = len(sent) - len(kept)
    history["sent"] = kept
    return history, removed


def save_sent_history(path: Path, history: dict[str, Any]) -> bool:
    """写回历史文件。失败只告警不抛异常（下次仍能运行，只是丢一次去重机会）。"""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(history, ensure_ascii=False, indent=1), encoding="utf-8")
        return True
    except Exception as exc:
        logger.warning(f"failed to write sent history ({path}: {exc})")
        return False


def paper_id_from_url(url: str) -> str:
    """从 Paper.url / ArxivResult.entry_id 提取稳定 ID（含版本号）。

    entry_id 形如 https://arxiv.org/abs/2610.12611v1 —— arXiv 对同一论文的
    v2 修订会换版本号，视为"没推过"是合理的（修订版可能值得再看一眼），
    因此保留版本号做键。非 arXiv URL 原样返回。
    """
    marker = "arxiv.org/abs/"
    idx = url.find(marker)
    if idx < 0:
        return url
    return url[idx + len(marker):].strip("/")
