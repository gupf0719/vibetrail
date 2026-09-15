#!/usr/bin/env python3
"""把 stdin 的事件 JSONL 逐条包成 paas-coding-hook 协议 1.0 的批次，用仓内的 schema 原件校验。

用法：schema-check.py [--schema third-party/collection-batch-1.0.schema.json] < events.jsonl
每条事件单独包一个批次校验，错误能定位到第几行、哪个字段。全部通过打印 ✓ 并退出 0；否则列出错误、退出 1。
只在测试里用（A10/A11 的「每条事件先过协议 schema」钉子）；运行时的 push 层不依赖 python。
"""
import json
import os
import sys
import uuid

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    print("✗ 缺 python 包 jsonschema：pip install jsonschema", file=sys.stderr)
    sys.exit(2)

here = os.path.dirname(os.path.abspath(__file__))
schema_path = os.path.join(here, "..", "third-party", "collection-batch-1.0.schema.json")
args = sys.argv[1:]
if len(args) >= 2 and args[0] == "--schema":
    schema_path = args[1]

with open(schema_path, encoding="utf-8") as fh:
    schema = json.load(fh)
validator = Draft202012Validator(schema, format_checker=FormatChecker())

# 批次外壳：client 的两个默认值按 DESIGN §4.1（name 照填 const，policy_version = none-0 表示暂不脱敏）
def batch(events):
    return {
        "schema_version": "1.0",
        "batch_id": str(uuid.uuid4()),
        "client": {"name": "paas-coding-hook", "version": "test", "device_id": str(uuid.uuid4()), "policy_version": "none-0"},
        "events": events,
    }

events = []
bad = 0
for lineno, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError as exc:
        print(f"  ✗ 第 {lineno} 行不是 JSON: {exc}")
        bad += 1
        continue
    events.append((lineno, ev))
    errs = sorted(validator.iter_errors(batch([ev])), key=lambda e: list(e.path))
    if errs:
        bad += 1
        etype = ev.get("type") if isinstance(ev, dict) else "?"
        print(f"  ✗ 第 {lineno} 行 ({etype}) 不过 schema:")
        for e in errs[:6]:
            path = "/".join(str(p) for p in e.path) or "<root>"
            print(f"      {path}: {e.message[:160]}")

# 批次级约束（≤ 100 条）也过一遍：整批与单条都合法才算合法
if events and bad == 0:
    for i in range(0, len(events), 100):
        chunk = [ev for _, ev in events[i:i + 100]]
        errs = list(validator.iter_errors(batch(chunk)))
        if errs:
            bad += 1
            print(f"  ✗ 第 {i // 100 + 1} 个批次不过 schema: {errs[0].message[:160]}")

if bad:
    print(f"  ❌ {bad} 处不过 schema（共 {len(events)} 条事件）")
    sys.exit(1)
print(f"  ✓ {len(events)}/{len(events)} 条事件过协议 1.0 schema")
