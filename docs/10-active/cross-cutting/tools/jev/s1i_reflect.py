#!/usr/bin/env python
"""S1-I 反思离线测量“产出”阶段：对三个材料库 × 三种产出者（R / C / T）× 4 次，共 36 条反思产出。

用途
    按 .demo/observe/npc-slice1-20261112/s1i/plan.md “产出者（变量）”一节：
      R  Hindsight reflect：query = 聚焦问题 + 空格 + 回答规则；include.facts = {}；不传 budget / max_tokens。
      C  聚焦问题 -> Hindsight recall（budget mid、max_tokens 2000、不加 tags）-> LLM 给 <= 3 条
         `insight (because of id, id)` 洞见（提示 = 召回记忆 `[id] text` + 问题 + 指令 + 回答规则）。
      T  ① memories/list 取全量，按时间取最近 20 条 -> LLM 提 <= 3 个问题（每行一个）；
         ② 每个问题各打一次 recall（参数同 C），按 id 合并去重（保持首次出现次序）；
         ③ 同 C 的第三步，“问题”处列出这 <= 3 个问题。
    只读三个 bank（reflect / recall / memories/list）；不 retain、不改配置、不删库、不起容器或长驻进程。
    只用标准库 urllib。

用法（Git Bash 下 Python 用 -I -B -X utf8）
    python -I -B -X utf8 s1i_reflect.py run                       # 全量 36 条，写 s1i/outputs/
    python -I -B -X utf8 s1i_reflect.py run --out <dir> --only m1-R-1,m1-C-1,m1-T-1   # 小规模验证
    选项：--base（默认 http://127.0.0.1:18933）、--samples（每格次数，默认 4）、--only（逗号分隔的 key）

T 的“最近 20 条”：取 memories/list 全部条目（含 observation / world / experience），排序键为
    occurred_start；为空则回退 mentioned_at；再空回退 date（回退次数记入每条记录的 time_fallbacks 并写 run.log）。
    排序降序取 20 条（并列时依次比 mentioned_at、id，保证确定），喂给 LLM 时按时间升序排列、只给 text。
    memories/list 每个库只取一次（库内容不变），原始响应存 raw/<bank>-memories-list.json。

并发与重试：全脚本同时在途的任务 <= 3（每个任务内部的请求串行）；每个请求超时 180 秒
    （若设了 NPC_LLM_TIMEOUT_MS 且更小则用更小者）；失败最多重试 2 次（共 3 次尝试；400/401/403/404/422 不重试），仍失败记为失败并继续。

LLM 端点与凭据
    环境 NPC_LLM_URL / NPC_LLM_KEY / NPC_LLM_MODEL（及可选 NPC_LLM_EFFORT、NPC_LLM_TIMEOUT_MS、NPC_LLM_CACERTFILE）。
    进程环境里没有时，只从主检出 D:/hemifuture/ex_mmo_cluster/.env 读 NPC_LLM_* 进本进程环境。
    请求体形状同 apps/npc_server/lib/npc_server/brain/llm.ex 与 http.ex（Responses 风格：
    model / input / reasoning.effort（缺省 "low"）/ store=false，Authorization: Bearer），单轮纯文本、不带工具、不设 temperature。
    URL 与 key 的值绝不打印、不写入任何文件：原始响应、日志、错误信息落盘前都会把这两个值替换掉；只记录模型名。

落盘（s1i/outputs/）：outputs.json、raw/、blind-a.json、blind-b.json、blind-key.json、run.log。

第 2 轮（plan-round2.md）：run --round 2，只有 R、C，规则 A1 / A2（A2 在问题前加人格段），3 库 × 2 × 2 × 4 = 48 条，
    key 形如 m1-R-A2-3，写 s1i/outputs2/（outputs.json 每条另有 rule；盲评清单用不同种子与编号前缀 p）。
    不带 --round 时行为与第 1 轮完全一致。
"""

import argparse
import json
import os
import random
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
S1I = REPO / ".demo/observe/npc-slice1-20261112/s1i"
MAIN_ENV = Path("D:/hemifuture/ex_mmo_cluster/.env")

BANKS = ("s1i-m0", "s1i-m1", "s1i-m2")
PRODUCERS = ("R", "C", "T")
ACTOR_NAME = "Corvin (actor 920628760578)"

# 与 plan.md 逐字一致。
ANSWER_RULES = ("Answer in the first person, in at most 3 sentences. Use only what the memories say; "
                "if they do not settle something, say so. Mention the evidence (how many times, "
                "what happened or did not happen).")
FOCUS_QUESTION = (f"Since {ACTOR_NAME} removed my hut and I rebuilt it, I have guarded it 10 times. "
                  "What do I make of that, and what should I conclude about my hut and about him?")
REFLECT_QUERY = FOCUS_QUESTION + " " + ANSWER_RULES
T_QUESTION_SENTENCE = ("Given only the statements above, what are the 3 most salient high-level questions "
                       "we can answer about the subject?")
T_QUESTION_FORMAT = "Give at most 3 questions, one per line, with no numbering and no other text."
INSIGHT_INSTRUCTION = ("Give at most 3 insights. Write each insight on its own line in the form "
                       "`insight (because of id, id)`, where every id must be taken only from the memory ids "
                       "listed above.")

# 第 2 轮（plan-round2.md “变量”一节，逐字）：只换回答规则。A0 = 上面的 ANSWER_RULES（第 1 轮）。
ROUND2_RULES = {
    "A1": ("Answer in the first person, in at most 3 sentences. Start from the evidence in the memories "
           "(how many times, what happened or did not happen); do not add events that are not in them. "
           "Then make up your mind: say what you now believe about how things stand with the hut and with "
           "him. People have to decide on incomplete evidence, and the belief may go either way."),
}
ROUND2_RULES["A2"] = ROUND2_RULES["A1"]  # A2 与 A1 的规则相同，差别只在问题前的人格段
PERSONA = ("I am Garen, a builder. Personality: a bit friendly, bold, very responsible, very hardworking, "
           "practical, thorough. Personal: Takes pride in the things he builds and is slow to forget a wrong "
           "done to him. Once his work is done he likes to spend his time at the plaza with the neighbours.")
ROUND2_PRODUCERS = ("R", "C")
ROUND2_RULE_NAMES = ("A1", "A2")

RECALL_PARAMS = {"budget": "mid", "max_tokens": 2000}
PATH_PREFIX = "/v1/default"
REQUEST_TIMEOUT = 180
MAX_RETRIES = 2
MAX_CONCURRENCY = 3
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
BECAUSE_RE = re.compile(r"\s*\(\s*because(?:\s+of)?\b[^)]*\)", re.IGNORECASE)  # 模型偶尔漏写 of


# ---------------------------------------------------------------- 凭据与日志

def load_env():
    """进程环境缺 NPC_LLM_* 时，只从主检出 .env 读这些键进本进程环境；不打印值。"""
    if all(k in os.environ for k in ("NPC_LLM_URL", "NPC_LLM_KEY", "NPC_LLM_MODEL")):
        return
    for line in MAIN_ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            k = k.strip()
            if k.startswith("NPC_LLM_") and k not in os.environ:
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                os.environ[k] = v


class Secrets:
    def __init__(self):
        self.values = [os.environ[k] for k in ("NPC_LLM_URL", "NPC_LLM_KEY") if os.environ.get(k)]
        # 主机名也不落盘。
        m = re.match(r"^\w+://([^/:]+)", os.environ.get("NPC_LLM_URL", ""))
        if m:
            self.values.append(m.group(1))
        self.values = sorted(set(self.values), key=len, reverse=True)

    def scrub(self, text):
        for v in self.values:
            text = text.replace(v, "<redacted>")
        return text


class Logger:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def __call__(self, line):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        with self.lock:
            with open(self.path, "a", encoding="utf8") as f:
                f.write(f"{stamp} {line}\n")


# ---------------------------------------------------------------- HTTP

class Client:
    def __init__(self, base, log, secrets, out_raw):
        self.base = base.rstrip("/")
        self.log = log
        self.secrets = secrets
        self.raw = out_raw
        self.llm_url = os.environ["NPC_LLM_URL"]
        self.llm_key = os.environ["NPC_LLM_KEY"]
        self.model = os.environ["NPC_LLM_MODEL"]
        self.effort = os.environ.get("NPC_LLM_EFFORT") or "low"
        t = os.environ.get("NPC_LLM_TIMEOUT_MS")
        self.llm_timeout = min(REQUEST_TIMEOUT, int(t) / 1000) if t and t.isdigit() else REQUEST_TIMEOUT
        cafile = os.environ.get("NPC_LLM_CACERTFILE")
        self.ssl_ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()

    def _once(self, req, timeout, ctx):
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return r.status, r.read().decode("utf8")

    def _send(self, label, req, timeout, ctx, raw_name):
        """最多 1 + MAX_RETRIES 次尝试；返回 (json, 最后一次尝试耗时秒, 尝试次数)；仍失败抛 RuntimeError。"""
        last = "?"
        for attempt in range(1, MAX_RETRIES + 2):
            t0 = time.time()
            try:
                status, text = self._once(req, timeout, ctx)
            except urllib.error.HTTPError as e:
                status, text = e.code, e.read().decode("utf8", "replace")
            except Exception as e:  # 连接 / 超时
                dt = time.time() - t0
                last = f"{type(e).__name__}: {self.secrets.scrub(str(e))[:200]}"
                self.log(f"{label} ERROR {type(e).__name__} {dt:.2f}s attempt={attempt}")
                if attempt <= MAX_RETRIES:
                    time.sleep(2 * attempt)
                continue
            dt = time.time() - t0
            self.log(f"{label} -> {status} {dt:.2f}s attempt={attempt}")
            if status == 200:
                try:
                    js = json.loads(text)
                except json.JSONDecodeError:
                    last = "HTTP 200 but body is not JSON"
                    if attempt <= MAX_RETRIES:
                        time.sleep(2 * attempt)
                    continue
                if raw_name:
                    (self.raw / raw_name).write_text(
                        self.secrets.scrub(json.dumps(js, ensure_ascii=False, indent=1)), encoding="utf8")
                return js, dt, attempt
            last = f"HTTP {status}: {self.secrets.scrub(text)[:300]}"
            if status in (400, 401, 403, 404, 422):  # 请求本身有问题，重试无意义
                break
            if attempt <= MAX_RETRIES:
                time.sleep(2 * attempt)
        raise RuntimeError(last)

    def hindsight(self, method, path, body, raw_name):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf8")
        req = urllib.request.Request(self.base + PATH_PREFIX + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"} if data else {})
        return self._send(f"{method} {PATH_PREFIX}{path}", req, REQUEST_TIMEOUT, None, raw_name)

    def llm(self, prompt, raw_name):
        """单轮纯文本请求（形状同 brain/llm.ex）。返回 (text, usage, 耗时秒, 尝试次数)。"""
        body = {"model": self.model, "input": prompt, "reasoning": {"effort": self.effort}, "store": False}
        req = urllib.request.Request(
            self.llm_url, data=json.dumps(body, ensure_ascii=False).encode("utf8"), method="POST",
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + self.llm_key,
                     "User-Agent": "npc-s1i-reflect/1.0"})
        js, dt, attempts = self._send("LLM", req, self.llm_timeout, self.ssl_ctx, raw_name)
        text = llm_text(js)
        if not text:
            raise RuntimeError("LLM response has no output text")
        return text, js.get("usage"), dt, attempts


def llm_text(js):
    if isinstance(js.get("output_text"), str) and js["output_text"].strip():
        return js["output_text"].strip()
    parts = []
    for item in js.get("output") or []:
        if item.get("type") == "message":
            for c in item.get("content") or []:
                if isinstance(c.get("text"), str):
                    parts.append(c["text"])
    return "".join(parts).strip()


# ---------------------------------------------------------------- 文本处理

def clean_text(text):
    """去掉 `(because of …)` 引用括号与残留 id，多行 / 多条洞见用一个空格连成一行；其它字符不改。"""
    t = BECAUSE_RE.sub("", text)
    t = re.sub(r"\[\s*" + UUID_RE.pattern + r"\s*\]", "", t)
    t = UUID_RE.sub("", t)
    # 第 2 轮里模型有时把引用写成 `(id, id)`（没有 because of），去掉 id 后剩空括号 `(, )`：一并去掉，
    # 并把由此产生的连续空格收成一个（统筹会话 2026-11-13 补；第 1 轮的产出里没有这种残留）。
    t = re.sub(r"\s*\((?:\s*,?\s*)*\)", "", t)
    t = re.sub(r" {2,}", " ", t)
    return re.sub(r"\s*[\r\n]+\s*", " ", t).strip()


def extract_citations(text):
    """从 `(because of …)` 括号里按出现次序取 id（含重复）。"""
    ids = []
    for m in re.finditer(r"\(\s*because(?:\s+of)?\b([^)]*)\)", text, re.IGNORECASE):
        ids += UUID_RE.findall(m.group(1))
    return ids


def count_sentences(raw_text):
    """句数粗数：先去引用括号，再按行（每条洞见一行，可能没有句号）与句末标点切分。"""
    t = UUID_RE.sub("", BECAUSE_RE.sub("", raw_text))
    n = 0
    for line in t.splitlines():
        n += len([s for s in re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(\[])", line.strip()) if s])
    return n


def parse_questions(text):
    qs = []
    for line in text.splitlines():
        line = re.sub(r"^\s*(?:\d+[.)]|[-*\u2022])\s*", "", line).strip()
        if line:
            qs.append(line)
    return qs[:3]


def when_key(item):
    """(排序用时间, 用了哪个回退)；occurred_start -> mentioned_at -> date。"""
    for field in ("occurred_start", "mentioned_at", "date"):
        if item.get(field):
            return item[field], field
    return "", "none"


def build_insight_prompt(memories, questions, rule=ANSWER_RULES, persona=None):
    """默认参数即第 1 轮的提示；第 2 轮传 rule（A1 规则）与可选 persona（放在“问题”之前、独占一段）。"""
    lines = ["Memories:"] + [f"[{m['id']}] {m['text']}" for m in memories]
    if len(questions) == 1:
        q = "Question: " + questions[0]
    else:
        q = "Questions:\n" + "\n".join(f"{i}. {x}" for i, x in enumerate(questions, 1))
    if persona:
        q = persona + "\n\n" + q
    return "\n".join(lines) + "\n\n" + q + "\n\n" + INSIGHT_INSTRUCTION + " " + rule


# ---------------------------------------------------------------- 产出者

class Runner:
    def __init__(self, client, log, out):
        self.c = client
        self.log = log
        self.out = out
        self.lists = {}
        self.list_lock = threading.Lock()

    def bank_list(self, bank):
        with self.list_lock:
            if bank not in self.lists:
                js, dt, _ = self.c.hindsight("GET", f"/banks/{bank}/memories/list?limit=1000&offset=0", None,
                                             f"{bank}-memories-list.json")
                self.lists[bank] = js["items"]
        return self.lists[bank]

    def recall(self, bank, question, raw_name):
        body = {"query": question, **RECALL_PARAMS}
        js, dt, _ = self.c.hindsight("POST", f"/banks/{bank}/memories/recall", body, raw_name)
        return [{"id": r["id"], "text": r["text"]} for r in js.get("results") or []], dt

    def insight_step(self, bank, key, questions, memories, rec, rule=ANSWER_RULES, persona=None):
        prompt = build_insight_prompt(memories, questions, rule, persona)
        text, usage, dt, att = self.c.llm(prompt, f"{key}.llm-insight.json")
        rec.update(text=text, llm_insight_s=round(dt, 3), llm_insight_attempts=att)
        rec["usage"]["insight"] = usage

    def produce(self, key, bank, producer, sample, rule=None):
        """rule=None 即第 1 轮（提示逐字不变）；rule 为 "A1" / "A2" 时是第 2 轮（只有 R、C）。"""
        rec = {"key": key, "bank": bank, "producer": producer, "sample": sample, "text": None, "clean": None,
               "usage": {}, "error": None}
        rule_text = ROUND2_RULES[rule] if rule else ANSWER_RULES
        persona = PERSONA if rule == "A2" else None
        reflect_query = REFLECT_QUERY
        if rule:
            rec["rule"] = rule
            reflect_query = ((persona + " ") if persona else "") + FOCUS_QUESTION + " " + rule_text
        t_all = time.time()
        try:
            if producer == "R":
                body = {"query": reflect_query, "include": {"facts": {}}}
                js, dt, att = self.c.hindsight("POST", f"/banks/{bank}/reflect", body, f"{key}.reflect.json")
                rec.update(text=js.get("text"), reflect_s=round(dt, 3), reflect_attempts=att)
                rec["usage"]["reflect"] = js.get("usage")
                facts = ((js.get("based_on") or {}).get("memories")) or []
                rec["based_on_ids"] = [m["id"] for m in facts]
            elif producer == "C":
                mems, dt = self.recall(bank, FOCUS_QUESTION, f"{key}.recall.json")
                rec.update(questions=[FOCUS_QUESTION], recall_s=[round(dt, 3)], recalled_ids=[m["id"] for m in mems])
                self.insight_step(bank, key, [FOCUS_QUESTION], mems, rec, rule_text, persona)
            else:  # T
                items = self.bank_list(bank)
                keyed = [(when_key(it), it) for it in items]
                keyed.sort(key=lambda p: (p[0][0], p[1].get("mentioned_at") or "", p[1]["id"]), reverse=True)
                recent = keyed[:20]
                fallbacks = [p[0][1] for p in recent if p[0][1] != "occurred_start"]
                rec["time_fallbacks"] = fallbacks
                if fallbacks:
                    self.log(f"{key} time fallback used {len(fallbacks)}x: {fallbacks}")
                recent.sort(key=lambda p: (p[0][0], p[1].get("mentioned_at") or "", p[1]["id"]))
                statements = "\n".join("- " + p[1]["text"] for p in recent)
                prompt = f"Statements:\n{statements}\n\n{T_QUESTION_SENTENCE} {T_QUESTION_FORMAT}"
                qtext, usage, dt, att = self.c.llm(prompt, f"{key}.llm-questions.json")
                rec.update(llm_questions_s=round(dt, 3), questions_raw=qtext)
                rec["usage"]["questions"] = usage
                qs = parse_questions(qtext)
                if not qs:
                    raise RuntimeError("T step 1 produced no questions")
                rec["questions"] = qs
                merged, seen, rts = [], set(), []
                for i, q in enumerate(qs, 1):
                    mems, dt = self.recall(bank, q, f"{key}.recall-{i}.json")
                    rts.append(round(dt, 3))
                    for m in mems:
                        if m["id"] not in seen:
                            seen.add(m["id"])
                            merged.append(m)
                rec.update(recall_s=rts, recalled_ids=[m["id"] for m in merged])
                self.insight_step(bank, key, qs, merged, rec)
            text = rec["text"]
            if not text or not text.strip():
                raise RuntimeError("empty output text")
            rec["clean"] = clean_text(text)
            rec["sentences"] = count_sentences(text)
            if producer in ("C", "T"):
                valid = {it["id"] for it in self.bank_list(bank)}
                cites = extract_citations(text)
                rec["citations"] = [{"id": i, "exists_in_bank": i in valid} for i in cites]
        except Exception as e:
            rec["error"] = self.c.secrets.scrub(f"{type(e).__name__}: {e}")[:400]
            self.log(f"{key} FAILED {rec['error'][:160]}")
        rec["total_s"] = round(time.time() - t_all, 3)
        return rec


# ---------------------------------------------------------------- run

BLIND_ROUND1 = (("a", 20261112), ("b", 20261113))
BLIND_ROUND2 = (("a", 20261114), ("b", 20261115))  # 第 2 轮：不同种子，编号加前缀 "p"（cmd_run）


def write_blind(records, out, tags=BLIND_ROUND1, id_prefix=""):
    ok = [r for r in records if r["clean"]]
    key_map = {}
    for tag, seed in tags:
        order = list(ok)
        random.Random(seed).shuffle(order)
        entries, mapping = [], {}
        for i, r in enumerate(order, 1):
            oid = f"{id_prefix}{tag}{i:02d}"
            entries.append({"id": oid, "text": r["clean"]})
            mapping[oid] = r["key"]
        (out / f"blind-{tag}.json").write_text(json.dumps(entries, ensure_ascii=False, indent=1), encoding="utf8")
        key_map[tag] = mapping
    (out / "blind-key.json").write_text(json.dumps(key_map, ensure_ascii=False, indent=1), encoding="utf8")


def cmd_run(args):
    out = Path(args.out)
    (out / "raw").mkdir(parents=True, exist_ok=True)
    log = Logger(out / "run.log")
    load_env()
    for k in ("NPC_LLM_URL", "NPC_LLM_KEY", "NPC_LLM_MODEL"):
        if not os.environ.get(k):
            print(f"缺少环境 {k}（进程环境与主检出 .env 里都没有）", file=sys.stderr)
            return 2
    client = Client(args.base, log, Secrets(), out / "raw")
    log(f"start argv={sys.argv[1:]} model={client.model} effort={client.effort} "
        f"samples={args.samples} concurrency<={MAX_CONCURRENCY}")
    if args.round == 2:
        jobs = [(f"{b[-2:]}-{p}-{rl}-{s}", b, p, s, rl) for b in BANKS for p in ROUND2_PRODUCERS
                for rl in ROUND2_RULE_NAMES for s in range(1, args.samples + 1)]
    else:
        jobs = [(f"{b[-2:]}-{p}-{s}", b, p, s) for b in BANKS for p in PRODUCERS for s in range(1, args.samples + 1)]
    if args.only:
        wanted = set(args.only.split(","))
        jobs = [j for j in jobs if j[0] in wanted]
    runner = Runner(client, log, out)
    with ThreadPoolExecutor(max_workers=MAX_CONCURRENCY) as ex:
        records = list(ex.map(lambda j: runner.produce(*j), jobs))
    (out / "outputs.json").write_text(json.dumps(records, ensure_ascii=False, indent=1), encoding="utf8")
    if args.round == 2:
        write_blind(records, out, BLIND_ROUND2, "p")
    else:
        write_blind(records, out)
    bad = [r["key"] for r in records if r["error"]]
    log(f"finished total={len(records)} failed={bad}")
    print(f"model={client.model} total={len(records)} failed={bad}")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--base", default="http://127.0.0.1:18933")
    r.add_argument("--out", default=None, help="默认：第 1 轮 s1i/outputs，第 2 轮 s1i/outputs2")
    r.add_argument("--samples", type=int, default=4)
    r.add_argument("--only", default="")
    r.add_argument("--round", type=int, choices=(1, 2), default=1,
                   help="2 = 第 2 轮：产出者 R、C × 规则 A1、A2，key 形如 m1-R-A2-3")
    args = ap.parse_args()
    if args.out is None:
        args.out = str(S1I / ("outputs2" if args.round == 2 else "outputs"))
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
