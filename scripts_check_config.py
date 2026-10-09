"""校验 config/custom.yaml 能被 Hydra/OmegaConf 正确解析并与 base.yaml 合并。

用假的环境变量值，只验证配置结构与合并结果，不触碰网络。
运行：uv run python tests/test_local_config.py
"""

import os
from omegaconf import OmegaConf

FAKE_ENV = {
    "ZOTERO_ID": "12345678",
    "ZOTERO_KEY": "FAKE_ZOTERO_KEY",
    "SENDER": "12345678@qq.com",
    "RECEIVER": "12345678@qq.com",
    "SENDER_PASSWORD": "FAKE_SMTP_CODE",
    "OPENAI_API_KEY": "sk-ant-FAKE",
    "OPENAI_API_BASE": "https://api.anthropic.com/v1/",
}
os.environ.update(FAKE_ENV)

base = OmegaConf.load("config/base.yaml")
custom = OmegaConf.load("config/custom.yaml")

# 与 config/default.yaml 的 defaults 列表一致的合并顺序：先 base 后 custom
merged = OmegaConf.merge(base, custom)

errors: list[str] = []


def check(label: str, actual, expected) -> None:
    if actual != expected:
        errors.append(f"{label}: 期望 {expected!r}，实际 {actual!r}")


# --- 环境变量插值是否真的生效 ---
check("zotero.user_id", merged.zotero.user_id, "12345678")
check("zotero.api_key", merged.zotero.api_key, "FAKE_ZOTERO_KEY")
check("email.sender", merged.email.sender, "12345678@qq.com")
check("email.sender_password", merged.email.sender_password, "FAKE_SMTP_CODE")
check("llm.api.key", merged.llm.api.key, "sk-ant-FAKE")
check("llm.api.base_url", merged.llm.api.base_url, "https://api.anthropic.com/v1/")

# --- 本方案的关键决策 ---
check("api_mode", merged.llm.api_mode, "chat_completion")
check("language", merged.llm.language, "Chinese")
check("model", merged.llm.generation_kwargs.model, "deepseek-flash")
check("max_tokens", merged.llm.generation_kwargs.max_tokens, 512)

# DeepSeek 思考模式默认开启，必须显式关闭，否则成本/延迟翻倍
thinking = merged.llm.generation_kwargs.get("extra_body", {}).get("thinking", {})
check("thinking disabled", thinking.get("type"), "disabled")
check("arxiv categories", list(merged.source.arxiv.category), ["cs.MA"])
check("smtp_server", merged.email.smtp_server, "smtp.qq.com")
check("smtp_port", merged.email.smtp_port, 465)
check("executor.source", list(merged.executor.source), ["arxiv"])
check("executor.reranker", merged.executor.reranker, "local")
check("reranker.local.model", merged.reranker.local.model,
      "jinaai/jina-embeddings-v5-text-nano-retrieval")

# --- upstream Executor 会用到的字段必须存在且非 null ---
if merged.source.arxiv.category is None:
    errors.append("source.arxiv.category 为 null —— ArxivRetriever 会抛 ValueError")
if not merged.executor.source:
    errors.append("executor.source 为空 —— 不会检索任何源")
if merged.executor.max_paper_num is None:
    errors.append("executor.max_paper_num 为 null")

print(OmegaConf.to_yaml(merged))
if errors:
    print("\n=== 校验失败 ===")
    for e in errors:
        print(f"  - {e}")
    raise SystemExit(1)
print("=== 配置校验通过 ===")
