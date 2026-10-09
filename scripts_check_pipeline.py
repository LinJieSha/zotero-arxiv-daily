"""端到端连通性预检：在拿到 Zotero/LLM/邮箱凭据之前，先独立验证三件事。

1. arXiv RSS 端点可达，且 cs.CR+cs.MA 组合有效、返回论文数合理
2. Claude 的 OpenAI 兼容端点可达，模型名正确，system+user 双消息可用
3. 本地 reranker 模型能下载并编码（本项目唯一可选的 reranker）

用法：uv run python scripts_check_pipeline.py
需要：ANTHROPIC_API_KEY 环境变量（或 .env 中已设置 OPENAI_API_KEY）
"""

import os
import sys

import requests
from dotenv import load_dotenv

load_dotenv()

CATEGORIES = ["cs.MA"]
MODEL = "deepseek-flash"
BASE_URL = "https://api.deepseek.com"

failures: list[str] = []


def report(name: str, ok: bool, detail: str) -> None:
    print(f"[{'OK ' if ok else 'FAIL'}] {name}: {detail}")
    if not ok:
        failures.append(name)


# --- 1. arXiv RSS ---
try:
    query = "+".join(CATEGORIES)
    url = f"https://rss.arxiv.org/atom/{query}"
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    import feedparser

    feed = feedparser.parse(resp.text)
    entries = feed.entries
    # 估算一个工作日的量级，用于判断 6 小时 Actions 限额是否有风险
    report(
        "arXiv RSS",
        len(entries) > 0,
        f"{len(entries)} 条 (query={query})",
    )
except Exception as exc:
    report("arXiv RSS", False, f"{type(exc).__name__}: {exc}")


# --- 2. DeepSeek 兼容端点 ---
api_key = os.environ.get("OPENAI_API_KEY") or os.environ.get("ANTHROPIC_API_KEY")
if not api_key:
    report("DeepSeek 端点", False, "未找到 API key，跳过（先在 .env 里填 OPENAI_API_KEY）")
else:
    try:
        from openai import OpenAI

        client = OpenAI(api_key=api_key, base_url=BASE_URL)
        # 复用上游 protocol.py 的调用形状：system + user 两条消息 + extra_body
        resp = client.chat.completions.create(
            model=MODEL,
            max_tokens=64,
            messages=[
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": "用一句中文总结：多智能体系统中的认知偷懒。"},
            ],
            extra_body={"thinking": {"type": "disabled"}},
        )
        text = resp.choices[0].message.content
        u = resp.usage
        report(
            "DeepSeek 端点",
            bool(text),
            f"{MODEL} -> {text[:50]!r} | tokens in/out={u.prompt_tokens}/{u.completion_tokens}",
        )
    except Exception as exc:
        report("Claude 端点", False, f"{type(exc).__name__}: {exc}")


# --- 3. 本地 reranker 模型 ---
try:
    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(
        "jinaai/jina-embeddings-v5-text-nano-retrieval", trust_remote_code=True
    )
    vecs = model.encode(["prompt injection attack"], task="retrieval", prompt_name="document")
    report("本地 reranker", vecs.shape[0] == 1, f"shape={vecs.shape}")
except Exception as exc:
    report("本地 reranker", False, f"{type(exc).__name__}: {exc}")


print()
if failures:
    print(f"=== {len(failures)} 项未通过: {', '.join(failures)} ===")
    sys.exit(1)
print("=== 三项预检全部通过 ===")
