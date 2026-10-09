"""从 config/custom.yaml 生成可直接粘贴进 GitHub Variables 的 CUSTOM_CONFIG 纯 YAML。

GitHub 的 CUSTOM_CONFIG 是单行字符串变量，注释和多余空行会造成困扰，
所以这里剥离注释、规范化后输出。上线前请确认 debug 为 false。

用法：uv run python scripts_emit_custom_config.py
"""

from pathlib import Path

import yaml

src = Path("config/custom.yaml")
raw = yaml.safe_load(src.read_text(encoding="utf-8"))

if raw["executor"].get("debug"):
    raise SystemExit(
        "当前 config/custom.yaml 的 executor.debug 为 true。\n"
        "这是本地验证用的设置，上线前请改成 false，否则每天只推 10 篇。"
    )

print("# 粘贴以下全部内容到 GitHub: Settings → Secrets and variables → Actions")
print("# → Variables → New repository variable → 名称 CUSTOM_CONFIG")
print("# 注意：必须建在 Variables 标签，不是 Secrets。")
print()
print(yaml.safe_dump(raw, sort_keys=False, allow_unicode=True, default_flow_style=False))
