#!/usr/bin/env python
"""S1-X2：反思的第二轮离线测量——带此刻的事实、带之前的想法、存单独的反思库、连续几轮。探索性，不是验收。

是什么
  在 S1-T 那一次真实实跑的导出上，按规则算出 NPC（Garen）该反思的时刻，逐轮：把那一刻真实 bank 里已有的文档重放进
  经历副本库 -> 定这一轮问哪几件事 -> 取四块材料（Right now / What happened / What I thought before / To think over now）
  -> 经本机 magpie 网关写几句角色口吻的日记 -> 代码卡句数 -> 存进单独的反思库 -> 下一轮从反思库读回原文带进提示词；
  最后把每轮各问题最新的一条作为新栏插进真实 state 问 Jev。
为什么
  上一轮 S1-X 有两处测法缺陷：材料的“现在”与基准 state 错位，材料里没有此刻的处境。本轮的计划、提示词与期望已定稿于
  .demo/observe/npc-slice1-20261112/s1x2/plan.md（唯一规格；本脚本一字不改地实现其中的提示词与问题原文，不判定成立 / 落空）。
方法论硬约束
  输入只能是产品真实运行的导出（s1t/export、s1t/states、s1t/export/rawobs）；不手写任何进库或进 state 的材料。
  真实 bank npc-life-371636310017 与 S1-N 的 npc-life-312999940097 只读：本脚本只对 s1x2-copy-20261113 与
  s1x2-refl-20261113 两个库发请求（Hindsight 客户端在发送前核对路径）。

输入的取法（都从文件算，不写死文档数、时刻、人名、cid、建筑名）
  - 文档原文：导出的文档列表只有 id / tags / 事件时刻 / 写入时刻 / 长度，没有正文。S1-T 的 state 里“What just happened”
    写的是“多久以前 + 原文”（产品 Mind.ago），不再是 S1-N 那样的 `At <UTC> (UTC), ` 前缀，所以 s1q.build_documents 的
    “按时刻串对上”在 S1-T 上用不了。这里改为：对每份 state 的每一条近期经历，找事件时刻不晚于该 state、
    且 Mind.ago(事件时刻, now) 与这一条的前缀相同（now 取 state 文件名时刻往前 15 秒内的任一毫秒——Life 算 now 在召回之前）、
    且 `At <事件时刻 ISO 毫秒> (UTC), <原文>`（产品 Life.dated/1 的写法）的长度等于文档 text_length 的文档；
    每份文档必须恰好对上一种正文，否则停下列出。旧脚本 s1q / s1v / s1x 一行不改。
  - 人名：文档正文与 state 里 `<名字> (actor <cid>)` 的写法；被拆屋的人 = kind:event 文档的 actor tag；
    “另一个人” = 文档 actor tag 里除他与自己以外唯一的 cid。建筑名取 state `Current situation` 栏的 `My building "<名>"`。

反思时刻的规则（计划“反思时刻由规则从真实经历序列算出”一节，补充按统筹会话的说明）
  每份文档按 tags 打分：kind:event 8、kind:conversation 5、kind:sight 3、kind:activity 且带任一 actor: tag 3、
  其余 kind:activity 1（出现别的 kind 就停）。经历时刻取 retain_params.event_date，按它排序。
  kind:event 的文档到来即“立即触发”；累计分 >= 20 触发；触发后累计清零；距上一次触发不足现实 5 分钟时不触发，
  条件保留到满 5 分钟后的第一条经历上触发；触发时刻 t = 触发它的那条经历的时刻。取前 5 个时刻做 5 轮。
  一轮反思的“此刻”t′ = t 之后第一份 state 的时刻（计划“运行前补记”第 1 条；t 与 t′ 都留在 moments.json）：
  经历副本库截到 created_at <= t′；召回的 query_timestamp 与“多久以前”都以 t′ 为现在；Right now 用 t′ 那份 state 与
  t′ 之前最近的一份 rawobs；存进反思库的正文 `At <t′> (UTC), I thought it over:` 与 timestamp 也用 t′。
  t 到 t′ 之间发生的经历在那份 state 的 What just happened 里照给。
  “无人 state” = `Current situation` 栏写着 `Nobody else is nearby` 的 state。
  V = 被拆屋的人在场（state 的 Nearby）、在拆屋之后、index.tsv 里这份 state 的选择成功（top1 不是 FAILED、file 列不是 MISMATCH）
      的第一份 state；T = 另一个人第二次在 6 米内到场（连续在 6 米内的 state 算一次到场）后的第一份 state。
      两者都与 s1t/seg3-report.md 的逐次表核对（表里第一行“在场者”写着该人名字的那份），不一致就报告。
      V / T 的新栏放“此刻 t′ 不晚于该 state 的最近一轮”结束时的各条。
  一轮“问哪几件事”：t′ 那份 state 的 `Current situation` 里每座“我的建筑”一问（Q_place），`Feelings and relationships`
  栏里出现的每个 actor 一问（Q_person），Q_self 一问；只问自上一轮以来有新经历的对象——新经历 = 事件时刻在
  (上一轮 t′, 这一轮 t′] 内的文档（Q_place / Q_person 要带相应 place: / actor: tag；Q_self 有任何一份即可）。
  建筑或人多于一个（问题会超过 3 个）就停下报告，不自己截。
  同一轮内按 Q_place -> Q_person -> Q_self 串行（补记第 2 条）：每问写完、检查通过就立即存反思库并从反思库读回；
  后写的那问的 About other things 是其它问题各自字面上最新的一条（含本轮刚存下的前几问），About this 仍是同一问题
  此前最近一次存下的那条；被丢弃的那一问不算最新（仍用它更早的那条，没有就不出现）。
  代码检查（补记第 3 条）：句数 > 4、`Used:` 行缺失、Used 编号不在 What happened 里（Used 行一个编号都没有也算），
  任一项不合格就原样重问一次；每问至多重问一次；重问后仍有任一项不合格就丢弃这一问。
  reflections/<k>-<问题>.json 里 attempts 逐次记原文、check 与 failures（不合格原因），reask_reason 是第一次的原因，
  discarded_reason 是丢弃时重问的原因。

各子命令（读数全部落 .demo/observe/npc-slice1-20261112/s1x2/；可分阶段、可重入，每步落盘，失败即停并报原因，不自动重试）
  纯离线
    moments            算全部触发时刻 t 与各轮的此刻 t′，写 moments.json（冻结；之后各轮按它跑，导出变了而轮已开跑就停），
                       打印一张表（库内文档数按 t′ 算）与 V / T 处境 state 的定位及核对。
    render-now <k>     渲染第 k 轮的 `Right now` 一块，落 rounds/<k>/right-now.txt 并打印。
    selftest           纯函数自检（句数、Markdown、元话语词、Used 解析、伤病写词、rawobs 解析、触发规则、
                       不合格就重问一次 / 丢弃（假的模型输出）、同一轮串行时“之前的想法”的取法（内存里的假反思）、
                       新栏插入位置——插入只在内存里做，不落盘）。
    judge-pack         把盲判要用的东西整理到 judge/：每轮每条日记正文、当轮四块材料、同题额外的 2 条。
                       不放期望、计划原文、系统提示词、机器判读结果。
    check              只用落盘的读数重算机器判读与汇总，写 results.json 的 check 一节。
  需要网络（本次只写不跑；都有 --dry-run：只构造、不发送，打印请求数与第一个请求体摘要，落 dryrun/）
    setup              GET /banks 确认两个库都不存在（存在就停，不删）；按产品 Life.Hindsight.ensure/2 建经历副本库
                       s1x2-copy-20261113 与反思库 s1x2-refl-20261113（PUT name + bank mission、PATCH /config 两条 mission、
                       逐份 GET -> 404 -> POST 四份认识并等 operation）。建之前核对这些常量与导出的 bank 配置 / 认识一致。
    round <k>          第 k 轮：增量重放 created_at <= t′ 的真实文档进副本库（按实跑的写入分钟分批，async false）并等巩固
                       -> 定问题 -> 从反思库按 document_id 读回之前各轮的想法 -> 按 Q_place、Q_person、Q_self 逐问：
                       两次召回取材料 -> 写 -> 代码检查（不合格原样重问一次，仍不合格就丢弃）-> 通过的立即存反思库、
                       等巩固、按 document_id 读回 -> 下一问 -> 轮末核对副本库事实数 / 认识数在存反思前后不变 -> 落盘。
                       --dry-run 时 k 可写 all。
    extra              第 1 轮与最后一轮，每个进了这一轮的问题再写 2 次（同一系统提示词与用户消息；只读数，不存、不带进下一轮）。
    jev                全部变体每个问 Jev 4 次：N<k>_R0 / N<k>_col（每轮），V_R0 / V_col、T_R0 / T_col。
    forced             只读：本测量开始以来 Hindsight 容器日志里 `Forced step` 且 `returned no tool call` 的行数（docker logs）。

怎么运行（Git Bash；仓库根下）
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py moments
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py render-now 1
  python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py round all --dry-run
  MAGPIE_KEY=... python -I -B -X utf8 docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py round 1
  TYPESAFE_API_URL=... TYPESAFE_API_KEY=... TYPESAFE_MODEL=... python -I -B -X utf8 .../s1x2_reflect.py jev
  凭据只从进程环境变量读（网关 MAGPIE_KEY；Jev TYPESAFE_API_URL / TYPESAFE_API_KEY / TYPESAFE_MODEL），不读 .env、不落盘、不打印。
并发与超时
  Hindsight 在途 <= 3（s1q.Hindsight 的信号量；同一问的两次召回并发），网关在途 <= 2（本脚本一轮内逐问串行写，实际 1），
  Jev <= 3；单请求都有超时。
  401 / 403 / 429、正文含 quota、连接错误：立即停在当前阶段并打印原文，不重试。
"""

import argparse
import datetime
import difflib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s1x_reflect as s1x  # noqa: E402  导入时它把 s1v 的落盘目录指到 s1x/；下面重新指到 s1x2/

s1v = s1x.s1v
s1q = s1x.s1q

# ---------------------------------------------------------------- 路径

S1 = s1q.S1
S1T = S1 / "s1t"
EXPORT = S1T / "export"
STATES_DIR = S1T / "states"
INDEX_TSV = STATES_DIR / "index.tsv"
RAWOBS_DIR = EXPORT / "rawobs"
DOCS_LIST = EXPORT / "hindsight-documents-list.json"
BANK_CONFIG = EXPORT / "hindsight-bank-config.json"
TEMPLATE = EXPORT / "request-template.json"
SEG3_REPORT = S1T / "seg3-report.md"

OUT = S1 / "s1x2"
RAW = OUT / "raw"
ROUNDS = OUT / "rounds"
REFLECTIONS = OUT / "reflections"
EXTRA_DIR = OUT / "extra"
VARIANTS_DIR = OUT / "variants"
JUDGE = OUT / "judge"
DRYRUN = OUT / "dryrun"
MOMENTS = OUT / "moments.json"
REPLAYED = OUT / "replayed.json"
STORED = OUT / "stored.json"
SYSTEM_PROMPT_FILE = OUT / "system-prompt.txt"
RESULTS = OUT / "results.json"
LOG = OUT / "run.log"

COPY_BANK = "s1x2-copy-20261113"
REFL_BANK = "s1x2-refl-20261113"
OWN_BANKS = (COPY_BANK, REFL_BANK)

# s1v / s1q 的模块级落盘路径（save、Hindsight.call 的原始返回）指到本目录，不碰 s1x/、s1v/、s1q/。
s1v.configure(COPY_BANK, str(OUT))
s1q.RAW = RAW

# ---------------------------------------------------------------- 规则与上限（计划原文的取值）

MAX_ROUNDS = 5
SCORE_EVENT, SCORE_CONVERSATION, SCORE_SIGHT, SCORE_ACTIVITY_WITH_ACTOR, SCORE_ACTIVITY = 8, 5, 3, 3, 1
TRIGGER_SCORE = 20
MIN_GAP_MS = 5 * 60 * 1000
NOW_WINDOW_MS = 15_000      # 对文档原文时 state 的 now 可能早于文件名时刻的上限（Life 在召回之前取 now；实测 recall_ms 至多约 9 s）
NEAR_M = 6.0                # T 处境“5 米到场”的判法：Nearby 距离 <= 6 米（产品经历里 “came within 6 m” 的界）
MAX_COLUMN_ENTRIES = 4
MAX_SENTENCES = 4
EXTRA_REPEATS = 2

LLM_URL = s1x.LLM_URL
LLM_MODEL = s1x.LLM_MODEL
LLM_MAX_TOKENS = 400
LLM_TIMEOUT_S = 120
RAW_TYPES, RAW_MAX_TOKENS = ["experience", "world"], 1500
OBS_TYPES, OBS_MAX_TOKENS = ["observation"], 800
RETAIN_TIMEOUT_S = 300
REPLAY_CAP_S = 25 * 60
STORE_CAP_S = 10 * 60
OPERATION_CAP_S = 10 * 60
POLL_S = 5
JEV_REPEATS = 4
JEV_WORKERS = 3
JEV_TIMEOUT_S = 60
CONTAINER = s1x.CONTAINER   # npc-s1g-hindsight-20261113（S1-T 用的同一个容器，见 s1t/scripts/hindsight-s1t.sh）

# ---------------------------------------------------------------- 提示词（plan.md 定稿原文，不改）

SYSTEM_TEMPLATE = """You are this person: <character>

You have a quiet moment to yourself and are writing a few lines in your own journal. Nobody else will ever read it. You write to get your own thinking straight, and you will read these lines again later when you decide what to do with your days.

You will be given four things. First, how things stand right now: these are plain facts about this moment, and where they differ from what you remember, right now is what is true. Second, things you remember: what you did, what you saw, what others did to you or said to you, each with roughly how long ago it was. They are your own memories, not a file and not a report. Third, lines you wrote in this journal before: they are what you thought then, not facts, and you may have been wrong. Last, one thing to think over.

Write what you now think about it, in your own voice, in the first person, in plain connected sentences, the way you would mutter to yourself. If what has happened since, or how things stand right now, no longer fits what you wrote before, say what you think now. If two of your earlier thoughts would have you do opposite things, make up your mind between them. End with what you will actually do next. Four sentences at most.

Stay with what you actually remember and how things stand right now. Do not add events, people, numbers or times that are not there. Where you do not know something, say so the way a person would, for example: "I don't know whether he came back after that."

Write only the journal lines: no headings, no lists, nothing about memories, records, data, notes or summaries as such, and no account of how you reasoned.

Here are three journal entries written by other people, only to show the kind of voice. Their lives are not yours; take nothing from what they say.
<example>The nets came up half empty again, three mornings now. I think the shoal has moved past the point, and I would rather row an hour further than sit here hoping. Tomorrow I try the north bank.</example>
<example>Mira paid back the flour she owed, and a day early. I was wrong to grumble about her. Next time she asks I will lend without making her wait.</example>
<example>The beam I set last week has not shifted. Good. I still do not trust the east wall, and I will hang nothing heavy on it until I have seen it through a storm.</example>"""

# 用户消息：第一块 Right now 由 right_now_block 渲染（含 `Right now:` 标题与其下三行）。
USER_TEMPLATE = """{right_now}

What happened:
{lines}

What I thought before (my own earlier thoughts, not facts):
About this: {this}
About other things: {others}

To think over now: {question}

After the journal lines, add one last line that starts with "Used:" and lists the numbers of the things under "What happened" that you drew on."""

USED_INSTRUCTION = USER_TEMPLATE.rsplit("\n\n", 1)[1]
NOTHING_YET = "nothing yet"

Q_PLACE = ('My building "{name}": what has actually happened there, where do things stand with it now, '
           'and what exactly will I do about it next?')
Q_PERSON = ("{name} (actor {cid}): what have they actually done around me, where do things stand between us now, "
            "and how exactly will I act the next time they are near?")
Q_SELF = ("How I have been spending my time lately: what came of it, and what exactly will I keep doing "
          "or do differently from here?")
QUESTION_ORDER = ("Q_place", "Q_person", "Q_self")

# 存进反思库的正文：`At <t 的 UTC> (UTC), I thought it over: <日记>`；读回时去掉这个前缀。
REFLECTION_PREFIX = "At {t} (UTC), I thought it over: "
REFLECTION_PREFIX_RE = re.compile(r"^At \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \(UTC\), I thought it over: ")

# 伤病标签 -> 英文词（标签集合取自 apps/scene_server/lib/scene_server/body.ex 的 injuries/1，照标签原词，不写严重度与因果）。
INJURY_WORDS = {
    "temperature.hypothermia": "hypothermia",
    "temperature.hyperthermia": "hyperthermia",
    "trauma.thermal.burn": "a burn",
    "trauma.thermal.frostbite": "frostbite",
    "nutrition.hunger": "hunger",
    "recovery.weakness": "weakness",
    "nervous.daze": "a daze",
}
MECHANICAL_INJURY = re.compile(r"^trauma\.mechanical\.(head|torso|legs)$")

# 只记录：日记里的机器词（坐标、日号、钟点、id、材料号、活动名这类）。
MACHINE_WORDS = re.compile(
    r"\(\s*-?\d+(?:\.\d+)?,\s*-?\d+(?:\.\d+)?,\s*-?\d+(?:\.\d+)?\s*\)|\b[xyz]=\s*-?\d|\bday \d+\b|\bactor \d+\b"
    r"|\bmaterial \d+\b|\btransaction \d+\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}:\d{2}\b|\b\d{4,}\b|\b[a-z]+_[a-z_]+\b", re.I)


# ---------------------------------------------------------------- 小工具

class Stop(SystemExit):
    """失败即停：带原因退出，不重试。"""


def log(line):
    OUT.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a", encoding="utf8") as f:
        f.write(f"{s1q.now_iso()} {line}\n")
    print(line, flush=True)


def stop(msg):
    log(f"STOP {msg}")
    raise Stop(msg)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=1), encoding="utf8")
    os.replace(tmp, path)


def read_json(path):
    return json.loads(path.read_text(encoding="utf8"))


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.encode("utf8"))


def save_result(key, value):
    s1v.save(key, value)  # s1v.RESULTS 已指到 s1x2/results.json


def iso_ms(iso):
    return s1x.iso_ms(iso)


def ms_iso(ms):
    return s1q.ms_to_iso(ms)


def hms(ms):
    return ms_iso(ms)[11:23]


FILE_STAMP = re.compile(r"(\d{8})T(\d{2})(\d{2})(\d{2})\.(\d{3})Z")


def file_ms(name):
    d, hh, mm, ss, frac = FILE_STAMP.search(name).groups()
    return iso_ms(f"{d[:4]}-{d[4:6]}-{d[6:]}T{hh}:{mm}:{ss}.{frac}Z")


def dated(at_ms, text):
    """产品 Life.dated/1：交给 Hindsight 的经历正文。"""
    return f"At {ms_iso(at_ms)} (UTC), {text}"


def one_line(text):
    return s1x.one_line(text)


def unique(seq):
    out = []
    for x in seq:
        if x not in out:
            out.append(x)
    return out


def safe_name(text):
    return re.sub(r"[^\w.-]+", "_", text)


# ---------------------------------------------------------------- state

STATE_TITLES = ("Now",) + s1q.TITLES
NOW, CHARACTER, FEELINGS, SITUATION = "Now", "Character", "Feelings and relationships", "Current situation"
WJH, MEM = s1q.WJH, s1q.MEM
AGO_PREFIX = re.compile(r"(Just now, |About \d+(?:\.5)? hours? ago, |About \d+ days? ago, )")
NEARBY = re.compile(r"(?:Nearby: |; )(.+?) \((player|NPC), actor (\d+), (\d+(?:\.\d+)?) m away\)")
BUILDING = re.compile(r'My building "([^"]+)" at \(')
ACTOR_ID = re.compile(r"\bactor (\d+)\b")
NAMED_ACTOR = re.compile(r"\b([A-Z][\w'-]*(?: [A-Z][\w'-]*)*) \(actor (\d+)\)")


def state_sections(text):
    """[(栏名, [行])]：一栏从 `<栏名>: ` 开头的行起，到下一栏开头之前；栏的次序必须是产品 Mind.snapshot 的次序。"""
    out = []
    for line in text.split("\n"):
        title = next((t for t in STATE_TITLES if line.startswith(t + ": ")), None)
        if title and title not in [s[0] for s in out]:
            out.append((title, [line]))
        elif out:
            out[-1][1].append(line)
        else:
            raise ValueError("state 的第一行不是栏")
    if tuple(t for t, _ in out) != STATE_TITLES:
        raise ValueError(f"栏的次序不是 {STATE_TITLES}: {[t for t, _ in out]}")
    return out


@dataclass
class State:
    path: Path
    asked_ms: int
    text: str
    sections: list

    @property
    def name(self):
        return self.path.name

    def body(self, title):
        lines = dict(self.sections)[title]
        return "\n".join(lines)[len(title) + 2:]

    def nobody(self):
        return "Nobody else is nearby." in self.body(SITUATION)

    def nearby(self):
        """[(名字, kind, cid, 距离米)]，取自 Current situation 的 Nearby。"""
        return [(n, k, cid, float(d)) for n, k, cid, d in NEARBY.findall(self.body(SITUATION))]

    def buildings(self):
        return unique(BUILDING.findall(self.body(SITUATION)))

    def related(self):
        return unique(ACTOR_ID.findall(self.body(FEELINGS)))

    def recent_items(self):
        """What just happened 的各条：[(多久以前的前缀, 原文)]，旧在前。"""
        body = self.body(WJH)
        if body == "Nothing new.":
            return []
        if not body.startswith("Oldest first. "):
            raise ValueError(f"{self.name}: What just happened 的开头不是 Oldest first.")
        parts = AGO_PREFIX.split(body[len("Oldest first. "):])
        if parts[0].strip():
            raise ValueError(f"{self.name}: What just happened 的第一条没有多久以前的前缀")
        return [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts), 2)]


def load_states():
    states = []
    for p in sorted(STATES_DIR.glob("asked-*.txt")):
        text = p.read_text(encoding="utf8")
        try:
            states.append(State(p, file_ms(p.name), text, state_sections(text)))
        except ValueError as e:
            stop(f"state {p.name}: {e}")
    return sorted(states, key=lambda s: s.asked_ms)


def load_index():
    """index.tsv：{state 文件名: top1}，只收 file 列与这次选择对上的行（MISMATCH: 与 - 不收）。"""
    lines = INDEX_TSV.read_text(encoding="utf8").splitlines()
    head = lines[0].split("\t")
    out = {}
    for line in lines[1:]:
        row = dict(zip(head, line.split("\t")))
        f = row.get("file", "")
        if f.startswith("asked-"):
            out[f] = row.get("top1", "")
    return out


# ---------------------------------------------------------------- 文档（真实 bank 的导出 + state 里的原文）

@dataclass
class Doc:
    id: str
    event_ms: int
    created_ms: int
    created_at: str
    tags: list
    text_length: int
    content: str = None

    def actors(self):
        return [t.split(":", 1)[1] for t in self.tags if t.startswith("actor:")]


def load_documents(states):
    raw = read_json(DOCS_LIST)
    items = raw["items"]
    if raw.get("total") != len(items):
        stop(f"文档列表不完整：total={raw.get('total')} items={len(items)}")
    docs = [Doc(d["id"], iso_ms(d["retain_params"]["event_date"]), iso_ms(d["created_at"]), d["created_at"],
                list(d["tags"]), d["text_length"]) for d in items]
    stamp_len = len(dated(0, ""))
    by_len = {}
    for d in docs:
        by_len.setdefault(d.text_length - stamp_len, []).append(d)
    found = {d.id: set() for d in docs}
    for s in states:
        try:
            pieces = s.recent_items()
        except ValueError as e:
            stop(str(e))
        for prefix, text in pieces:
            for d in by_len.get(len(text), []):
                if d.event_ms > s.asked_ms:
                    continue
                nows = range(s.asked_ms - NOW_WINDOW_MS, s.asked_ms + 1, 250)
                if any(s1x.ago(d.event_ms, now) == prefix for now in nows):
                    found[d.id].add(dated(d.event_ms, text))
    bad = {i: sorted(c) for i, c in found.items() if len(c) != 1}
    if bad:
        stop("文档原文对不上（0 个或多于 1 个候选）：" + json.dumps(bad, ensure_ascii=False)[:2000])
    for d in docs:
        (d.content,) = found[d.id]
        assert len(d.content) == d.text_length
    return sorted(docs, key=lambda d: (d.event_ms, d.id))


def replay_batches(docs):
    """同 s1q.build_documents：按实跑写入时刻的分钟分批，批内按事件时刻旧在前。"""
    batches = {}
    for d in docs:
        batches.setdefault(d.created_at[:16], []).append(d)
    return [(k, sorted(batches[k], key=lambda d: (d.event_ms, d.id))) for k in sorted(batches)]


def self_cid():
    banks = {d["bank_id"] for d in read_json(DOCS_LIST)["items"]}
    if len(banks) != 1:
        stop(f"文档列表里的 bank 不止一个：{banks}")
    return banks.pop().rsplit("-", 1)[1]


def actor_names(docs, states):
    """{cid: 名字}：先取 state `Nearby` 里产品写的名字（Life.State.person_name）；Nearby 里没出现过的 cid，
    再取文档正文里 `<名字> (actor <cid>)` 的写法。同一来源里同一 cid 出现两种名字就停。"""
    def collect(pairs):
        seen = {}
        for name, cid in pairs:
            seen.setdefault(cid, set()).add(name)
        clash = {c: sorted(n) for c, n in seen.items() if len(n) > 1}
        if clash:
            stop(f"同一 actor 有不同的名字：{clash}")
        return {c: n.pop() for c, n in seen.items()}
    from_nearby = collect((name, cid) for s in states for name, _, cid, _ in s.nearby())
    from_docs = collect(p for d in docs for p in NAMED_ACTOR.findall(d.content) if p[1] not in from_nearby)
    return {**from_docs, **from_nearby}


# ---------------------------------------------------------------- rawobs（Elixir inspect 文本，只取需要的量）

@dataclass
class RawObs:
    path: Path
    ms: int
    day: int
    life: float
    injuries: list


def bracket_span(text, start, open_ch, close_ch):
    """text[start] 是 open_ch；返回与之配对的 close_ch 之后的下标（不处理字符串里的括号：这里的值没有）。"""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("括号不配对")


def parse_rawobs(path):
    text = path.read_text(encoding="utf8")
    day = re.search(r"world_time: %\{day: (\d+)", text)
    i = text.find("body_state: ")
    if not day or i < 0:
        raise ValueError(f"{path.name}: 没有 world_time.day 或 body_state")
    j = i + len("body_state: ")
    if text.startswith("nil", j):
        raise ValueError(f"{path.name}: body_state 是 nil（Life 还没收到身体状态）")
    if not text.startswith("%{", j):
        raise ValueError(f"{path.name}: body_state 不是 map")
    body = text[j + 1:bracket_span(text, j + 1, "{", "}")]
    life = re.search(r"\blife: (-?\d+(?:\.\d+)?)", body)
    k = body.find("injuries: [")
    if not life or k < 0:
        raise ValueError(f"{path.name}: body_state 里没有 life 或 injuries")
    k += len("injuries: ")
    inj = body[k:bracket_span(body, k, "[", "]")]
    return RawObs(path, file_ms(path.name), int(day.group(1)), float(life.group(1)), re.findall(r'tag: "([^"]+)"', inj))


def load_rawobs():
    out = []
    for p in sorted(RAWOBS_DIR.glob("rawobs-*.txt")):
        try:
            out.append(parse_rawobs(p))
        except ValueError as e:
            stop(str(e))
    return sorted(out, key=lambda r: r.ms)


def injury_word(tag):
    if tag in INJURY_WORDS:
        return INJURY_WORDS[tag]
    m = MECHANICAL_INJURY.match(tag)
    if m:
        return f"an injury to the {m.group(1)}"
    raise ValueError(f"未知的伤病标签 {tag}（apps/scene_server body.ex 的 injuries/1 里没有）")


def join_words(words):
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + " and " + words[-1]


def body_sentence(life, injury_tags):
    """身体一句：生命与伤病的词（原创写法，量是真实的；不写开尔文数、不写因果）。"""
    words = [injury_word(t) for t in injury_tags]
    tail = "no injuries or ailments" if not words else "with " + join_words(words)
    return f"My body: life {round(life)} of 100, {tail}."


def right_now_block(state, obs):
    """第一块：`Now:` 一行原文去掉栏名 + 日号一句；`Current situation` 一栏原文（去掉栏名）；身体一句。"""
    return (f"Right now:\n{state.body(NOW)} It is day {obs.day}.\n{state.body(SITUATION)}\n"
            f"{body_sentence(obs.life, obs.injuries)}")


# ---------------------------------------------------------------- 触发时刻

def experience_score(doc):
    kinds = [t for t in doc.tags if t.startswith("kind:")]
    if "kind:event" in kinds:
        return SCORE_EVENT, "event"
    if "kind:conversation" in kinds:
        return SCORE_CONVERSATION, "conversation"
    if "kind:sight" in kinds:
        return SCORE_SIGHT, "sight"
    if kinds == ["kind:activity"]:
        return (SCORE_ACTIVITY_WITH_ACTOR, "activity_with_actor") if doc.actors() else (SCORE_ACTIVITY, "activity")
    stop(f"文档 {doc.id} 的 kind 不在打分表里：{kinds}")


def compute_moments(docs):
    """按事件时刻走一遍真实经历序列，返回全部触发时刻。"""
    moments, acc, last_ms, held = [], 0, None, []
    for d in docs:
        points, kind = experience_score(d)
        acc += points
        # 记下触发条件：每次 kind:event 都记；累计分只记第一次越过阈值（保留期间后续的经历不重复记）
        if kind == "event":
            held.append(dict(cause="immediate (kind:event)", at=ms_iso(d.event_ms), doc_id=d.id))
        elif acc >= TRIGGER_SCORE and not any(c["cause"].startswith("score") for c in held):
            held.append(dict(cause=f"score {acc} >= {TRIGGER_SCORE}", at=ms_iso(d.event_ms), doc_id=d.id))
        if not held:
            continue
        if last_ms is not None and d.event_ms - last_ms < MIN_GAP_MS:
            continue  # 条件保留，等满 5 分钟后的第一条经历
        moments.append(dict(n=len(moments) + 1, t_ms=d.event_ms, t=ms_iso(d.event_ms), doc_id=d.id, doc_kind=kind,
                            score=acc, causes=held,
                            held_by_gap=held[0]["at"] != ms_iso(d.event_ms) or held[0]["doc_id"] != d.id))
        acc, last_ms, held = 0, d.event_ms, []
    return moments


# ---------------------------------------------------------------- 输入汇总、每轮的离线计划

class Inputs:
    """一次读入全部真实导出，算出触发时刻与处境定位。"""

    def __init__(self):
        self.states = load_states()
        self.index = load_index()
        self.docs = load_documents(self.states)
        self.rawobs = load_rawobs()
        self.self_cid = self_cid()
        self.names = actor_names(self.docs, self.states)
        self.moments = compute_moments(self.docs)
        self.wrecker, self.visitor, self.wreck_ms = self.people()
        self.v_state, self.t_state = self.locate_v(), self.locate_t()

    def people(self):
        events = [d for d in self.docs if "kind:event" in d.tags]
        if not events:
            stop("导出里没有 kind:event 文档（没有拆屋事件）")
        wreckers = unique(events[0].actors())
        if len(wreckers) != 1:
            stop(f"第一份 kind:event 文档的 actor 不是一个：{wreckers}")
        others = unique(a for d in self.docs for a in d.actors() if a not in (wreckers[0], self.self_cid))
        if len(others) != 1:
            stop(f"除拆屋者外的 actor 不是一个：{others}")
        return wreckers[0], others[0], events[0].event_ms

    def locate_v(self):
        for s in self.states:
            if s.asked_ms > self.wreck_ms and any(c == self.wrecker for _, _, c, _ in s.nearby()):
                top1 = self.index.get(s.name)
                if top1 and not top1.startswith("FAILED"):
                    return s
        return None

    def locate_t(self):
        episodes, was_near = [], False
        for s in self.states:
            near = any(c == self.visitor and d <= NEAR_M for _, _, c, d in s.nearby())
            if near and not was_near:
                episodes.append(s)
            was_near = near
        return episodes[1] if len(episodes) >= 2 else None

    def report_check(self):
        """与 seg3-report.md 的逐次表核对 V / T：表里第一行“在场者”写着该人名字的那份 state。"""
        if not SEG3_REPORT.exists():
            return dict(status="seg3-report.md 不存在，未核对")
        rows = []
        for line in SEG3_REPORT.read_text(encoding="utf8").splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 8 and re.fullmatch(r"`T\d{6}\.\d{3}`", cells[7]):
                rows.append(cells)
        out = {}
        for label, cid, found in (("V", self.wrecker, self.v_state), ("T", self.visitor, self.t_state)):
            name = self.names.get(cid, "?")
            row = next((r for r in rows if name in r[6]), None)
            want = row[7].strip("`") if row else None
            got = "T" + FILE_STAMP.search(found.name).group(0)[9:-1] if found else None  # 同表里的 `T164357.820` 写法
            out[label] = dict(person=name, located=found.name if found else None, report_row=row[0] if row else None,
                              report_state=want, agree=bool(want and got and want == got))
        return out

    def state_after(self, k):
        """第 k 轮触发时刻 t 之后的第一份 state；它的时刻就是这一轮反思的“此刻”t′（补记第 1 条）。"""
        t = self.moments[k - 1]["t_ms"]
        return next((s for s in self.states if s.asked_ms > t), None)

    def round_plan(self, k):
        """第 k 轮（1 起）的离线计划：触发时刻 t 与此刻 t′、各 state / rawobs、库里已有的文档、要问的问题。

        四块材料对的是同一刻 t′：副本库截到 created_at <= t′，召回的 query_timestamp 与“多久以前”都以 t′ 为现在，
        Right now 用 t′ 那份 state 与 t′ 之前最近的一份 rawobs，“有新经历”的区间是（上一轮的 t′，本轮的 t′]。"""
        if not 1 <= k <= min(MAX_ROUNDS, len(self.moments)):
            stop(f"第 {k} 轮不存在：规则给出 {len(self.moments)} 个时刻，至多做 {MAX_ROUNDS} 轮")
        m = self.moments[k - 1]
        t = m["t_ms"]
        after = self.state_after(k)
        prev = self.state_after(k - 1) if k > 1 else None
        if not after or (k > 1 and not prev):
            stop(f"第 {k} 轮缺输入：t 之后没有 state（本轮 {after and after.name}，上一轮 {prev and prev.name}）")
        now, now_prev = after.asked_ms, prev.asked_ms if prev else None
        nobody = next((s for s in self.states if s.asked_ms > t and s.nobody()), None)
        obs = next((r for r in reversed(self.rawobs) if r.ms <= now), None)
        if not nobody or not obs:
            stop(f"第 {k} 轮缺输入：无人 state={nobody and nobody.name} t′ 之前的 rawobs={obs and obs.path.name}")
        library = [d for d in self.docs if d.created_ms <= now]
        new = [d for d in self.docs if (now_prev is None or d.event_ms > now_prev) and d.event_ms <= now]
        return dict(k=k, t_ms=t, t=ms_iso(t), now_ms=now, now=ms_iso(now),
                    now_prev=ms_iso(now_prev) if now_prev else None, moment=m,
                    state=after, nobody_state=nobody, rawobs=obs, library=library,
                    # t 到 t′ 之间写进真实库的文档：现在随副本库截到 t′ 一起进库
                    gap_docs=[d for d in self.docs if t < d.created_ms <= now],
                    # 写入时刻在 t′ 之前 NOW_WINDOW_MS 内的文档：state 的 now 可能早于文件名时刻，
                    # 这些文档可能同时出现在 What just happened 与召回里（只记数，不处理）
                    near_now_docs=[d.id for d in self.docs if now - NOW_WINDOW_MS < d.created_ms <= now],
                    unsealed_after_t=sum(1 for d in self.docs if t < d.event_ms <= now and d.created_ms > now),
                    questions=self.pick_questions(after, new))

    def pick_questions(self, state, new_docs):
        buildings, people = state.buildings(), state.related()
        if len(buildings) > 1 or len(people) > 1:
            stop(f"{state.name}: 建筑 {buildings}、有关系的人 {people}——问题会超过计划的“至多 3 问”，不自己截")
        out = []
        for b in buildings:
            tag = f"place:{b}"
            out.append(dict(key="Q_place", text=Q_PLACE.format(name=b), tags=[tag],
                            new=[d.id for d in new_docs if tag in d.tags]))
        for cid in people:
            if cid not in self.names:
                stop(f"actor {cid} 在导出里找不到名字")
            tag = f"actor:{cid}"
            out.append(dict(key="Q_person", text=Q_PERSON.format(name=self.names[cid], cid=cid), tags=[tag],
                            new=[d.id for d in new_docs if tag in d.tags]))
        out.append(dict(key="Q_self", text=Q_SELF, tags=[], new=[d.id for d in new_docs]))
        for q in out:
            q["asked"] = bool(q["new"])
        return out


def moments_record(inp):
    rounds = []
    for k in range(1, min(MAX_ROUNDS, len(inp.moments)) + 1):
        p = inp.round_plan(k)
        rounds.append(dict(k=k, t=p["t"], now=p["now"], state=p["state"].name, nobody_state=p["nobody_state"].name,
                           rawobs=p["rawobs"].path.name, library_documents=len(p["library"]),
                           gap_documents=[d.id for d in p["gap_docs"]], near_now_documents=p["near_now_docs"],
                           unsealed_after_t=p["unsealed_after_t"],
                           questions=[dict(key=q["key"], text=q["text"], tags=q["tags"], asked=q["asked"],
                                           new_documents=len(q["new"])) for q in p["questions"]]))
    return dict(rule=dict(scores=dict(event=SCORE_EVENT, conversation=SCORE_CONVERSATION, sight=SCORE_SIGHT,
                                      activity_with_actor=SCORE_ACTIVITY_WITH_ACTOR, activity=SCORE_ACTIVITY),
                          trigger_score=TRIGGER_SCORE, min_gap_ms=MIN_GAP_MS, max_rounds=MAX_ROUNDS),
                export=dict(documents=len(inp.docs), last_created_at=max(d.created_at for d in inp.docs),
                            states=len(inp.states), rawobs=len(inp.rawobs)),
                self_cid=inp.self_cid, names=inp.names, wrecker=inp.wrecker, visitor=inp.visitor,
                moments=inp.moments, rounds=rounds,
                situations=dict(V=inp.v_state.name if inp.v_state else None,
                                T=inp.t_state.name if inp.t_state else None, check=inp.report_check()))


def frozen_moments(inp):
    """round 等阶段按冻结的 moments.json 跑；导出变了（时刻或问题不同）就停，免得半路换输入。"""
    if not MOMENTS.exists():
        stop("先跑 moments")
    frozen, now = read_json(MOMENTS), moments_record(inp)
    keys = ("moments", "rounds", "situations")
    if any(json.dumps(frozen[k], sort_keys=True) != json.dumps(now[k], sort_keys=True) for k in keys):
        stop("导出与 moments.json 不一致（时刻 / 轮 / 处境变了）；先确认是否重跑 moments")
    return frozen


# ---------------------------------------------------------------- 子命令：moments / render-now

def cmd_moments(a):
    inp = Inputs()
    rec = moments_record(inp)
    started = sorted(p.parent.name for p in ROUNDS.glob("*/plan.json")) if ROUNDS.exists() else []
    if started and MOMENTS.exists() and read_json(MOMENTS)["rounds"] != rec["rounds"]:
        stop(f"已有轮开跑（{started}），新算的时刻与 moments.json 不同；不覆盖")
    write_json(MOMENTS, rec)
    print(f"导出：文档 {rec['export']['documents']} 份（最晚写入 {rec['export']['last_created_at']}），"
          f"state {rec['export']['states']} 份，rawobs {rec['export']['rawobs']} 份；"
          f"自己 {inp.self_cid}；拆屋者 {inp.names.get(inp.wrecker)} {inp.wrecker}；另一人 {inp.names.get(inp.visitor)} {inp.visitor}")
    print(f"规则给出 {len(inp.moments)} 个时刻（做前 {min(MAX_ROUNDS, len(inp.moments))} 个）\n")
    head = ["k", "t (UTC)", "t′ (UTC)", "触发原因", "累计分", "库内文档（截到 t′）", "t′ 的 state", "t 后第一份无人 state",
            "t′ 前最近 rawobs", "问题（括号 = 无新经历跳过）"]
    print(" | ".join(head))
    by_k = {r["k"]: r for r in rec["rounds"]}
    for m in inp.moments:
        causes = "; ".join(f"{c['cause']} @{c['at'][11:23]}" for c in m["causes"])
        if m["held_by_gap"]:
            causes += "（间隔不足 5 分钟，保留到此）"
        r = by_k.get(m["n"])
        if r:
            qs = " ".join(q["key"] if q["asked"] else f"({q['key']})" for q in r["questions"])
            print(f"{m['n']} | {m['t'][11:23]} | {r['now'][11:23]} | {causes} | {m['score']} | {r['library_documents']} | "
                  f"{r['state']} | {r['nobody_state']} | {r['rawobs']} | {qs}")
            if r["gap_documents"] or r["unsealed_after_t"] or r["near_now_documents"]:
                print(f"    注：t 到 t′ 之间写入库的文档 {len(r['gap_documents'])} 份（已随副本库进库）；"
                      f"t′ 那份 state 的近期经历里事件晚于 t 的约 {r['unsealed_after_t']} 条；"
                      f"写入时刻在 t′ 前 {NOW_WINDOW_MS // 1000} s 内的文档 {len(r['near_now_documents'])} 份"
                      f"（可能同时在近期经历与库里）")
        else:
            print(f"{m['n']} | {m['t'][11:23]} | — | {causes} | {m['score']} | （第 {MAX_ROUNDS} 轮之后，不做）")
    sit = rec["situations"]
    print(f"\nV = {sit['V']}  T = {sit['T']}")
    for label, c in sit["check"].items():
        print(f"  核对 {label}: {c}")
    log(f"moments: {len(inp.moments)} 个时刻 -> {MOMENTS}")


def cmd_render_now(a):
    inp = Inputs()
    p = inp.round_plan(int(a.k))
    block = right_now_block(p["state"], p["rawobs"])
    write_text(ROUNDS / str(p["k"]) / "right-now.txt", block)
    print(f"第 {p['k']} 轮 t={p['t']}  t′={p['now']}  state={p['state'].name}  rawobs={p['rawobs'].path.name}\n")
    print(block)


# ---------------------------------------------------------------- 材料与用户消息

def recall_bodies(question, t_iso):
    """每问两次召回（同 S1-X）：原始经历与认识；tag 过滤 any_strict；query_timestamp = 这一轮的此刻 t′。"""
    out = []
    for kind, types, max_tokens in (("raw", RAW_TYPES, RAW_MAX_TOKENS), ("observation", OBS_TYPES, OBS_MAX_TOKENS)):
        body = dict(query=question["text"], budget="mid", types=types, max_tokens=max_tokens, query_timestamp=t_iso)
        if question["tags"]:
            body.update(tags=question["tags"], tags_match="any_strict")
        out.append((kind, body))
    return out


def unsealed_items(state):
    return [dict(kind="unsealed", id=None, at=None, body=prefix + text) for prefix, text in state.recent_items()]


def recalled_items(kind, rows, t_ms):
    """召回条目：去掉 ` | When:` 起的后缀；有时刻就按产品 Mind.ago 写多久以前（相对此刻 t′），没有就不写。"""
    out = []
    for it in rows:
        plain = (it.get("text") or "").split(" | When:", 1)[0]
        at = it.get("occurred_start") or it.get("mentioned_at")
        prefix = s1x.ago(iso_ms(at), t_ms) if at else ""
        out.append(dict(kind=kind, id=it["id"], at=at, type=it.get("type"), tags=it.get("tags"), body=prefix + plain,
                        text=it.get("text")))
    return out


def number_items(groups):
    """未封存在前，再原始经历、认识；召回条目按 id 去重；编号从 1 起。"""
    seen, out = set(), []
    for items in groups:
        for it in items:
            if it["id"] is not None:
                if it["id"] in seen:
                    continue
                seen.add(it["id"])
            out.append(dict(it, n=len(out) + 1, line=f"[{len(out) + 1}] {it['body']}"))
    return out


def thoughts_text(key, latest):
    """之前的想法：同一问题最新的一条；其它问题各自最新的一条，各占一行（第一条接在标签之后）。"""
    this = latest.get(key) or NOTHING_YET
    others = [one_line(latest[q]) for q in QUESTION_ORDER if q != key and latest.get(q)]
    return one_line(this) if this != NOTHING_YET else this, "\n".join(others) if others else NOTHING_YET


def user_message(right_now, lines, this, others, question_text):
    return USER_TEMPLATE.format(right_now=right_now, lines="\n".join(lines), this=this, others=others,
                                question=question_text)


def system_prompt(state):
    return SYSTEM_TEMPLATE.replace("<character>", state.body(CHARACTER))


# ---------------------------------------------------------------- Hindsight（只对本测量的两个库）

def is_timeout(error):
    e = (error or "").lower()
    return "timed out" in e or "timeout" in e


class GuardedHindsight(s1q.Hindsight):
    """s1q.Hindsight（标准库 HTTP、在途 <= 3、不重试）加两道闸：只许本测量的两个库与 GET /banks；
    401 / 403 / 429、正文含 quota、连接错误（以及调用方没声明可容忍的超时）立即停。"""

    def call(self, method, path, body=None, raw_name=None, timeout=s1q.HTTP_TIMEOUT, tolerate_timeout=False):
        allowed = path == "/banks" or any(path == f"/banks/{b}" or path.startswith(f"/banks/{b}/")
                                          or path.startswith(f"/banks/{b}?") for b in OWN_BANKS)
        if not allowed:
            stop(f"拒绝发往本测量以外的路径：{method} {path}")
        out = super().call(method, path, body, raw_name, timeout)
        err = out["error"] or ""
        if out["status"] in (401, 403, 429) or "quota" in err.lower():
            stop(f"Hindsight 额度 / 认证：status={out['status']} {method} {path} error={err}")
        if out["status"] is None and err and not (tolerate_timeout and is_timeout(err)):
            stop(f"Hindsight 连接错误：{method} {path} error={err}")
        return out


class Bank:
    """一个本测量自己的库：建法、写入、等巩固、召回、读文档。"""

    def __init__(self, h, bank_id):
        assert bank_id in OWN_BANKS
        self.h, self.id = h, bank_id

    def path(self, sub=""):
        return f"/banks/{self.id}{sub}"

    def must(self, out, what):
        if not out["ok"]:
            stop(f"{self.id} {what} 失败：{out['error']}")
        return out["json"]

    def ensure(self):
        """同产品 Life.Hindsight.ensure/2（与 s1v.cmd_setup 的建库部分同一做法）。"""
        tag = safe_name(self.id)
        self.must(self.h.call("PUT", self.path(), dict(name=self.id, mission=s1v.BANK_MISSION),
                              raw_name=f"S_{tag}_put.json"), "PUT bank")
        self.must(self.h.call("PATCH", self.path("/config"),
                              dict(updates=dict(retain_mission=s1v.RETAIN_MISSION,
                                                observations_mission=s1v.OBSERVATIONS_MISSION)),
                              raw_name=f"S_{tag}_patch_config.json"), "PATCH /config")
        cfg = self.must(self.h.call("GET", self.path("/config"), raw_name=f"S_{tag}_config.json"), "GET /config")
        cfg = cfg.get("config", {})
        check = dict(retain_mission_equal=cfg.get("retain_mission") == s1v.RETAIN_MISSION,
                     observations_mission_equal=cfg.get("observations_mission") == s1v.OBSERVATIONS_MISSION)
        models = []
        for mid, query in s1v.QUERIES:
            got = self.h.call("GET", f"{self.path('/mental-models/')}{mid}?detail=content",
                              raw_name=f"S_{tag}_model_get_{mid}.json")
            if got["status"] != 404:
                stop(f"{self.id} 认识 {mid} 意外存在或 GET 失败：{got['status']} {got['error']}")
            resp = self.must(self.h.call("POST", self.path("/mental-models"), model_body(mid, query),
                                         raw_name=f"S_{tag}_model_post_{mid}.json"), f"create {mid}")
            w = self.wait_operation(resp.get("operation_id"))
            models.append(dict(id=mid, operation_id=resp.get("operation_id"), **w))
            log(f"{self.id} ensure model {mid}: {w}")
            if w["status"] != "completed":
                stop(f"{self.id} create {mid}: {w}")
        return dict(config_check=check, models=models)

    def wait_operation(self, op_id):
        t0, polls = time.time(), 0
        while True:
            out = self.h.call("GET", f"{self.path('/operations/')}{op_id}")
            polls += 1
            st = (out["json"] or {}).get("status") if out["ok"] else None
            if st == "completed":
                return dict(status=st, seconds=round(time.time() - t0, 1), polls=polls)
            if st in ("failed", "cancelled", "not_found") or not out["ok"]:
                return dict(status=st or "poll_error", seconds=round(time.time() - t0, 1), polls=polls,
                            error=(out["json"] or {}).get("error_message") or out["error"])
            if time.time() - t0 >= OPERATION_CAP_S:
                return dict(status="timeout", seconds=round(time.time() - t0, 1), polls=polls, last=st)
            time.sleep(POLL_S)

    def retain(self, items, raw_name):
        """同步写入（async false，同 s1v 的重放）；超时不算失败（之后等巩固），其它失败即停。"""
        t0 = time.time()
        out = self.h.call("POST", self.path("/memories"), {"items": items, "async": False}, raw_name=raw_name,
                          timeout=RETAIN_TIMEOUT_S, tolerate_timeout=True)
        row = dict(n=len(items), ok=out["ok"], status=out["status"], seconds=round(time.time() - t0, 1),
                   error=out["error"])
        if not out["ok"] and not is_timeout(out["error"]):
            stop(f"{self.id} retain 失败：{out['error']}")
        return row

    def stats(self, raw_name=None):
        # refresh=true：Hindsight 的 /stats 默认走 60 s TTL 的缓存（HINDSIGHT_API_BANK_STATS_CACHE_TTL_SECONDS），
        # 写入后立即读可能拿到写入前的 pending 0 / 0，等巩固会被误判为已做完（第 1 轮反思库实测）；强制重算。
        j = self.must(self.h.call("GET", self.path("/stats?refresh=true"), raw_name=raw_name), "GET /stats")
        return {k: j.get(k) for k in ("total_nodes", "nodes_by_fact_type", "total_documents", "pending_operations",
                                      "pending_consolidation", "failed_operations", "failed_consolidation")}

    def wait_drained(self, cap_s, tag):
        t0, polls = time.time(), []
        while time.time() - t0 < cap_s:
            st = self.stats()
            polls.append(dict(t=round(time.time() - t0, 1), **st))
            if st["pending_operations"] == 0 and st["pending_consolidation"] == 0:
                write_json(RAW / f"{tag}_stats_polls.json", polls)
                return dict(status="drained", seconds=round(time.time() - t0, 1), polls=len(polls), last=st)
            time.sleep(POLL_S)
        write_json(RAW / f"{tag}_stats_polls.json", polls)
        stop(f"{self.id} 等巩固超过 {cap_s} s：{polls[-1] if polls else None}")

    def recall(self, body, raw_name):
        out = self.h.call("POST", self.path("/memories/recall"), body, raw_name=raw_name)
        rows = (out["json"] or {}).get("results") if out["ok"] else None
        if not isinstance(rows, list):
            stop(f"{self.id} recall 失败：{out['error'] or 'no results list'}")
        return rows

    def document_text(self, doc_id):
        out = self.h.call("GET", self.path("/documents/") + urllib.parse.quote(doc_id, safe=""),
                          raw_name=f"D_{safe_name(doc_id)}.json")
        text = (out["json"] or {}).get("original_text") if out["ok"] else None
        if not isinstance(text, str):
            stop(f"{self.id} 读文档 {doc_id} 失败：{out['error'] or 'no original_text'}")
        return text

    def memories(self, tag):
        rows, total = s1q.list_all(self.h, self.id, "/memories/list", "items", tag=tag)
        return rows, total


def model_body(mid, query):
    return dict(id=mid, name=mid, source_query=query + " " + s1v.TRUTH, max_tokens=800,
                trigger=dict(refresh_after_consolidation=False))


def hindsight():
    return GuardedHindsight(s1q.BASE, LOG)


def verify_product_constants():
    """建库常量（取自 s1v，即产品 hindsight.ex 的原文）与 S1-T 导出的真实 bank 配置 / 四份认识核对。"""
    cfg = read_json(BANK_CONFIG)["config"]
    diffs = []
    for key, mine in (("reflect_mission", s1v.BANK_MISSION), ("retain_mission", s1v.RETAIN_MISSION),
                      ("observations_mission", s1v.OBSERVATIONS_MISSION)):
        if cfg.get(key) != mine:
            diffs.append(key)
    for mid, query in s1v.QUERIES:
        m = read_json(EXPORT / f"hindsight-mental-model-{mid}.json")
        want = model_body(mid, query)
        if (m.get("source_query"), m.get("max_tokens"), (m.get("trigger") or {}).get("refresh_after_consolidation")) != \
                (want["source_query"], want["max_tokens"], False):
            diffs.append(f"mental-model {mid}")
    if diffs:
        stop(f"建库常量与导出的真实 bank 不一致：{diffs}")


# ---------------------------------------------------------------- 网关写作

def write_journal(system, user, raw_name):
    """magpie 网关 /v1/messages，不开扩展思考；出错即停（401 / 403 / 429 / quota / 连接 / 其它 HTTP 错误）。"""
    key = os.environ.get("MAGPIE_KEY")
    if not key:
        stop("环境变量 MAGPIE_KEY 没有设置")
    body = dict(model=LLM_MODEL, max_tokens=LLM_MAX_TOKENS, system=system, messages=[dict(role="user", content=user)])
    req = urllib.request.Request(LLM_URL, data=json.dumps(body, ensure_ascii=False).encode("utf8"), method="POST",
                                 headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                                          "content-type": "application/json"})
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=LLM_TIMEOUT_S) as r:
            status, js = r.status, json.loads(r.read().decode("utf8"))
    except urllib.error.HTTPError as e:
        stop(f"网关 HTTP {e.code}: {e.read()[:500].decode('utf8', 'replace')}")
    except Exception as e:  # 超时 / 连接
        stop(f"网关 {type(e).__name__}: {e}")
    seconds = round(time.perf_counter() - t0, 2)
    write_json(RAW / raw_name, js)
    text = "".join(b.get("text", "") for b in js.get("content") or [] if b.get("type") == "text")
    log(f"llm {raw_name} status={status} s={seconds} usage={js.get('usage')} stop={js.get('stop_reason')}")
    if not text.strip():
        stop(f"网关返回没有正文：{raw_name}")
    return dict(status=status, seconds=seconds, text=text, usage=js.get("usage"), stop_reason=js.get("stop_reason"),
                raw_file=raw_name)


def journal_checks(text, items):
    """S1-X 的代码检查（句数、Markdown、元话语词、第一人称、Used），加各类材料被引了几条与机器词。"""
    c = s1x.checks(text, items)
    by_n = {it["n"]: it for it in items}
    used = set(u for u in (c["used"] or []) if u in by_n)
    c["used_by_kind"] = {k: sum(1 for u in used if by_n[u]["kind"] == k) for k in ("unsealed", "raw", "observation")}
    c["machine_words"] = [m.group(0) for m in MACHINE_WORDS.finditer(c["journal"])]
    return c


# ---------------------------------------------------------------- 子命令：setup

def cmd_setup(a):
    verify_product_constants()
    if a.dry_run:
        lines = ["setup 将要发送的请求（不发送）：", "  GET /banks（确认两个库都不存在）"]
        for b in OWN_BANKS:
            lines += [f"  {b}: PUT {{name, mission}}；PATCH /config {{retain_mission, observations_mission}}；GET /config；"
                      f"四份认识各 GET（期望 404）+ POST + 轮询 operation（>= 1 次）"]
        n_min = 1 + len(OWN_BANKS) * (3 + 3 * len(s1v.QUERIES))
        lines.append(f"  请求数至少 {n_min}（轮询次数运行时定）")
        lines.append("  第一个 POST 认识的请求体：" + json.dumps(model_body(*s1v.QUERIES[0]), ensure_ascii=False))
        return dry_report("setup", lines)
    h = hindsight()
    banks = Bank(h, COPY_BANK).must(h.call("GET", "/banks", raw_name="S_banks_before.json"), "GET /banks")
    ids = [b.get("bank_id") for b in banks.get("banks") or []]
    present = [b for b in OWN_BANKS if b in ids]
    if present:
        stop(f"库已存在：{present}（不删，停下）")
    save_result("setup_started", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    info = dict(banks_before=ids)
    for b in OWN_BANKS:
        info[b] = Bank(h, b).ensure()
        save_result("setup", info)
    info["finished"] = s1q.now_iso()
    save_result("setup", info)


def dry_report(stage, lines):
    text = "\n".join(lines)
    write_text(DRYRUN / f"{stage}.txt", text)
    print(text)


# ---------------------------------------------------------------- 子命令：round

def stored_rows():
    return read_json(STORED) if STORED.exists() else []


def latest_document_ids(rows):
    """{问题: 最新一条反思的 document_id}（反思库里已存的）。"""
    out = {}
    for r in sorted(rows, key=lambda r: r["round"]):
        out[r["key"]] = r["document_id"]
    return out


def cmd_round(a):
    inp = Inputs()
    frozen = frozen_moments(inp)
    n_rounds = len(frozen["rounds"])
    if a.dry_run:
        ks = range(1, n_rounds + 1) if a.k == "all" else [int(a.k)]
        return dry_run_rounds(inp, ks)
    k = int(a.k)
    plan = inp.round_plan(k)
    rdir = ROUNDS / str(k)
    if (rdir / "done.json").exists():
        stop(f"第 {k} 轮已做完（{rdir / 'done.json'}）")
    if k > 1 and not (ROUNDS / str(k - 1) / "done.json").exists():
        stop(f"第 {k - 1} 轮还没做完")
    if not (s1v.load().get("setup") or {}).get("finished"):
        stop("先跑 setup")
    h = hindsight()
    copy, refl = Bank(h, COPY_BANK), Bank(h, REFL_BANK)
    log(f"START round {k} t={plan['t']} t′={plan['now']} state={plan['state'].name}")
    write_json(rdir / "plan.json", frozen["rounds"][k - 1])
    replay_step(copy, plan, rdir)
    latest = read_back_step(refl, rdir)
    system = system_prompt(plan["state"])
    if SYSTEM_PROMPT_FILE.exists() and SYSTEM_PROMPT_FILE.read_text(encoding="utf8") != system:
        stop("系统提示词与之前的轮不同（Character 一行变了）")
    write_text(SYSTEM_PROMPT_FILE, system)
    right_now = right_now_block(plan["state"], plan["rawobs"])
    write_text(rdir / "right-now.txt", right_now)
    asked = [q for q in plan["questions"] if q["asked"]]
    for q in plan["questions"]:
        if not q["asked"]:
            log(f"round {k} {q['key']}: 自上一轮以来没有新经历，跳过")
    copy_before = copy_stats_before(copy, k, rdir)

    def step(q, latest):
        materials_step(copy, plan, q, right_now, latest, rdir)
        row = write_step(k, q, system, rdir)
        return store_one(refl, plan, row, rdir) if row["kept"] else None

    serial_questions(asked, latest, step)
    store_step(copy, refl, plan, asked, rdir, copy_before)
    column_step(k, rdir)
    write_json(rdir / "done.json", dict(round=k, finished=s1q.now_iso()))
    log(f"END round {k}")


def replay_step(copy, plan, rdir):
    path = rdir / "replay.json"
    if path.exists():
        log(f"round {plan['k']} 重放已做过（{path}）")
        return
    done = set(read_json(REPLAYED)) if REPLAYED.exists() else set()
    todo = [d for d in plan["library"] if d.id not in done]
    info = dict(library_documents=len(plan["library"]), already=len(done), new=len(todo), batches=[])
    for minute, batch in replay_batches(todo):
        items = [dict(document_id=d.id, content=d.content, timestamp=ms_iso(d.event_ms), tags=d.tags) for d in batch]
        row = copy.retain(items, f"R{plan['k']}_retain_{safe_name(minute)}.json")
        info["batches"].append(dict(created_minute=minute, **row))
        log(f"round {plan['k']} retain {minute}: {row}")
        done |= {d.id for d in batch}
        write_json(REPLAYED, sorted(done))
    if todo:
        info["wait"] = copy.wait_drained(REPLAY_CAP_S, f"R{plan['k']}_replay")
        log(f"round {plan['k']} replay wait {info['wait']}")
    write_json(path, info)


def read_back_one(refl, doc_id):
    """按 document_id 从反思库读文档原文（不经召回），去掉存入时加的 `At … (UTC), I thought it over: ` 前缀。"""
    text = refl.document_text(doc_id)
    m = REFLECTION_PREFIX_RE.match(text)
    if not m:
        stop(f"反思库文档 {doc_id} 的正文不是 `At <UTC> (UTC), I thought it over: ` 开头")
    return dict(document_id=doc_id, original_text=text, journal=text[m.end():])


def read_back_step(refl, rdir):
    """轮首：之前各轮每个问题最新的一条，从反思库读回。返回 {问题: {document_id, original_text, journal}}。"""
    path = rdir / "before.json"
    if path.exists():
        return read_json(path)
    out = {key: read_back_one(refl, doc_id) for key, doc_id in latest_document_ids(stored_rows()).items()}
    write_json(path, out)
    return out


def serial_questions(asked, latest, step):
    """补记第 2 条：同一轮按 Q_place -> Q_person -> Q_self 的次序一问一问做（网关写作不并发）。

    step(q, latest) 用当时的 latest 取“之前的想法”、写、检查；通过的立即存进反思库并读回，返回读回的那条
    （{document_id, journal, …}）；被丢弃返回 None。latest 随之更新，所以后写的那问在 About other things 里
    看到的是字面上的最新（含本轮刚写好的前几问）；About this 仍是同一问题此前最近一次存下的那条
    （本轮还没写到它）；被丢弃的那一问不更新，latest 里仍是它更早的那条（没有就不出现）。"""
    keys = [q["key"] for q in asked]
    assert keys == [k for k in QUESTION_ORDER if k in keys], f"问题次序不是 {QUESTION_ORDER}：{keys}"
    for q in asked:
        got = step(q, latest)
        if got is not None:
            latest[q["key"]] = got
    return latest


def materials_step(copy, plan, q, right_now, latest, rdir):
    key = q["key"]
    path = rdir / f"materials-{key}.json"
    if path.exists():
        return
    bodies = recall_bodies(q, plan["now"])
    with ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(lambda kb: copy.recall(kb[1], f"M{plan['k']}_{key}_{kb[0]}.json"), bodies))
    groups = [unsealed_items(plan["state"])] + [recalled_items(kind, r, plan["now_ms"]) for (kind, _), r in zip(bodies, rows)]
    items = number_items(groups)
    this, others = thoughts_text(key, {o: v["journal"] for o, v in latest.items()})
    user = user_message(right_now, [it["line"] for it in items], this, others, q["text"])
    counts = {kind: sum(1 for it in items if it["kind"] == kind) for kind in ("unsealed", "raw", "observation")}
    # 之前的想法各取自反思库的哪份文档（本轮前几问的也在其中）
    sources = dict(this=(latest.get(key) or {}).get("document_id"),
                   others=[latest[o]["document_id"] for o in QUESTION_ORDER if o != key and o in latest])
    write_json(path, dict(question=q, request_bodies={k: b for k, b in bodies},
                          returned={k: len(r) for (k, _), r in zip(bodies, rows)}, counts=counts, items=items,
                          thoughts=dict(this=this, others=others, read_back_from=sources)))
    write_text(rdir / f"materials-{key}.txt", "\n".join(it["line"] for it in items))
    write_text(rdir / f"user-{key}.txt", user)
    log(f"round {plan['k']} materials {key}: {counts} thoughts from {sources}")


def journal_failures(check):
    """代码检查不合格的原因（空 = 合格）。补记第 3 条：句数超限、`Used:` 行缺失、Used 编号不在 What happened 里
    三者同样处理。Used 行在但一个编号都没有，按 S1-X 的 used_valid 判法同样算不合格。"""
    out = []
    if check["sentences"] > MAX_SENTENCES:
        out.append(f"sentences {check['sentences']} > {MAX_SENTENCES}")
    if not check["used_present"]:
        out.append("Used line missing")
    elif check["used_invalid_numbers"]:
        out.append(f"Used numbers not under What happened: {check['used_invalid_numbers']}")
    elif not check["used"]:
        out.append("Used line lists no numbers")
    return out


def write_with_reask(ask, items):
    """写一次；任一项不合格就原样重问一次（每问至多重问一次，不论第一次因为什么）；重问后仍有任一项不合格就丢弃。
    ask(attempt) -> write_journal 的结果。返回 (attempts, kept)；每次尝试带原文、check 与 failures（不合格原因）。"""
    attempts = []
    for attempt in (1, 2):
        r = ask(attempt)
        check = journal_checks(r["text"], items)
        failures = journal_failures(check)
        attempts.append(dict(r, attempt=attempt, check=check, failures=failures, passed=not failures))
        if not failures:
            break
    return attempts, attempts[-1]["passed"]


def write_step(k, q, system, rdir):
    """写一问并做代码检查（write_with_reask）；落 reflections/<k>-<问题>.json，返回这一行。"""
    key = q["key"]
    path = REFLECTIONS / f"{k}-{key}.json"
    if path.exists():
        return read_json(path)
    user = (rdir / f"user-{key}.txt").read_text(encoding="utf8")
    items = read_json(rdir / f"materials-{key}.json")["items"]
    attempts, kept = write_with_reask(lambda n: write_journal(system, user, f"L{k}_{key}_a{n}.json"), items)
    first, last = attempts[0], attempts[-1]
    row = dict(round=k, key=key, question=q["text"], tags=q["tags"], kept=kept, attempts=attempts,
               reask_reason=first["failures"] if len(attempts) > 1 else None,
               journal=last["check"]["journal"] if kept else None,
               discarded_reason=None if kept else "still failing after one re-ask: " + "; ".join(last["failures"]))
    write_json(path, row)
    if kept:
        write_text(REFLECTIONS / f"{k}-{key}.txt", last["check"]["journal"])
    c = last["check"]
    log(f"round {k} {key}: attempts={len(attempts)} kept={kept} reask_reason={row['reask_reason']} "
        f"failures={last['failures']} sentences={c['sentences']} md={c['markdown']} meta={c['meta']} "
        f"fp={c['first_person']} used={c['used']} valid={c['used_valid']}")
    return row


def store_one(refl, plan, row, rdir):
    """一问通过检查后立即存进反思库（一份文档，正文时刻与 timestamp 用此刻 t′）、等巩固，
    再按 document_id 从反思库读回原文给本轮后面的问题用（读写路径在一轮之内也走到）。"""
    k, key = plan["k"], row["key"]
    path = rdir / f"store-{key}.json"
    if path.exists():
        return read_json(path)["read_back"]
    doc_id = f"reflection:{key}:{k}"
    item = dict(document_id=doc_id, content=REFLECTION_PREFIX.format(t=plan["now"]) + row["journal"],
                timestamp=plan["now"], tags=["kind:reflection"] + row["tags"])
    info = dict(document_id=doc_id, tags=item["tags"], chars=len(item["content"]))
    if any(r["document_id"] == doc_id for r in stored_rows()):
        info["retain"] = "already stored before a restart; not sent again"
    else:
        info["retain"] = refl.retain([item], f"T{k}_{key}_refl_retain.json")
        info["refl_wait"] = refl.wait_drained(STORE_CAP_S, f"T{k}_{key}_refl")
        write_json(STORED, stored_rows() + [dict(round=k, key=key, document_id=doc_id, t=plan["now"])])
    info["read_back"] = read_back_one(refl, doc_id)
    info["read_back_equal"] = info["read_back"]["journal"] == row["journal"]
    write_json(path, info)
    log(f"round {k} store {doc_id}: read back equal={info['read_back_equal']}")
    return info["read_back"]


def copy_stats_before(copy, k, rdir):
    """副本库在本轮存任何反思之前的事实数 / 认识数（重入时用落盘的那份）。"""
    path = rdir / "copy-before.json"
    if path.exists():
        return read_json(path)
    st = copy.stats(f"T{k}_copy_stats_before.json")
    write_json(path, st)
    return st


def store_step(copy, refl, plan, asked, rdir, copy_before):
    """轮末汇总：本轮存进反思库的各条（逐问已存，见 store_one）、列反思库的事实；核对副本库的事实数 / 认识数
    在本轮存反思前后不变。"""
    path = rdir / "store.json"
    if path.exists():
        return
    k = plan["k"]
    stored = [read_json(rdir / f"store-{q['key']}.json") for q in asked if (rdir / f"store-{q['key']}.json").exists()]
    info = dict(documents=[{f: s[f] for f in ("document_id", "tags", "chars", "read_back_equal")} for s in stored],
                copy_before=copy_before)
    if stored:
        rows, total = refl.memories(f"T{k}_refl_list")
        write_json(rdir / "refl-memories.json", dict(total=total, items=rows))
    info["copy_after"] = copy.stats(f"T{k}_copy_stats_after.json")
    same = all(info["copy_before"][f] == info["copy_after"][f] for f in ("total_nodes", "nodes_by_fact_type"))
    info["copy_unchanged"] = same
    write_json(path, info)
    log(f"round {k} store: {len(stored)} reflections; copy unchanged={same} "
        f"before={info['copy_before']['nodes_by_fact_type']} after={info['copy_after']['nodes_by_fact_type']}")


def column_entries(k):
    """第 k 轮结束时每个问题最新的一条（问题次序），至多 4 条。"""
    latest = {}
    for r in sorted(stored_rows(), key=lambda r: r["round"]):
        if r["round"] <= k:
            latest[r["key"]] = read_json(REFLECTIONS / f"{r['round']}-{r['key']}.json")["journal"]
    return [latest[q] for q in QUESTION_ORDER if q in latest][:MAX_COLUMN_ENTRIES]


def column_step(k, rdir):
    entries = column_entries(k)
    write_json(rdir / "column.json", dict(round=k, entries=entries))


def dry_thoughts(key, earlier, this_round_before):
    """dry-run 的“之前的想法”占位：earlier = 之前各轮存过的问题（按都存下估计），
    this_round_before = 本轮排在它前面、会先写的问题。"""
    this = f"[{key} 此前最近存下的一条，轮首从反思库读回，运行时填入]" if key in earlier else NOTHING_YET
    others = []
    for o in QUESTION_ORDER:
        if o == key:
            continue
        if o in this_round_before:
            fallback = "它此前最近的一条" if o in earlier else "这一行不出现（全都不出现时写 nothing yet）"
            others.append(f"[本轮 {o} 写好、通过检查并存入反思库后从反思库读回的正文，运行时填入；若 {o} 被丢弃则{fallback}]")
        elif o in earlier:
            others.append(f"[{o} 此前最近存下的一条，轮首从反思库读回，运行时填入]")
    return this, "\n".join(others) if others else NOTHING_YET


def dry_run_rounds(inp, ks):
    lines = []
    totals = dict(retain_calls_max=0, retain_docs=0, recall=0, read_back_max=0, gateway_min=0, gateway_max=0)
    replayed, stored_keys = set(), set()
    for k in ks:
        p = inp.round_plan(k)
        asked = [q for q in p["questions"] if q["asked"]]
        todo = [d for d in p["library"] if d.id not in replayed]
        replayed |= {d.id for d in todo}
        batches = replay_batches(todo)
        read_back = len(stored_keys)
        earlier = set(stored_keys)
        stored_keys |= {q["key"] for q in asked}
        n_recall = 2 * len(asked)
        totals["retain_calls_max"] += len(batches) + len(asked)
        totals["retain_docs"] += len(todo)
        totals["recall"] += n_recall
        totals["read_back_max"] += read_back + len(asked)
        totals["gateway_min"] += len(asked)
        totals["gateway_max"] += 2 * len(asked)
        lines.append(f"第 {k} 轮 t={p['t']}  t′={p['now']}  state={p['state'].name}  rawobs={p['rawobs'].path.name}")
        lines.append(f"  Hindsight：重放 retain {len(batches)} 次（{len(todo)} 份文档，分批 "
                     f"{[(m, len(b)) for m, b in batches]}）+ 等巩固轮询 GET /stats >= {1 if todo else 0}；"
                     f"轮首读回之前的想法 GET /documents <= {read_back}；副本库 GET /stats 2（存反思前后）")
        lines.append(f"  逐问串行 {[q['key'] for q in asked]}（跳过 {[q['key'] for q in p['questions'] if not q['asked']]}），"
                     f"每问：召回 2（两次召回可并发）-> 网关写作 1（不合格原样重问 1 次，至多 2）-> 通过的立即反思库 retain 1 "
                     f"+ 轮询 GET /stats >= 1 + 读回 GET /documents 1")
        lines.append(f"  本轮合计：召回 {n_recall}；网关写作 {len(asked)}–{2 * len(asked)}（串行）；反思库 retain <= {len(asked)}、"
                     f"读回 <= {read_back + len(asked)}；轮末反思库列事实 >= {1 if asked else 0}（有存才列）")
        if asked:
            kind, body = recall_bodies(asked[0], p["now"])[0]
            lines.append(f"  第一个召回请求体（{kind}）：{json.dumps(body, ensure_ascii=False)}")
            if k == ks[0]:
                lines_items = [it["line"] for it in number_items([unsealed_items(p["state"])])]
                lines_items.append("[召回结果在运行时填入]")
                right_now = right_now_block(p["state"], p["rawobs"])
                for i, q in enumerate(asked):
                    this, others = dry_thoughts(q["key"], earlier, {x["key"] for x in asked[:i]})
                    user = user_message(right_now, lines_items, this, others, q["text"])
                    lines.append(f"  第 {k} 轮 {q['key']}（本轮第 {i + 1} 问）的完整用户消息：\n" + "-" * 60 + "\n" + user
                                 + "\n" + "-" * 60)
                lines.append(f"  系统提示词 {len(system_prompt(p['state']))} 字（<character> = state 的 Character 一栏原文）；"
                             f"网关请求体 model={LLM_MODEL} max_tokens={LLM_MAX_TOKENS}，不开扩展思考")
    lines.append(f"合计（按每问都存下估计上限）：{totals}")
    dry_report("round-" + "-".join(map(str, ks)), lines)


# ---------------------------------------------------------------- 子命令：extra

def done_rounds():
    done = sorted(int(p.parent.name) for p in ROUNDS.glob("*/done.json")) if ROUNDS.exists() else []
    return done


def cmd_extra(a):
    frozen = read_json(MOMENTS) if MOMENTS.exists() else stop("先跑 moments")
    n = len(frozen["rounds"])
    targets = sorted({1, n})
    if a.dry_run:
        asked = {r["k"]: [q["key"] for q in r["questions"] if q["asked"]] for r in frozen["rounds"]}
        total = sum(len(asked[k]) for k in targets) * EXTRA_REPEATS
        return dry_report("extra", [f"extra：第 {targets} 轮，每个进了该轮的问题再写 {EXTRA_REPEATS} 次；"
                                    f"网关写作至多 {total} 次（{ {k: asked[k] for k in targets} }；被丢弃的问不再写）；"
                                    "用户消息 = 该轮落盘的 user-<问题>.txt 原样"])
    if done_rounds() != list(range(1, n + 1)):
        stop(f"各轮还没全做完：done={done_rounds()}，应有 1..{n}")
    system = SYSTEM_PROMPT_FILE.read_text(encoding="utf8")
    for k in targets:
        for path in sorted(REFLECTIONS.glob(f"{k}-*.json")):
            chain = read_json(path)
            if not chain["kept"]:
                continue
            key = chain["key"]
            user = (ROUNDS / str(k) / f"user-{key}.txt").read_text(encoding="utf8")
            items = read_json(ROUNDS / str(k) / f"materials-{key}.json")["items"]
            for i in range(1, EXTRA_REPEATS + 1):
                out = EXTRA_DIR / f"{k}-{key}-{i}.json"
                if out.exists():
                    continue
                r = write_journal(system, user, f"X{k}_{key}_{i}.json")
                write_json(out, dict(round=k, key=key, run=i, **r, check=journal_checks(r["text"], items)))


# ---------------------------------------------------------------- 子命令：jev

def insert_column(text, entries):
    """新栏：在 What I remember 栏之后、Current situation 之前插一行（s1x.insert_column），并自检位置与其余不变。"""
    new = s1x.insert_column(text, entries)
    if not entries:
        return new, 0
    old_lines, new_lines = text.split("\n"), new.split("\n")
    i = next(n for n, l in enumerate(new_lines) if l.startswith("What I have come to think: "))
    assert new_lines[i + 1].startswith("Current situation: "), "新栏之后不是 Current situation"
    assert new_lines[:i] + new_lines[i + 1:] == old_lines, "去掉新栏后与基准 state 不同"
    secs = state_sections(new)
    assert dict(secs)[MEM][-1] == new_lines[i], "新栏不在 What I remember 一栏的末尾"
    return new, len(new) - len(text)


def variant_plan(frozen, inp, column_of):
    """[(变体名, 基准 state, 新栏条目或 None, 说明)]；column_of(k) 给第 k 轮结束时的各条。"""
    states = {s.name: s for s in inp.states}
    out = []
    for r in frozen["rounds"]:
        base = states[r["nobody_state"]]
        out.append((f"N{r['k']}_R0", base, None, dict(round=r["k"])))
        out.append((f"N{r['k']}_col", base, column_of(r["k"]), dict(round=r["k"])))
    for label in ("V", "T"):
        name = frozen["situations"][label]
        if not name:
            stop(f"{label} 处境的 state 没定位到")
        base = states[name]
        prior = [r["k"] for r in frozen["rounds"] if iso_ms(r["now"]) <= base.asked_ms]  # 比较的是各轮的此刻 t′
        if not prior:
            stop(f"{label} 处境 state {name} 早于第 1 轮，没有时刻不晚于它的轮")
        k = max(prior)
        out.append((f"{label}_R0", base, None, dict(round=k)))
        out.append((f"{label}_col", base, column_of(k), dict(round=k)))
    return out


def jev_question():
    tpl = read_json(TEMPLATE)
    q = {"activity": {"criteria": {c["name"]: c["criterion"] for c in tpl["candidates"]},
                      "instructions": tpl["instructions"], "type": "choice"}}
    return q, [c["name"] for c in tpl["candidates"]]


def cmd_jev(a):
    inp = Inputs()
    frozen = frozen_moments(inp)
    if a.dry_run:
        plan = variant_plan(frozen, inp, lambda k: [f"[第 {k} 轮各问题最新的反思在运行时填入]"])
        lines = [f"jev：{len(plan)} 个变体 x {JEV_REPEATS} 次 = {len(plan) * JEV_REPEATS} 个请求，并发 <= {JEV_WORKERS}，"
                 f"超时 {JEV_TIMEOUT_S} s，候选 {jev_question()[1]}"]
        for name, base, entries, note in plan:
            text, delta = insert_column(base.text, entries) if entries else (base.text, 0)
            lines.append(f"  {name}: base={base.name} round={note['round']} chars={len(text)} "
                         f"column_entries={len(entries) if entries else 0} delta={delta}")
        name, base, entries, _ = plan[0]
        lines.append(f"  第一个请求体：state = {base.name} 全文（{len(base.text)} 字）、model = $TYPESAFE_MODEL、"
                     f"questions.activity = request-template.json 的 instructions 与 {len(jev_question()[1])} 个候选")
        return dry_report("jev", lines)
    if done_rounds() != list(range(1, len(frozen["rounds"]) + 1)):
        stop(f"各轮还没全做完：done={done_rounds()}")
    plan = variant_plan(frozen, inp, column_entries)
    texts, notes = {}, {}
    for name, base, entries, note in plan:
        text, delta = insert_column(base.text, entries) if entries else (base.text, 0)
        texts[name] = text
        notes[name] = dict(base_state=base.name, round=note["round"], column_entries=len(entries or []),
                           state_chars=len(text), delta_chars=delta)
        write_text(VARIANTS_DIR / f"{name}.txt", text)
    write_json(VARIANTS_DIR / "notes.json", notes)
    order = [p[0] for p in plan]
    data = run_jev(texts, order)
    data["variant_notes"] = notes
    save_result("jev", data)
    for v in data["variants"]:
        log(f"jev {v['variant']} top1={v['top1_counts']} avg={ {k: round(x, 3) for k, x in v['avg_probs'].items() if x} } "
            f"failed={v['failed']}")
    if data.get("stopped"):
        stop(data["stopped"])


def run_jev(texts, order):
    """每变体 JEV_REPEATS 次、并发 <= JEV_WORKERS；401 / 403 / 429 / quota / 连接错误即停（未发的不再发），其它失败记下不补问。"""
    for k in ("TYPESAFE_API_URL", "TYPESAFE_API_KEY", "TYPESAFE_MODEL"):
        if not os.environ.get(k):
            stop(f"环境变量 {k} 没有设置")
    q, cands = jev_question()
    halt, halted = threading.Event(), []

    def one(cell):
        name, rep = cell
        row = dict(repeat=rep, ok=False, top1=None, probs=None, latency_ms=None, error=None)
        if halt.is_set():
            row["error"] = "not sent (stopped)"
            return name, row
        try:
            answers, seconds = s1q.jev_ask(texts[name], q, timeout=JEV_TIMEOUT_S)
        except Exception as ex:  # 连接 / 超时
            halt.set()
            halted.append(f"Jev {name} r{rep}: {type(ex).__name__}: {ex}")
            row["error"] = type(ex).__name__
            return name, row
        row["latency_ms"] = round(seconds * 1000)
        write_json(RAW / f"J_{name}_r{rep}.json", answers)
        if "error" in answers:
            row["error"] = f"http {answers['error']}"
            if answers["error"] in (401, 403, 429) or "quota" in str(answers.get("body", "")).lower():
                halt.set()
                halted.append(f"Jev {name} r{rep}: HTTP {answers['error']} {answers.get('body')}")
        else:
            ans = answers.get("activity")
            if isinstance(ans, dict) and "choice" in ans:
                row.update(ok=True, top1=ans["choice"], probs=ans.get("probabilities"))
            else:
                row["error"] = "malformed answer"
        print(f"{name} r{rep}: {row['top1']} {row['error'] or ''}", flush=True)
        return name, row

    cells = [(n, r + 1) for n in order for r in range(JEV_REPEATS)]
    started = s1q.now_iso()
    with ThreadPoolExecutor(JEV_WORKERS) as pool:
        got = list(pool.map(one, cells))
    by = {}
    for name, row in got:
        by.setdefault(name, []).append(row)
    variants = []
    for name in order:
        rows = sorted(by[name], key=lambda r: r["repeat"])
        ok = [r for r in rows if r["ok"]]
        top = {}
        for r in ok:
            top[r["top1"]] = top.get(r["top1"], 0) + 1
        avg = {c: (sum((r["probs"] or {}).get(c, 0.0) for r in ok) / len(ok) if ok else None) for c in cands}
        variants.append(dict(variant=name, state_chars=len(texts[name]), top1_counts=top, avg_probs=avg,
                             failed=len(rows) - len(ok), requests=rows))
    return dict(model=os.environ["TYPESAFE_MODEL"], repeats=JEV_REPEATS, workers=JEV_WORKERS, timeout_s=JEV_TIMEOUT_S,
                retries=0, candidates=cands, started=started, finished=s1q.now_iso(), requests=len(got),
                answered=sum(r["ok"] for _, r in got), stopped="; ".join(halted) or None, variants=variants)


# ---------------------------------------------------------------- 子命令：forced（只读容器日志）

def cmd_forced(a):
    start = s1v.load().get("setup_started")
    if not start:
        stop("results.json 里没有 setup_started")
    p = subprocess.run(["docker", "logs", "--since", start, CONTAINER], capture_output=True, timeout=120)
    text = (p.stdout + p.stderr).decode("utf8", "replace")
    forced = [l for l in text.splitlines() if "Forced step" in l]
    both = [l for l in forced if "returned no tool call" in l]
    write_text(RAW / "forced-step-lines.txt", "\n".join(forced))
    info = dict(since=start, read_at=s1q.now_iso(), docker_exit=p.returncode, total_lines=len(text.splitlines()),
                forced_step_lines=len(forced), forced_and_no_tool_call=len(both))
    save_result("forced_step", info)
    log(f"forced {info}")


# ---------------------------------------------------------------- 子命令：judge-pack

def materials_for_judge(user):
    """四块材料 = 用户消息去掉最后一段（Used 行的写法要求）。"""
    assert user.endswith(USED_INSTRUCTION)
    return user[:-len(USED_INSTRUCTION)].rstrip() + "\n"


def cmd_judge_pack(a):
    index = []
    for path in sorted(REFLECTIONS.glob("*.json"), key=lambda p: [int(x) if x.isdigit() else x for x in p.stem.split("-")]):
        r = read_json(path)
        k, key = r["round"], r["key"]
        d = JUDGE / f"round-{k}"
        user = (ROUNDS / str(k) / f"user-{key}.txt").read_text(encoding="utf8")
        write_text(d / f"materials-{key}.txt", materials_for_judge(user))
        entry = dict(round=k, question=key, materials=f"round-{k}/materials-{key}.txt", journal=None, extra=[])
        if r["kept"]:
            write_text(d / f"journal-{key}.txt", r["journal"] + "\n")
            entry["journal"] = f"round-{k}/journal-{key}.txt"
        for x in sorted(EXTRA_DIR.glob(f"{k}-{key}-*.json")) if EXTRA_DIR.exists() else []:
            xr = read_json(x)
            name = f"extra-{key}-{xr['run']}.txt"
            write_text(d / name, s1x.split_used(xr["text"])[0] + "\n")
            entry["extra"].append(f"round-{k}/{name}")
        index.append(entry)
    write_json(JUDGE / "index.json", index)
    print(f"judge pack: {len(index)} 条 -> {JUDGE}")


# ---------------------------------------------------------------- 子命令：check

def reflection_extraction(rows):
    """反思库里每份反思文档被抽成几条事实与认识（认识按 source_memory_ids 归到文档）。"""
    fact_doc = {m["id"]: m.get("document_id") for m in rows if m["fact_type"] != "observation"}
    out = {}
    for m in rows:
        if m["fact_type"] != "observation" and m.get("document_id"):
            out.setdefault(m["document_id"], dict(facts=0, observations=0))["facts"] += 1
    for m in rows:
        if m["fact_type"] == "observation":
            src = m.get("source_memory_ids") or []
            if isinstance(src, str):
                src = re.findall(r"[0-9a-f-]{36}", src)
            for doc in sorted({fact_doc[s] for s in src if fact_doc.get(s)}):
                out.setdefault(doc, dict(facts=0, observations=0))["observations"] += 1
    return out


def cmd_check(a):
    chain, extra = [], []
    for path in sorted(REFLECTIONS.glob("*.json")):
        r = read_json(path)
        items = read_json(ROUNDS / str(r["round"]) / f"materials-{r['key']}.json")["items"]
        attempts = []
        for i, x in enumerate(r["attempts"]):
            c = journal_checks(x["text"], items)
            attempts.append(dict(attempt=i + 1, seconds=x["seconds"], usage=x["usage"], failures=journal_failures(c), **c))
        chain.append(dict(round=r["round"], key=r["key"], kept=r["kept"], attempts=attempts))
    for path in sorted(EXTRA_DIR.glob("*.json")) if EXTRA_DIR.exists() else []:
        x = read_json(path)
        items = read_json(ROUNDS / str(x["round"]) / f"materials-{x['key']}.json")["items"]
        extra.append(dict(round=x["round"], key=x["key"], run=x["run"], **journal_checks(x["text"], items)))
    similarity = []
    for key in QUESTION_ORDER:
        kept = sorted((c["round"], c["attempts"][-1]["journal"]) for c in chain if c["key"] == key and c["kept"])
        for (k1, a1), (k2, a2) in zip(kept, kept[1:]):
            similarity.append(dict(key=key, rounds=[k1, k2], ratio=round(difflib.SequenceMatcher(None, a1, a2).ratio(), 3)))
    rounds = []
    for p in sorted(ROUNDS.glob("*/store.json"), key=lambda p: int(p.parent.name)):
        k = int(p.parent.name)
        s = read_json(p)
        col = read_json(p.parent / "column.json")["entries"] if (p.parent / "column.json").exists() else None
        mats = {m.stem.split("-", 1)[1]: read_json(m)["counts"] for m in p.parent.glob("materials-*.json")}
        rounds.append(dict(round=k, copy_unchanged=s["copy_unchanged"], copy_before=s["copy_before"]["nodes_by_fact_type"],
                           copy_after=s["copy_after"]["nodes_by_fact_type"], column_entries=len(col or []),
                           materials=mats))
    last_refl = sorted(ROUNDS.glob("*/refl-memories.json"), key=lambda p: int(p.parent.name))
    extraction = reflection_extraction(read_json(last_refl[-1])["items"]) if last_refl else None
    results = s1v.load()
    jev = results.get("jev")
    jev_summary = [dict(variant=v["variant"], top1=v["top1_counts"],
                        avg={k: round(x, 3) for k, x in v["avg_probs"].items() if x},
                        state_chars=v["state_chars"], delta_chars=(jev.get("variant_notes") or {}).get(v["variant"], {}).get("delta_chars"),
                        failed=v["failed"]) for v in (jev or {}).get("variants", [])]
    summary = dict(
        chain=chain, extra=extra, adjacent_similarity=similarity, rounds=rounds,
        discarded=[dict(round=c["round"], key=c["key"], reasons=c["attempts"][-1]["failures"])
                   for c in chain if not c["kept"]],
        discarded_by_sentences=sum(1 for c in chain if not c["kept"] and c["attempts"][-1]["sentences"] > MAX_SENTENCES),
        reasked=[dict(round=c["round"], key=c["key"], first_failures=c["attempts"][0]["failures"])
                 for c in chain if len(c["attempts"]) > 1],
        reflection_bank_extraction=extraction, jev=jev_summary, forced_step=results.get("forced_step"),
        finished=s1q.now_iso())
    save_result("check", summary)
    for c in chain:
        x = c["attempts"][-1]
        print(f"round {c['round']} {c['key']}: kept={c['kept']} attempts={len(c['attempts'])} "
              f"failures={[a['failures'] for a in c['attempts']]} sent={x['sentences']} "
              f"md={x['markdown']} meta={x['meta']} fp={x['first_person']} used_valid={x['used_valid']} "
              f"machine={x['machine_words']}")
    for s in similarity:
        print(f"similarity {s}")
    for r in rounds:
        print(f"round {r['round']}: copy unchanged={r['copy_unchanged']} column={r['column_entries']} materials={r['materials']}")
    for v in jev_summary:
        print(f"jev {v}")
    print(f"results: {RESULTS} [check]")


# ---------------------------------------------------------------- 子命令：selftest（纯函数，不发请求、不落盘）

def cmd_selftest(a):
    mats = [dict(n=i, kind=k) for i, k in ((1, "unsealed"), (2, "raw"), (3, "observation"))]
    cases = [
        ("I set the beam this morning. It held. I will check it again tomorrow.\nUsed: 1, 3",
         dict(sentences=3, markdown=0, meta=0, first_person=True, used=[1, 3], used_valid=True)),
        ("- First thing\n**Still** angry. My note says he came back! I think so.\nUsed: [2], [7]",
         # S1-X 判法：行首 `-` 1 + 行首 `**` 的 `*` 1 + `**` 出现 2 次 = 4
         dict(sentences=3, markdown=4, meta=1, first_person=True, used=[2, 7], used_valid=False)),
        ("You are right. The data says so! Is it? Maybe. Yes.",
         dict(sentences=5, markdown=0, meta=1, first_person=False, used=None, used_valid=False)),
        ("He took my hut down. I don't know whether he came back after that. Used: 1",
         dict(sentences=3, used=None, used_valid=False)),
    ]
    for text, want in cases:
        got = journal_checks(text, mats)
        bad = {k: (got[k], v) for k, v in want.items() if got[k] != v}
        print(("ok   " if not bad else "FAIL ") + repr(text[:60]) + (f" {bad}" if bad else
              f" sent={got['sentences']} md={got['markdown_hits']} meta={got['meta_hits']} used={got['used']}"))
        assert not bad
    assert s1x.split_used("a b.\nUsed: [4], [5]\n")[2] == [4, 5]
    assert body_sentence(100, []) == "My body: life 100 of 100, no injuries or ailments."
    assert body_sentence(72.6, ["trauma.thermal.burn", "nutrition.hunger"]) == "My body: life 73 of 100, with a burn and hunger."
    assert body_sentence(50, ["trauma.mechanical.legs", "recovery.weakness", "nervous.daze"]) == \
        "My body: life 50 of 100, with an injury to the legs, weakness and a daze."
    try:
        injury_word("trauma.unknown")
        raise AssertionError("unknown tag accepted")
    except ValueError:
        pass
    print("ok   injury words / body sentence")
    obs = load_rawobs()
    print(f"ok   rawobs parse: {len(obs)} files; first {obs[0].path.name} day={obs[0].day} life={obs[0].life} "
          f"injuries={obs[0].injuries}")
    # 触发规则：用内存里的 Doc 走一遍（不是测量输入，只验规则的分支）
    t0 = 1_000_000

    def doc(i, sec, tags):
        return Doc(f"d{i}", t0 + sec * 1000, 0, "", tags, 0)
    seq = [doc(1, 0, ["kind:activity"]), doc(2, 10, ["kind:event", "actor:9"]),
           doc(3, 20, ["kind:conversation"]), doc(4, 30, ["kind:sight"]), doc(5, 40, ["kind:activity", "actor:9"]),
           doc(6, 50, ["kind:sight"]), doc(7, 60, ["kind:sight"]), doc(8, 70, ["kind:conversation"]),
           doc(9, 200, ["kind:activity"]), doc(10, 311, ["kind:activity"])]
    ms = compute_moments(seq)
    assert [m["doc_id"] for m in ms] == ["d2", "d10"], ms
    assert ms[1]["held_by_gap"] and ms[1]["score"] == 24, ms[1]
    print("ok   moment rule: immediate event, threshold held by the 5-minute gap, reset after trigger")
    # 补记第 3 条：缺 Used / 编号越界 / 句数超限同样处理，每问至多重问一次（假的模型输出，不发请求）
    good = "I set the beam this morning. It held. I will check it again tomorrow.\nUsed: 1, 3"
    no_used = "I set the beam this morning. It held. I will check it again tomorrow."
    out_of_range = "I set the beam this morning. It held.\nUsed: 2, 7"
    five = "I set the beam. It held. He came by. I watched. I will check it again.\nUsed: 1"
    empty_used = "I set the beam. It held.\nUsed: none"
    reask_cases = [
        ([good], True, [[]]),
        ([no_used, good], True, [["Used line missing"], []]),
        ([out_of_range, out_of_range], False, [["Used numbers not under What happened: [7]"]] * 2),
        ([five, five], False, [[f"sentences 5 > {MAX_SENTENCES}"]] * 2),
        ([five, no_used, good], False, [[f"sentences 5 > {MAX_SENTENCES}"], ["Used line missing"]]),
        ([empty_used, good], True, [["Used line lists no numbers"], []]),
    ]
    for outputs, want_kept, want_failures in reask_cases:
        calls = []

        def ask(n, outputs=outputs, calls=calls):
            calls.append(n)
            return dict(text=outputs[n - 1], seconds=0, usage=None)
        attempts, kept = write_with_reask(ask, mats)
        got_failures = [x["failures"] for x in attempts]
        assert kept == want_kept and got_failures == want_failures and len(calls) <= 2, (outputs, kept, got_failures, calls)
        assert all(x["text"] == outputs[i] for i, x in enumerate(attempts)), "落盘的原文不是模型原样输出"
    print(f"ok   re-ask: {len(reask_cases)} fake outputs (missing Used / number out of range / 5 sentences / "
          f"empty Used / mixed reasons) -> at most one re-ask, discarded when the re-ask still fails")
    # 补记第 2 条：串行时 About other things 取字面上的最新（内存里的假“已存反思”，不发请求）

    def stored(key, k, journal):
        return dict(document_id=f"reflection:{key}:{k}", journal=journal)

    def run_serial(latest, outcome):
        """outcome[key] = 本轮写出的正文，None = 被丢弃；返回每问看到的 (About this, About other things)。"""
        seen = {}

        def step(q, latest):
            seen[q["key"]] = thoughts_text(q["key"], {o: v["journal"] for o, v in latest.items()})
            text = outcome[q["key"]]
            return stored(q["key"], 2, text) if text else None
        final = serial_questions([dict(key=key) for key in QUESTION_ORDER if key in outcome], latest, step)
        return seen, {o: v["journal"] for o, v in final.items()}
    earlier = {"Q_place": stored("Q_place", 1, "old place"), "Q_person": stored("Q_person", 1, "old person")}
    seen, final = run_serial(dict(earlier), dict(Q_place="new place", Q_person=None, Q_self="new self"))
    assert seen == {"Q_place": ("old place", "old person"),
                    "Q_person": ("old person", "new place"),
                    "Q_self": (NOTHING_YET, "new place\nold person")}, seen
    assert final == {"Q_place": "new place", "Q_person": "old person", "Q_self": "new self"}, final
    seen, _ = run_serial({}, dict(Q_place=None, Q_person="first person", Q_self="first self"))
    assert seen == {"Q_place": (NOTHING_YET, NOTHING_YET), "Q_person": (NOTHING_YET, NOTHING_YET),
                    "Q_self": (NOTHING_YET, "first person")}, seen
    try:
        serial_questions([dict(key="Q_self"), dict(key="Q_place")], {}, lambda q, latest: None)
        raise RuntimeError("out-of-order questions accepted")
    except AssertionError:
        pass
    print("ok   serial questions: later questions see this round's earlier ones under About other things; "
          "About this stays the earlier one; a discarded question keeps its older entry")
    # 新栏位置：用一份真实 state 与三条占位假日记，只在内存里插入与检查
    inp_states = load_states()
    base = max((s for s in inp_states if s.nobody()), key=lambda s: len(dict(s.sections)[MEM]))  # 记忆栏最长的无人 state
    fake = ["[placeholder one]", "[placeholder two]", "[placeholder three]"]
    text, delta = insert_column(base.text, fake)
    lines = text.split("\n")
    i = next(n for n, l in enumerate(lines) if l.startswith("What I have come to think: "))
    print(f"ok   column insert on {base.name}: line {i + 1} of {len(lines)}; previous line starts "
          f"{lines[i - 1][:40]!r}; next line starts {lines[i + 1][:30]!r}; delta {delta} chars")
    print(f"     inserted: {lines[i]}")


# ---------------------------------------------------------------- 入口

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="stage", required=True)
    for name in ("moments", "selftest", "judge-pack", "check", "forced"):
        sub.add_parser(name)
    sub.add_parser("render-now").add_argument("k", type=int)
    for name in ("setup", "extra", "jev"):
        sub.add_parser(name).add_argument("--dry-run", action="store_true")
    r = sub.add_parser("round")
    r.add_argument("k", help="轮号；--dry-run 时可写 all")
    r.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.stage == "round" and a.k == "all" and not a.dry_run:
        ap.error("round all 只用于 --dry-run")
    for d in (OUT, RAW):
        d.mkdir(parents=True, exist_ok=True)
    dict(moments=cmd_moments, selftest=cmd_selftest, **{"render-now": cmd_render_now, "judge-pack": cmd_judge_pack},
         check=cmd_check, forced=cmd_forced, setup=cmd_setup, round=cmd_round, extra=cmd_extra, jev=cmd_jev)[a.stage](a)


if __name__ == "__main__":
    main()
