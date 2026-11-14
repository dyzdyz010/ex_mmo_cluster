"""重新生成本目录的夹具（只复制 / 删减真实导出，不计算被测规则）。需要本机有 .demo/observe/npc-slice1-20261112/。
用法（在仓库根）：python -I apps/npc_server/test/support/fixtures/reflection/regenerate.py ."""
import datetime
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(sys.argv[1])
OBS = ROOT / ".demo/observe/npc-slice1-20261112"
S1T, X2, X3 = OBS / "s1t", OBS / "s1x2", OBS / "s1x3"
OUT = ROOT / "apps/npc_server/test/support/fixtures/reflection"
OUT.mkdir(parents=True, exist_ok=True)


def iso_ms(iso):
    # 同离线脚本 s1x.iso_ms（s1q._iso_key 之后 * 1000 取整）
    s = iso.replace("Z", "+00:00")
    return int(round(datetime.datetime.fromisoformat(s).astimezone(datetime.timezone.utc).timestamp() * 1000))


def read_json(p):
    return json.loads(p.read_text(encoding="utf8"))


def write_lines_json(path, rows):
    """一行一个元素的 JSON 数组（便于人读、便于 diff）。"""
    body = ",\n".join(" " + json.dumps(r, ensure_ascii=False) for r in rows)
    path.write_bytes(("[\n" + body + "\n]\n").encode("utf8"))


def write_json(path, value):
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=1) + "\n").encode("utf8"))


# 1. 经历序列：id / at_ms / tags，次序同 s1x2_reflect.load_documents（按 (事件时刻, id)）
raw = read_json(S1T / "export/hindsight-documents-list.json")
assert raw["total"] == len(raw["items"]) == 108
docs = [dict(id=d["id"], at_ms=iso_ms(d["retain_params"]["event_date"]), tags=list(d["tags"])) for d in raw["items"]]
docs.sort(key=lambda d: (d["at_ms"], d["id"]))
write_lines_json(OUT / "s1t-experiences.json", docs)

# 2. S1-X2 算出的时刻与各轮的问题（原样复制）
shutil.copyfile(X2 / "moments.json", OUT / "s1x2-moments.json")

# 3. 提示词：系统提示词原样；人格卡取 state 的 Character 一行原文
shutil.copyfile(X2 / "system-prompt.txt", OUT / "system-prompt.txt")
state = (S1T / "states/asked-20261113T164745.373Z.txt").read_text(encoding="utf8").split("\n")
(character,) = [l[len("Character: "):] for l in state if l.startswith("Character: ")]
(OUT / "character.txt").write_bytes(character.encode("utf8"))

# 4. 第 1、4 轮 Q_place：此刻一块、材料正文（编号之前）、上一轮的日记、真实发出的用户消息
for k in (1, 4):
    rdir = X2 / "rounds" / str(k)
    shutil.copyfile(rdir / "right-now.txt", OUT / f"round{k}-right-now.txt")
    items = read_json(rdir / "materials-Q_place.json")["items"]
    assert [it["n"] for it in items] == list(range(1, len(items) + 1))
    write_lines_json(OUT / f"round{k}-happened-Q_place.json", [it["body"] for it in items])
    shutil.copyfile(rdir / "user-Q_place.txt", OUT / f"round{k}-user-Q_place.txt")
before = read_json(X2 / "rounds/4/before.json")
write_json(OUT / "round4-before.json", {q: before[q]["journal"] for q in ("Q_place", "Q_person", "Q_self")})

# 5. 检查函数的样本：S1-X2 的真实应答原文、材料条数、离线检查的读数；收尾一句取 S1-X3 新栏里的原文
def sample(k, q, attempt):
    r = read_json(X2 / f"reflections/{k}-{q}.json")
    a = r["attempts"][attempt - 1]
    n_items = len(read_json(X2 / f"rounds/{k}/materials-{q}.json")["items"])
    return dict(source=f"s1x2/reflections/{k}-{q}.json attempt {attempt}", items=n_items,
                sentences=a["check"]["sentences"], used=a["check"]["used"], journal=a["check"]["journal"],
                response=a["text"])


samples = {"4-Q_self": sample(4, "Q_self", 1), "5-Q_place-1": sample(5, "Q_place", 1),
           "5-Q_place-2": sample(5, "Q_place", 2), "1-Q_place": sample(1, "Q_place", 1)}
assert samples["4-Q_self"]["journal"] == (X2 / "reflections/4-Q_self.txt").read_text(encoding="utf8")
prefix = "What I have come to think: "
(line,) = [l for l in (X3 / "variants/N4_selfplan.txt").read_text(encoding="utf8").split("\n") if l.startswith(prefix)]
samples["4-Q_self"]["closing"] = line[len(prefix):]
samples["4-Q_self"]["closing_source"] = "s1x3/variants/N4_selfplan.txt 的 What I have come to think 一行"
# 第 1 轮 Q_place 存进反思库的那份文档（tags 与读回的原文；Life 写库时加的 `At … (UTC), ` 前缀在原文里）
stored = read_json(X2 / "rounds/1/store-Q_place.json")
samples["1-Q_place"]["stored_tags"] = stored["tags"]
samples["1-Q_place"]["stored_text"] = stored["read_back"]["original_text"]
samples["1-Q_place"]["stored_source"] = "s1x2/rounds/1/store-Q_place.json"
write_json(OUT / "check-samples.json", samples)

# 6. 写日记客户端的样本：网关核实时一次真实响应（content 第一块是空的 thinking），原样复制
shutil.copyfile(X3 / "gateway/resp-a-repro.json", OUT / "gateway-response.json")

for p in sorted(OUT.iterdir()):
    print(p.name, p.stat().st_size)
