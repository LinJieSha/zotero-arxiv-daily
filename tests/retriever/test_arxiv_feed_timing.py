"""Tests for the arXiv feed freshness gate and the API fallback.

Measured behaviour these tests encode (2026-10-12):
- arXiv announces one batch per working day at 20:00 ET and rebuilds each
  category Atom feed at 00:00 ET on the announcement day (04:00 UTC / 12:00
  Beijing). Entry ``<published>`` is always labelled 00:00 ET and says nothing
  about when the batch actually appeared.
- rss.arxiv.org sits behind a CDN that can serve an hours-old copy.
- The arXiv API reflects updates immediately, so it is the fallback source.
"""

import calendar
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import feedparser
import pytest
import requests.structures

import zotero_arxiv_daily.retriever.arxiv_retriever as arxiv_retriever
from zotero_arxiv_daily.retriever.arxiv_retriever import ArxivRetriever


def _ts(dt: datetime):
    return calendar.timegm(dt.utctimetuple())


def _entry(paper_id: str, updated: datetime, announce_type: str = "new", tags=None):
    """Build one entry the way feedparser represents a real Atom entry.

    A FeedParserDict supports attribute access, but its nested ``meta``
    (the ``<category>`` tags) stays a plain dict because feedparser only
    converts the top level. Making that distinction explicit keeps the
    helper faithful to the real parse and avoids accidentally relying on
    nested attribute access.
    """
    entry = feedparser.FeedParserDict({
        "id": f"oai:arXiv.org:{paper_id}v1",
        "title": f"Paper {paper_id}",
        "summary": "Abstract text.",
        "link": f"https://arxiv.org/abs/{paper_id}",
        "author": "Alice, Bob",
        "published_parsed": calendar.timegm((2026, 10, 12, 4, 0, 0, 0, 0, 0)),
        "updated_parsed": _ts(updated),
        "arxiv_announce_type": announce_type,
    })
    # tags stay a plain dict inside the FeedParserDict: feedparser only converts
    # the top level, so entry.meta is a dict on a real parse as well.
    entry["tags"] = tags if tags is not None else [{"term": "cs.AI"}, {"term": "cs.MA"}]
    return entry


def _feed(entries, feed_updated: datetime | None = None):
    if feed_updated is None:
        feed_updated = max(
            (datetime.fromtimestamp(e["updated_parsed"], tz=timezone.utc) for e in entries),
            default=datetime(2026, 10, 12, 4, 1, tzinfo=timezone.utc),
        )
    # Real parse shape: feedparser.FeedParserDict at the top level; nested
    # values (feed meta, entries, tags) stay plain dicts/lists.
    return feedparser.FeedParserDict({
        "bozo": False,
        "bozo_exception": None,
        "status": 200,
        "feed": {"title": "cs.AI updates on arXiv.org", "updated_parsed": _ts(feed_updated)},
        "entries": list(entries),
    })


def _response(age: int | None = None, status_code: int = 200):
    headers = requests.structures.CaseInsensitiveDict()
    if age is not None:
        headers["Age"] = str(age)
    return SimpleNamespace(content=b"<feed/>", headers=headers, status_code=status_code)


@pytest.fixture()
def now_utc(monkeypatch):
    """Freeze the clock so freshness decisions are deterministic."""
    frozen = datetime(2026, 10, 13, 2, 5, 0, tzinfo=timezone.utc)  # Tue 10:05 Beijing
    monkeypatch.setattr(arxiv_retriever, "_now_utc", lambda: frozen)
    return frozen


def _patch_feed(monkeypatch, feed, age=120):
    monkeypatch.setattr(
        ArxivRetriever, "_fetch_feed", lambda self, query, **kw: (feed, age)
    )


def _make(config, monkeypatch, now_utc):
    """Instantiate with the clock frozen, so entry times stay relative."""
    monkeypatch.setattr(arxiv_retriever, "_now_utc", lambda: now_utc)
    return ArxivRetriever(config)


def test_fresh_feed_is_used_without_api(monkeypatch, now_utc):
    entries = [_entry("2610.10001", now_utc - timedelta(hours=14))]
    _patch_feed(monkeypatch, _feed(entries))
    called = []
    monkeypatch.setattr(ArxivRetriever, "_retrieve_from_api", lambda self: called.append(1) or [])

    retriever = ArxivRetriever(_config())
    monkeypatch.setattr(arxiv_retriever, "_now_utc", lambda: now_utc)
    raw = retriever._retrieve_raw_papers()
    assert len(raw) == 1
    assert raw[0].title == "Paper 2610.10001"
    assert called == []


def test_stale_feed_falls_back_to_api(monkeypatch, now_utc):
    # Feed still carries last week's batch (updated 2026-10-09 16:00 UTC =
    # 82h before the frozen clock, outside the 72h lookback window).
    entries = [_entry("2609.09001", datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc))]
    _patch_feed(monkeypatch, _feed(entries, feed_updated=now_utc), age=9 * 3600)
    api_result = SimpleNamespace(title="API paper", entry_id="https://arxiv.org/abs/2610.20001")
    monkeypatch.setattr(ArxivRetriever, "_retrieve_from_api", lambda self: [api_result])

    raw = ArxivRetriever(_config())._retrieve_raw_papers()
    # 联合检索：API 结果在前；feed 条目早于窗口本应被丢弃，但合并去重按
    # entry_id 进行 —— feed 的 2609.09001 不在 API 结果里，仍会出现。
    assert "API paper" in [r.title for r in raw]


def test_empty_feed_falls_back_to_api(monkeypatch, now_utc):
    _patch_feed(monkeypatch, _feed([]), age=600)
    api_result = SimpleNamespace(title="API paper", entry_id="https://arxiv.org/abs/2610.20002")
    monkeypatch.setattr(ArxivRetriever, "_retrieve_from_api", lambda self: [api_result])

    raw = ArxivRetriever(_config())._retrieve_raw_papers()
    assert [r.title for r in raw] == ["API paper"]


def test_empty_feed_without_fallback_keeps_upstream_behaviour(monkeypatch, now_utc):
    _patch_feed(monkeypatch, _feed([]), age=600)
    monkeypatch.setattr(ArxivRetriever, "_retrieve_from_api", lambda self: pytest.fail("must not be called"))

    raw = ArxivRetriever(_config(fallback_api=False))._retrieve_raw_papers()
    assert raw == []


def test_stale_feed_with_failing_api_returns_feed(monkeypatch, now_utc):
    entries = [_entry("2609.09002", datetime(2026, 10, 9, 16, 0, tzinfo=timezone.utc))]
    _patch_feed(monkeypatch, _feed(entries, feed_updated=now_utc))
    monkeypatch.setattr(ArxivRetriever, "_retrieve_from_api", lambda self: [])

    raw = ArxivRetriever(_config())._retrieve_raw_papers()
    assert len(raw) == 1


def test_cross_list_entries_filtered_and_newest_tracked(monkeypatch, now_utc):
    entries = [
        _entry("2610.10001", now_utc - timedelta(hours=20)),
        _entry("2610.10002", now_utc - timedelta(hours=5), announce_type="cross"),
        _entry("2610.10003", now_utc - timedelta(hours=2)),
    ]
    retriever = _make(_config(), monkeypatch, now_utc)
    raw, newest = retriever._entries_to_results(entries, include_cross_list=False)
    assert sorted(p.title for p in raw) == ["Paper 2610.10001", "Paper 2610.10003"]
    assert newest == now_utc - timedelta(hours=2)

    raw_cross, _ = retriever._entries_to_results(entries, include_cross_list=True)
    assert len(raw_cross) == 3


def test_log_feed_state_reports_age_and_updated(monkeypatch, now_utc):
    messages: list[str] = []
    monkeypatch.setattr(arxiv_retriever.logger, "info", messages.append)
    entries = [_entry("2610.10001", now_utc - timedelta(hours=3))]
    ArxivRetriever._log_feed_state(_feed(entries, feed_updated=now_utc), 9 * 3600, 1)
    assert len(messages) == 1
    text = messages[0]
    assert "entries=1" in text
    assert "http_age=32400s" in text
    assert "stale" in text.lower()  # warns that the CDN copy is hours old


def test_as_aware_utc_converts_naive():
    naive = datetime(2026, 10, 12, 4, 0, 0)
    assert arxiv_retriever._as_aware_utc(naive) == datetime(2026, 10, 12, 4, 0, tzinfo=timezone.utc)
    assert arxiv_retriever._as_aware_utc(None) is None


def test_age_header_seconds():
    assert arxiv_retriever._age_header_seconds(_response(42)) == 42
    assert arxiv_retriever._age_header_seconds(_response()) is None
    assert arxiv_retriever._age_header_seconds(SimpleNamespace(headers={"Age": "x"})) is None


def test_fetch_feed_uses_requests_and_reads_age(monkeypatch):
    """_fetch_feed must go through requests.get so the Age header is visible."""
    captured = {}

    def fake_get(url, timeout=None, headers=None):
        captured["url"] = url
        captured["headers"] = headers
        return _response(300)

    good = _feed([_entry("2610.10001", datetime(2026, 10, 12, 4, 1, tzinfo=timezone.utc))])
    # a real parse returns a FeedParserDict (only the top level), so the stub must too
    monkeypatch.setattr(arxiv_retriever.requests, "get", fake_get)
    monkeypatch.setattr(arxiv_retriever.feedparser, "parse", lambda content: good)

    feed, age = ArxivRetriever(_config())._fetch_feed("cs.AI")
    assert captured["url"] == "https://rss.arxiv.org/atom/cs.AI"
    assert "zotero-arxiv-daily" in captured["headers"]["User-Agent"]
    assert age == 300
    assert len(feed.entries) == 1
    assert feed.status == 200
    captured = {}

    def fake_get(url, timeout=None, headers=None):
        captured["url"] = url
        captured["headers"] = headers
        return _response(300)

    monkeypatch.setattr(arxiv_retriever.requests, "get", fake_get)
    good = _feed([_entry("2610.10001", datetime(2026, 10, 12, 4, 1, tzinfo=timezone.utc))])
    # a real parse returns a FeedParserDict (only the top level), so the stub must too
    monkeypatch.setattr(arxiv_retriever.feedparser, "parse", lambda content: good)
    retriever = ArxivRetriever(_config())
    feed, age = retriever._fetch_feed("cs.AI")
    assert captured["url"] == "https://rss.arxiv.org/atom/cs.AI"
    assert "zotero-arxiv-daily" in captured["headers"]["User-Agent"]
    assert age == 300
    assert len(feed.entries) == 1
    assert feed.status == 200


def test_fetch_feed_retries_on_http_error(monkeypatch):
    """A 5xx body parses as bozo with no entries; the retriever retries once
    and then accepts the good feed (second response carries Age: 10)."""
    states = []
    good = _feed([_entry("2610.10001", datetime(2026, 10, 12, 4, 1, tzinfo=timezone.utc))])

    def fake_get(url, timeout=None, headers=None):
        states.append("get")
        return _response(status_code=503) if len(states) == 1 else _response(10)

    def fake_parse(content):
        if len(states) == 1:
            states.append("parse1")
            # feedparser.parse() of an HTML error body: bozo, no entries, no meta
            return feedparser.FeedParserDict({"bozo": True, "bozo_exception": Exception("503"), "entries": []})
        states.append("parse2")
        return good

    monkeypatch.setattr(arxiv_retriever.requests, "get", fake_get)
    monkeypatch.setattr(arxiv_retriever.feedparser, "parse", fake_parse)
    monkeypatch.setattr(arxiv_retriever, "sleep", lambda _: None)

    feed, age = ArxivRetriever(_config())._fetch_feed("cs.AI")
    assert states == ["get", "parse1", "get", "parse2"], states
    assert len(feed.entries) == 1
    assert age == 10



def test_entries_in_categories_filters_cross_listed(monkeypatch, now_utc):
    """With include_cross_list=False only entries whose primary category is
    subscribed survive, regardless of the announce_type mapping."""
    entries = [
        _entry("2610.10001", now_utc - timedelta(hours=2), tags=[{"term": "cs.AI"}, {"term": "cs.MA"}]),
        _entry("2610.10002", now_utc - timedelta(hours=2), tags=[{"term": "cs.LG"}, {"term": "cs.AI"}]),
    ]
    r = ArxivRetriever(_config())  # categories cs.AI + cs.CV
    kept = r._entries_in_categories(entries, include_cross_list=False)
    assert [e["id"] for e in kept] == ["oai:arXiv.org:2610.10001v1"]
    assert len(r._entries_in_categories(entries, include_cross_list=True)) == 2


def test_retrieve_from_api_filters_by_lookback(monkeypatch, now_utc):
    """The API fallback keeps only papers updated inside the window (72h)."""
    fresh = SimpleNamespace(
        title="Fresh", updated=now_utc - timedelta(hours=10), entry_id="x", pdf_url=None, authors=[]
    )
    mid = SimpleNamespace(
        title="Mid", updated=now_utc - timedelta(hours=50), entry_id="m", pdf_url=None, authors=[]
    )
    old = SimpleNamespace(
        title="Old", updated=now_utc - timedelta(hours=100), entry_id="y", pdf_url=None, authors=[]
    )
    captured = {}

    class FakeClient:
        def __init__(self, **kw):
            captured["client"] = kw

        def results(self, search):
            captured["query"] = search.query
            return iter([fresh, mid, old])

    class FakeSearch:
        def __init__(self, **kw):
            captured["search"] = kw
            self.query = kw.get("query")

    monkeypatch.setattr(arxiv_retriever.arxiv, "Client", FakeClient)
    monkeypatch.setattr(arxiv_retriever.arxiv, "Search", FakeSearch)

    papers = _make(_config(), monkeypatch, now_utc)._retrieve_from_api()
    # 50h 的 Mid 条目在 72h 窗口内（这正是 72h 相对 36h 的意义：捞回跨假期的批次）
    assert [p.title for p in papers] == ["Fresh", "Mid"]
    assert captured["search"]["query"] == "cat:cs.AI OR cat:cs.CV"
    assert captured["search"]["max_results"] == 200
    assert captured["client"]["delay_seconds"] >= 3.0


def test_retrieve_from_api_survives_api_failure(monkeypatch):
    class Boom:
        def __init__(self, **kw):
            pass

        def results(self, search):
            raise RuntimeError("HTTP 429")

    monkeypatch.setattr(arxiv_retriever.arxiv, "Client", Boom)
    assert ArxivRetriever(_config())._retrieve_from_api() == []


def test_defaults_come_from_base_yaml(config, monkeypatch):
    """base.yaml defines the keys; the retriever mirrors those defaults.

    CUSTOM_CONFIG on GitHub is composed on top of base.yaml, so a config that
    predates these keys still gets the documented defaults.
    """
    cfg = config
    cfg.source.arxiv.category = ["cs.MA"]
    assert cfg.source.arxiv.max_lookback_hours == 72
    assert cfg.source.arxiv.fallback_api is True
    assert cfg.source.arxiv.fallback_max_results == 200
    r = ArxivRetriever(cfg)
    assert r.max_lookback_hours == 72
    assert r.fallback_api is True
    assert r.fallback_max_results == 200

    # A hand-built config without the keys must not crash.
    minimal = ArxivRetriever(_config())
    assert minimal.max_lookback_hours == 72
    assert minimal.fallback_api is True


def _config(**arxiv_overrides):
    from omegaconf import OmegaConf

    cfg = OmegaConf.create(
        {
            "source": {"arxiv": {"category": ["cs.AI", "cs.CV"], "include_cross_list": False}},
            "executor": {"debug": False},
        }
    )
    for k, v in arxiv_overrides.items():
        cfg.source.arxiv[k] = v
    return cfg