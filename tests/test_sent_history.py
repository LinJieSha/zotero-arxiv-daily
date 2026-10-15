"""sent_history 模块与跨 run 去重的测试。"""

import json
from pathlib import Path

import pytest

from zotero_arxiv_daily.sent_history import (
    filter_unsent,
    load_sent_history,
    paper_id_from_url,
    prune_history,
    record_sent,
    save_sent_history,
)


class TestLoadSave:
    def test_missing_file_returns_empty(self, tmp_path: Path):
        h = load_sent_history(tmp_path / "nope.json")
        assert h == {"version": 1, "sent": {}}

    def test_corrupt_file_returns_empty(self, tmp_path: Path):
        p = tmp_path / "bad.json"
        p.write_text("{not json", encoding="utf-8")
        h = load_sent_history(p)
        assert h == {"version": 1, "sent": {}}

    def test_roundtrip(self, tmp_path: Path):
        p = tmp_path / "h.json"
        h = record_sent(["2610.1v1"], {"version": 1, "sent": {}})
        assert save_sent_history(p, h)
        h2 = load_sent_history(p)
        assert "2610.1v1" in h2["sent"]

    def test_save_failure_returns_false_not_raise(self, tmp_path: Path):
        # 目录路径当文件写 → 触发异常路径而非抛出
        d = tmp_path / "adir"
        d.mkdir()
        assert save_sent_history(d, {"version": 1, "sent": {}}) is False


class TestRecordFilter:
    def test_record_sets_date(self):
        h = record_sent(["a", "b"], {"version": 1, "sent": {}}, date_str="2026-10-16")
        assert h["sent"]["a"]["date"] == "2026-10-16"
        assert h["sent"]["b"]["date"] == "2026-10-16"

    def test_filter_unsent(self):
        h = record_sent(["a", "b"], {"version": 1, "sent": {}})
        assert filter_unsent(["a", "b", "c", "d"], h) == ["c", "d"]

    def test_filter_empty_history(self):
        assert filter_unsent(["a", "b"], {"version": 1, "sent": {}}) == ["a", "b"]


class TestPrune:
    def test_prune_keeps_newest(self):
        h = {"version": 1, "sent": {}}
        for i in range(10):
            h["sent"][f"p{i}"] = {"date": f"2026-10-{i + 1:02d}"}
        h2, removed = prune_history(h, max_entries=5)
        assert removed == 5
        assert len(h2["sent"]) == 5
        assert "p9" in h2["sent"] and "p0" not in h2["sent"]

    def test_prune_noop_under_limit(self):
        h = {"version": 1, "sent": {"x": {"date": "2026-10-16"}}}
        h2, removed = prune_history(h, max_entries=4000)
        assert removed == 0 and h2 is h


class TestPaperId:
    def test_arxiv_url(self):
        assert paper_id_from_url("https://arxiv.org/abs/2610.12611v1") == "2610.12611v1"

    def test_version_distinguishes(self):
        # v2 修订版 ≠ v1：视为未推送（修订值得再看一眼）
        h = record_sent(["2610.1v1"], {"version": 1, "sent": {}})
        assert filter_unsent(["2610.1v2"], h) == ["2610.1v2"]

    def test_non_arxiv_passthrough(self):
        assert paper_id_from_url("https://example.com/x") == "https://example.com/x"


class TestRetrieverDedup:
    """retriever 的 _filter_already_sent 集成测试（不碰网络）。"""

    @pytest.fixture
    def retriever(self):
        from zotero_arxiv_daily.retriever.arxiv_retriever import ArxivRetriever
        from omegaconf import OmegaConf

        cfg = OmegaConf.create(
            {
                "zotero": {"include_path": None, "ignore_path": None},
                "source": {
                    "arxiv": {
                        "category": ["cs.MA"],
                        "include_cross_list": False,
                        "max_lookback_hours": 72,
                        "fallback_api": True,
                        "fallback_max_results": 200,
                    }
                },
                "executor": {"debug": False},
            }
        )
        return ArxivRetriever(cfg)

    @staticmethod
    def _paper(entry_id: str):
        from zotero_arxiv_daily.retriever.arxiv_retriever import _entry_to_arxiv_result

        class E:
            id = f"oai:arXiv.org:{entry_id}"
            title = f"Paper {entry_id}"
            author = "A, B"
            summary = "Announce Type: new\nAbstract: something"
            link = f"https://arxiv.org/abs/{entry_id}"
            tags = [{"term": "cs.MA"}]
            published_parsed = None
            updated_parsed = None
            arxiv_comment = ""
            arxiv_journal_reference = ""
            arxiv_journal_ref = ""
            arxiv_doi = ""
            arxiv_announce_type = "new"

        return _entry_to_arxiv_result(E())

    def test_dedup_filters_sent(self, retriever, tmp_path: Path):
        retriever._sent_history_path = tmp_path / "h.json"
        h = record_sent(["2610.1v1"], {"version": 1, "sent": {}})
        save_sent_history(tmp_path / "h.json", h)
        papers = [self._paper("2610.1v1"), self._paper("2610.2v1")]
        kept = retriever._filter_already_sent(papers)
        assert [p.entry_id for p in kept] == ["https://arxiv.org/abs/2610.2v1"]

    def test_no_history_path_disables_dedup(self, retriever):
        retriever._sent_history_path = None
        papers = [self._paper("2610.1v1")]
        assert retriever._filter_already_sent(papers) == papers

    def test_history_format_is_plain_utf8(self, tmp_path: Path):
        # Actions runner 是 Linux：文件必须是纯 UTF-8 无 BOM、合法 JSON
        p = tmp_path / "h.json"
        h = record_sent(["2610.1v1"], {"version": 1, "sent": {}})
        save_sent_history(p, h)
        raw = p.read_bytes()
        assert not raw.startswith(b"\xef\xbb\xbf")
        json.loads(raw.decode("utf-8"))
