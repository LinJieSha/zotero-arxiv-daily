"""Executor × sent_history 端到端闭环测试：发信成功 → 记录 → 下次检索跳过。

不碰网络：Zotero/邮件/LLM 全部打桩。
"""

import json
from types import SimpleNamespace

from zotero_arxiv_daily.executor import Executor


class _StubRetriever:
    """按脚本注入的候选论文列表返回（带 _sent_history_path 属性）。

    真实流水线里该属性由 Executor.__init__ 注入；测试同样在 Executor 构造后
    补注入，保证 _filter_already_sent 能读到历史文件。
    """

    name = "arxiv"

    def __init__(self, candidates):
        self._candidates = candidates
        self._sent_history_path = None

    def retrieve_papers(self):
        from zotero_arxiv_daily.sent_history import (
            filter_unsent,
            load_sent_history,
            paper_id_from_url,
        )

        if self._sent_history_path is None:
            return list(self._candidates)
        history = load_sent_history(self._sent_history_path)
        kept = [
            p
            for p in self._candidates
            if paper_id_from_url(p.url) in filter_unsent([paper_id_from_url(p.url)], history)
        ]
        return kept


def _paper(url: str):
    return SimpleNamespace(
        source="arxiv",
        title=f"T {url}",
        authors=["A"],
        abstract="abs",
        url=url,
        pdf_url=url,
        full_text=None,
        tldr=None,
        affiliations=None,
        score=1.0,
        generate_tldr=lambda *a, **k: "tldr",
        generate_affiliations=lambda *a, **k: [],
    )


def _make_executor(tmp_path, monkeypatch, candidates, send_email=None):
    from omegaconf import OmegaConf

    cfg = OmegaConf.create(
        {
            "zotero": {"include_path": None, "ignore_path": None},
            "executor": {
                "debug": False,
                "send_empty": False,
                "max_paper_num": 30,
                "source": ["arxiv"],
                "reranker": "local",
                "sent_history_path": str(tmp_path / "sent_history.json"),
            },
            "source": {"arxiv": {"category": ["cs.MA"], "include_cross_list": False}},
            "llm": {"api": {"key": "x", "base_url": "x"}},
        }
    )

    # 打桩所有外部交互
    monkeypatch.setattr(
        "zotero_arxiv_daily.executor.get_retriever_cls",
        lambda name: lambda config: _StubRetriever(candidates),
    )

    class _StubReranker:
        def __init__(self, config):
            pass

        def rerank(self, papers, corpus):
            return papers

    monkeypatch.setattr(
        "zotero_arxiv_daily.executor.get_reranker_cls", lambda name: _StubReranker
    )
    monkeypatch.setattr(
        "zotero_arxiv_daily.executor.render_email", lambda papers: "<html>x</html>"
    )
    sent_emails = []

    def _default_send(config, html):
        sent_emails.append(html)

    monkeypatch.setattr(
        "zotero_arxiv_daily.executor.send_email", send_email or _default_send
    )
    monkeypatch.setattr(
        Executor,
        "fetch_zotero_corpus",
        lambda self: [SimpleNamespace(title="c", abstract="a", added_date=None, paths=[])],
    )

    ex = Executor(cfg)
    return ex, sent_emails


def test_send_then_dedup_roundtrip(tmp_path, monkeypatch):
    """第一次运行发信并记录；第二次运行同样的候选 → 0 篇不发信。"""
    from zotero_arxiv_daily.sent_history import load_sent_history

    candidates = [
        _paper("https://arxiv.org/abs/2610.11111v1"),
        _paper("https://arxiv.org/abs/2610.22222v1"),
    ]

    # 第一次：发信成功
    ex, sent = _make_executor(tmp_path, monkeypatch, candidates)
    ex.run()
    assert len(sent) == 1
    h = load_sent_history(ex.sent_history_path)
    assert set(h["sent"].keys()) == {"2610.11111v1", "2610.22222v1"}

    # 第二次：同样候选 → sent-history 去重后 0 篇 → 不发信
    ex2, sent2 = _make_executor(tmp_path, monkeypatch, candidates)
    ex2.run()
    assert len(sent2) == 0
    # 历史未变（no-papers 不记录）
    h2 = load_sent_history(ex2.sent_history_path)
    assert set(h2["sent"].keys()) == {"2610.11111v1", "2610.22222v1"}


def test_failed_send_does_not_record(tmp_path, monkeypatch):
    """SMTP 抛异常 → 不记入历史（失败重推时论文仍是"未推送"）。"""

    def boom(config, html):
        raise RuntimeError("smtp down")

    candidates = [_paper("https://arxiv.org/abs/2610.33333v1")]
    ex, _ = _make_executor(tmp_path, monkeypatch, candidates, send_email=boom)
    try:
        ex.run()
    except RuntimeError:
        pass
    assert not ex.sent_history_path.exists()


def test_partial_dedup(tmp_path, monkeypatch):
    """候选 = 1 篇已推 + 1 篇新 → 只推新的那篇。"""
    from zotero_arxiv_daily.sent_history import load_sent_history, record_sent, save_sent_history

    # 预置历史：11111 已推过
    ex, _ = _make_executor(tmp_path, monkeypatch, [])
    ex.sent_history = record_sent(["2610.11111v1"], {"version": 1, "sent": {}})
    save_sent_history(ex.sent_history_path, ex.sent_history)

    candidates = [
        _paper("https://arxiv.org/abs/2610.11111v1"),  # 已推
        _paper("https://arxiv.org/abs/2610.44444v1"),  # 新
    ]
    ex2, sent = _make_executor(tmp_path, monkeypatch, candidates)
    ex2.run()
    assert len(sent) == 1
    h = load_sent_history(ex2.sent_history_path)
    assert "2610.44444v1" in h["sent"] and "2610.11111v1" in h["sent"]
