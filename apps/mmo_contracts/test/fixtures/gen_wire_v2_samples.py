# 生成 wire-v2-samples.json（魔法线协议 v2 冻结样本）的作者工具。
#
# 为什么用独立脚本：golden 必须独立于被测的 MmoContracts codec，否则编解码错了样本也会跟着错。
# 本脚本只读 voxel_region 的 ir-v2-samples.json（程序字节）、quote-v2-samples.json（报价数值）与
# structure-v2-samples.json（结构记录字段值，由服务端 Structure.wire/1 等产品函数产出），用 struct 按切片 3 决策稿 §3
# 与切片 4 决策稿（2026-11-26-p1-closure-slices4-8.md）§3 的字段表逐段拼出大端字节；测试只读结果、从不改写。
#
# 用法（仓库根目录为参数）：python -I apps/mmo_contracts/test/fixtures/gen_wire_v2_samples.py <仓库根>
# 何时重跑：目录 digest、程序样本、报价样本或结构样本变化后。重跑前先通知客户端，提交后附 commit。
import json, math, struct, sys

root = sys.argv[1]
ir = json.load(open(f"{root}/apps/voxel_region/test/fixtures/magic/ir-v2-samples.json", encoding="utf-8"))
qs = json.load(open(f"{root}/apps/voxel_region/test/fixtures/magic/quote-v2-samples.json", encoding="utf-8"))
ss = json.load(open(f"{root}/apps/voxel_region/test/fixtures/magic/structure-v2-samples.json", encoding="utf-8"))
fireball_hex = next(s["program_hex"] for s in ir["samples"] if s["id"] == "fireball")
fq = next(p["quote"] for p in qs["presets"] if p["id"] == "fireball")
digest = ir["catalog_digest"]

def u(n, bits): return n.to_bytes(bits // 8, "big").hex()
def i64(n): return struct.pack(">q", n).hex()
def f64(x): return struct.pack(">d", float(x)).hex()

class Seg:
    def __init__(self): self.segs = []; self.off = 0
    def add(self, field, typ, hexs):
        self.segs.append({"offset": self.off, "field": field, "type": typ, "hex": hexs})
        self.off += len(hexs) // 2
    def hex(self): return "".join(s["hex"] for s in self.segs)

# ---- 0x82 v2 ----
f82 = {"request_id": 9, "client_intent_seq": 2, "logical_scene_id": 3, "action": 0,
       "catalog_digest": digest, "direction": [0.0, 0.0, 1.0], "micro": [-8, 16, 24],
       "incarnation": 5, "owner": [0, 0], "material": 28, "granularity": 0,
       "program_hex": fireball_hex}
s = Seg()
s.add("opcode", "u8", "82")
s.add("request_id", "u64", u(9, 64))
s.add("client_intent_seq", "u32", u(2, 32))
s.add("logical_scene_id", "u64", u(3, 64))
s.add("action", "u8", u(0, 8))
s.add("catalog_digest", "32B", digest)
for k, v in zip("xyz", f82["direction"]): s.add(f"direction.{k}", "f64", f64(v))
for k, v in zip("xyz", f82["micro"]): s.add(f"micro.{k}", "i64", i64(v))
s.add("incarnation", "u64", u(5, 64))
s.add("owner.birth", "u64", u(0, 64))
s.add("owner.occurrence", "u32", u(0, 32))
s.add("material", "u16", u(28, 16))
s.add("granularity", "u8", u(0, 8))
plen = len(fireball_hex) // 2
s.add("program_len", "u16", u(plen, 16))
s.add("program", f"{plen}B", fireball_hex)
spell = {"id": "spell_intent_fireball_quote", "frame": "0x82 v2", "direction": "上行",
         "design": "报价（action 0）：火球程序，准星微格 (−8, 16, 24)，眼睛方向 +Z",
         "program_sample": "fireball", "total_bytes": s.off, "fields": f82, "segments": s.segs, "hex": s.hex()}
assert s.off == 127 + plen

# ---- 0x83 v2 ----
energy_j = 300.0
f83 = {"request_id": 9, "seq": 10, "energy_j": energy_j, "capacity_j": 5000000.0, "resolution_eff": 16.0,
       "quote_j": fq["total_mj"] / 1000, "quote_s": float(fq["units"] * fq["precision"]), "spent_j": 0.0,
       "quote_windup_s": fq["windup_s"], "x0": fq["x0"], "x_star": fq["x_star"], "e_min_j": fq["e_min_mj"] / 1000,
       "p_maint_w": fq["p_maint_w"], "life_s": fq["life_s"], "detect_w": fq["detect_w"],
       "fail_step": 2, "rejects": [], "entries_charge": fq["entries_charge"], "entries_spoof": fq["entries_spoof"],
       "first_tick_min_j": fq["first_tick_min_mj"] / 1000}
# fail_step 由报价 steps 与余额推出（Cost.staged_failure/3 的口径，此处只作作者核对）。
k = next(i for i, st in enumerate(fq["steps"], 1) if st["complexity"] > 16 or st["spent_mj"] > energy_j * 1000)
assert k == 2, k
s = Seg()
s.add("opcode", "u8", "83")
s.add("request_id", "u64", u(9, 64))
s.add("seq", "u64", u(10, 64))
for name in ["energy_j", "capacity_j", "resolution_eff", "quote_j", "quote_s", "spent_j", "quote_windup_s",
             "x0", "x_star", "e_min_j", "p_maint_w", "life_s", "detect_w", "fail_step"]:
    s.add(name, "f64", f64(f83[name]))
s.add("rejects", "f64", f64(0))
for name in ["entries_charge", "entries_spoof", "first_tick_min_j"]:
    s.add(name, "f64", f64(f83[name]))
assert s.off == 161
caster = {"id": "caster_state_fireball_quote", "frame": "0x83 v2", "direction": "下行",
          "design": "回复上面的 0x82 报价：施法者余额 300 J、容量 5 MJ、Ω_eff = 16 × 1.0；报价字段取 quote-v2-samples.json 的 fireball，"
                    "fail_step = 2（第 2 步累计支出 1194196 mJ 超过余额 300000 mJ），rejects 为空",
          "quote_sample": "fireball", "total_bytes": s.off, "fields": f83, "segments": s.segs, "hex": s.hex()}

# ---- 施放记录 v2 ----
steps = [{"part_index": st["part_index"], "adjust_s": st["adjust_s"], "inject_s": st["inject_s"]} for st in fq["steps"]]

def cast_record(caster_id, live, outcome, fail_step, t0, origin, steps, program_hex, prefix):
    s = Seg()
    s.add(f"{prefix}.caster", "u64", u(caster_id, 64))
    s.add(f"{prefix}.live", "u8", u(live, 8))
    s.add(f"{prefix}.outcome", "u8", u(outcome, 8))
    s.add(f"{prefix}.fail_step", "u8", u(fail_step, 8))
    s.add(f"{prefix}.t0_us", "u64", u(t0, 64))
    for k, v in zip("xyz", origin): s.add(f"{prefix}.origin.{k}", "f64", f64(v))
    s.add(f"{prefix}.n", "u8", u(len(steps), 8))
    for j, st in enumerate(steps):
        s.add(f"{prefix}.steps[{j}].part_index", "u8", u(st["part_index"], 8))
        s.add(f"{prefix}.steps[{j}].adjust_s", "f64", f64(st["adjust_s"]))
        s.add(f"{prefix}.steps[{j}].inject_s", "f64", f64(st["inject_s"]))
    s.add(f"{prefix}.program_len", "u16", u(len(program_hex) // 2, 16))
    if program_hex: s.add(f"{prefix}.program", f"{len(program_hex)//2}B", program_hex)
    return s

settled = cast_record(1001, 0, 1, 2, 0, [0.0, 0.0, 0.0], [], "", "1001")
pending = cast_record(1002, 1, 0, 0, 1_700_000_000_000_000, [0.5, 2.5, 1.0], steps, fireball_hex, "1002")
assert settled.off == 46 and pending.off == 46 + 7 * 17 + plen
segs = settled.segs + [dict(x, offset=x["offset"] + settled.off) for x in pending.segs]
casts = {"id": "casts_fireball", "frame": "PropertyBatch casts（施放记录 v2）", "direction": "下行（广播）",
         "design": "施法者 1001：已结算，火球建构在第 2 步中断（outcome 1，fail_step 2，与上面的 0x83 同一情形），其余字段全 0；"
                   "施法者 1002：火球前摇中，t0 = 1.7e15 µs、手边点 (0.5, 2.5, 1.0)，7 步取 quote-v2-samples.json fireball 的"
                   " steps（part_index、adjust_s、inject_s），程序为 ir-v2-samples.json fireball",
         "program_sample": "fireball", "quote_sample": "fireball",
         "total_bytes": settled.off + pending.off,
         "fields": {"1001": {"live": 0, "outcome": 1, "fail_step": 2},
                    "1002": {"live": 1, "t0_us": 1_700_000_000_000_000, "origin": [0.5, 2.5, 1.0], "steps": steps,
                             "program_hex": fireball_hex}},
         "segments": segs, "hex": settled.hex() + pending.hex()}

# ---- 结构记录 v2（切片 4 决策稿 §3.1，每条 160 B）----
# 位表（与决策稿 §3.1 逐字相同；codec 另有自己的定义，二者由本样本对拍）。
FLAG_BITS = {"ends_on_contact": 0, "massless": 1}
COUPLING_BITS = ["thermal", "glow", "capacity", "disrupt"]
STATUS_BITS = ["overline", "folded", "feeding", "vent_damaged", "flying", "asleep"]

def mask(table, names):
    m = 0
    for name in names: m |= 1 << table.index(name)
    return m

def structure_record(sid, f, prefix):
    s = Seg()
    s.add(f"{prefix}.id_seq", "u64", u(sid[0], 64))
    s.add(f"{prefix}.id_n", "u32", u(sid[1], 32))
    if f is None:
        s.add(f"{prefix}.live", "u8", "00")
        s.add(f"{prefix}.zero", "147B", "00" * 147)
        assert s.off == 160
        return s
    flags = (1 << FLAG_BITS["ends_on_contact"] if f["ends_on_contact"] else 0) | (1 << FLAG_BITS["massless"] if f["massless"] else 0)
    s.add(f"{prefix}.live", "u8", u(f["live"], 8))
    s.add(f"{prefix}.caster", "u64", u(f["caster"], 64))
    s.add(f"{prefix}.shape", "u8", u(f["shape"], 8))
    s.add(f"{prefix}.flags", "u8", u(flags, 8))
    s.add(f"{prefix}.size1_m", "f64", f64(f["size1_m"]))
    s.add(f"{prefix}.temperature_k", "f64", f64(f["temperature_k"]))
    s.add(f"{prefix}.glow_w", "f64", f64(f["glow_w"]))
    for k, v in zip("xyz", f["origin"]): s.add(f"{prefix}.origin.{k}", "f64", f64(v))
    for k, v in zip("xyz", f["velocity"]): s.add(f"{prefix}.velocity.{k}", "f64", f64(v))
    s.add(f"{prefix}.t0_us", "u64", u(f["t0_us"], 64))
    s.add(f"{prefix}.flight_s", "f64", f64(f["flight_s"]))
    for k, v in zip("xyz", f["rest"]): s.add(f"{prefix}.rest.{k}", "f64", f64(v))
    assert s.off == 135
    s.add(f"{prefix}.size2_mm", "u16", u(f["size2_mm"], 16))
    s.add(f"{prefix}.size3_mm", "u16", u(f["size3_mm"], 16))
    s.add(f"{prefix}.proto_id", "u16", u(f["proto_id"], 16))
    s.add(f"{prefix}.coupling_mask", "u16", u(mask(COUPLING_BITS, f["coupling"]), 16))
    s.add(f"{prefix}.load", "u8", u(f["load"], 8))
    s.add(f"{prefix}.coherence", "u8", u(f["coherence"], 8))
    s.add(f"{prefix}.status", "u8", u(mask(STATUS_BITS, f["status"]), 8))
    s.add(f"{prefix}.failed_segments", "u8", u(f["failed_segments"], 8))
    s.add(f"{prefix}.anchor_type", "u8", u(f["anchor_type"], 8))
    s.add(f"{prefix}.anchor_ref", "12B", f["anchor_ref"])
    assert s.off == 160
    return s

def sid_key(sid): return f"{sid[0]}:{sid[1]}"

records = {r["id"]: r for r in ss["records"]}
structure_samples = []
for r in ss["records"]:
    s = structure_record(r["sid"], r["fields"], sid_key(r["sid"]))
    structure_samples.append({
        "id": f"structure_record_v2_{r['id']}", "frame": "PropertyBatch structures（结构记录 v2）", "direction": "下行（广播）",
        "design": r["design"] + (f"；预设 {r['preset']}，第 {r['tick']} 拍" if r["preset"] else ""),
        "structure_sample": r["id"], "event": r["event"], "total_bytes": s.off,
        "fields": {sid_key(r["sid"]): r["fields"]}, "segments": s.segs, "hex": s.hex()})

# ---- 结构状态增量（切片 4 决策稿 §3.3，每条 20 B）----
# 温度 0.1 K、发光 W：四舍五入（半数远离零），饱和到 65535。x − floor(x) 对 binary64 精确，故判定 ≥ 0.5 无舍入误差。
def round_half_away(x):
    assert x >= 0
    q = math.floor(x)
    return q + (1 if x - q >= 0.5 else 0)

def state_fields(w):
    return {"load": w["load"], "coherence": w["coherence"], "status": w["status"], "failed_segments": w["failed_segments"],
            "temperature_dk": min(65535, round_half_away(w["temperature_k"] * 10)), "glow_w": min(65535, round_half_away(w["glow_w"]))}

def state_record(sid, st, prefix):
    s = Seg()
    s.add(f"{prefix}.id_seq", "u64", u(sid[0], 64))
    s.add(f"{prefix}.id_n", "u32", u(sid[1], 32))
    s.add(f"{prefix}.load", "u8", u(st["load"], 8))
    s.add(f"{prefix}.coherence", "u8", u(st["coherence"], 8))
    s.add(f"{prefix}.status", "u8", u(mask(STATUS_BITS, st["status"]), 8))
    s.add(f"{prefix}.failed_segments", "u8", u(st["failed_segments"], 8))
    s.add(f"{prefix}.temperature_dk", "u16", u(st["temperature_dk"], 16))
    s.add(f"{prefix}.glow_w", "u16", u(st["glow_w"], 16))
    assert s.off == 20
    return s

states = sorted(ss["states"], key=lambda x: x["sid"])
state_segs = [state_record(x["sid"], state_fields(x["state"]), sid_key(x["sid"])) for x in states]

def concat(parts):
    segs, off = [], 0
    for p in parts:
        segs += [dict(x, offset=x["offset"] + off) for x in p.segs]
        off += p.off
    return segs, off, "".join(p.hex() for p in parts)

segs, total, hexs = concat(state_segs)
states_sample = {"id": "structure_states_v2", "frame": "PropertyBatch structure_states（结构状态增量）", "direction": "下行（广播）",
                 "design": "；".join(f"{x['sid']}：预设 {x['preset']} 第 {x['tick']} 拍（装载分箱 ⌊x·32⌋ 相对上一拍改变）" for x in states),
                 "source_states": [{"sid": x["sid"], "preset": x["preset"], "tick": x["tick"], "state": x["state"]} for x in states],
                 "total_bytes": total, "fields": {sid_key(x["sid"]): state_fields(x["state"]) for x in states},
                 "segments": segs, "hex": hexs}

# ---- PropertyBatch（M1 Voxel envelope 类型 5）：结构记录与状态增量同批 ----
BATCH_IDENTITY = [1, 2, 3]
def property_batch(complete, structure_parts, state_parts, prefix="batch"):
    body = Seg()
    for name, v in zip(["session_epoch", "scene_id", "scene_epoch"], BATCH_IDENTITY): body.add(f"identity.{name}", "u64", u(v, 64))
    body.add("transaction_seq", "u64", u(7, 64))
    for k in "xyz": body.add(f"l0_min.{k}", "i32", struct.pack(">i", 0).hex())
    for k in "xyz": body.add(f"l0_max_exclusive.{k}", "i32", struct.pack(">i", 1).hex())
    body.add("complete", "u8", u(complete, 8))
    body.add("hp_enabled", "u8", "01")
    body.add("digest", "32B", "a5" * 32)
    body.add("thermal_enabled", "u8", "01")
    body.add("ambient_kelvin", "f64", f64(293.15))
    body.add("epochs.len", "u32", u(0, 32))
    body.add("states.count", "u32", u(0, 32))
    body.add("protection.len", "u32", u(0, 32))
    shex = "".join(p.hex() for p in structure_parts)
    body.add("structures.len", "u32", u(len(shex) // 2, 32))
    if shex: body.add("structures", f"{len(shex)//2}B", shex)
    body.add("casts.len", "u32", u(0, 32))
    thex = "".join(p.hex() for p in state_parts)
    body.add("structure_states.len", "u32", u(len(thex) // 2, 32))
    if thex: body.add("structure_states", f"{len(thex)//2}B", thex)
    frame = Seg()
    frame.add("envelope.marker", "u8", "ff")
    frame.add("envelope.version", "u16", u(1, 16))
    frame.add("envelope.domain", "u8", "03")
    frame.add("envelope.kind", "u8", "05")
    frame.add("envelope.body_len", "u32", u(body.off, 32))
    for x in body.segs: frame.segs.append(dict(x, offset=x["offset"] + frame.off))
    frame.off += body.off
    return frame

record_parts = {r["id"]: structure_record(r["sid"], r["fields"], sid_key(r["sid"])) for r in ss["records"]}
batch_ids = ["deleted", "fireball_flight", "fireball_contact", "lamp_exhausted", "lamp_collapsed", "lamp_dispelled"]
batch = property_batch(0, [record_parts[i] for i in batch_ids], state_segs)
state_sids = {tuple(x["sid"]) for x in states}
assert not ({tuple(records[i]["sid"]) for i in batch_ids} & state_sids)
batch_sample = {"id": "property_batch_structures_v2", "frame": "M1 Voxel PropertyBatch（domain 3，kind 5）", "direction": "下行",
                "design": "增量批（complete 0）：structures 依次为 " + "、".join(f"structure_record_v2_{i}" for i in batch_ids)
                          + "（id 升序）；casts 为空；structure_states 同 structure_states_v2（id 与 structures 不重）。"
                          "字段顺序：…protection、structures、casts、structure_states（Hello 46 末尾新增 structure_states）",
                "structure_samples": batch_ids, "states_sample": "structure_states_v2",
                "identity": BATCH_IDENTITY, "transaction_seq": 7, "l0_min": [0, 0, 0], "l0_max_exclusive": [1, 1, 1],
                "complete": 0, "hp_enabled": 1, "digest_hex": "a5" * 32, "thermal_enabled": 1, "ambient_kelvin": 293.15,
                "total_bytes": batch.off, "segments": batch.segs, "hex": batch.hex()}

# ---- 反例 ----
spell_hex = spell["hex"]
def put_u16(h, off, v): return h[:off*2] + u(v, 16) + h[off*2+4:]
bad_perm_steps = [dict(st) for st in steps]; bad_perm_steps[6]["part_index"] = 5
bad_perm = cast_record(1002, 1, 0, 0, 1_700_000_000_000_000, [0.5, 2.5, 1.0], bad_perm_steps, fireball_hex, "1002").hex()
v1 = ("82" + u(1, 64) + u(2, 32) + u(3, 64) + "01" + "11" * 32 + f64(0.0) + f64(-1.0) + f64(0.0)
      + i64(-8) + i64(16) + i64(24) + u(5, 64) + u(0, 64) + u(0, 32) + u(28, 16) + "00"
      + u(7, 64) + u(1, 32) + "0002" + "7b7d")
negatives = [
    {"id": "spell_intent_program_len_overrun", "frame": "0x82 v2", "expect": "invalid_message",
     "mutation": f"偏移 125 的 program_len 改为 {plen + 1}，实际只剩 {plen} B 程序", "hex": put_u16(spell_hex, 125, plen + 1)},
    {"id": "spell_intent_program_len_underrun", "frame": "0x82 v2", "expect": "invalid_message",
     "mutation": f"偏移 125 的 program_len 改为 {plen - 1}，帧尾多出 1 B", "hex": put_u16(spell_hex, 125, plen - 1)},
    {"id": "spell_intent_v1_layout", "frame": "0x82 v1（Hello 44）", "expect": "invalid_message",
     "mutation": "v1 冻结样本（139 + 2 B：偏移 125 起是 12 B 拟态 id {7, 1}，程序 \"{}\"）按 v2 布局解码：program_len 读到 0，帧尾多 14 B",
     "hex": v1},
    {"id": "casts_part_index_not_permutation", "frame": "PropertyBatch casts（施放记录 v2）", "expect": "invalid_cast",
     "mutation": "casts_fireball 的施法者 1002 记录，第 7 步 part_index 6 改为 5（5 出现两次、缺 6）；编码端对同一记录显式失败",
     "hex": bad_perm,
     "fields": {"1002": {"live": 1, "t0_us": 1_700_000_000_000_000, "origin": [0.5, 2.5, 1.0], "steps": bad_perm_steps,
                         "program_hex": fireball_hex}}},
]

# 结构记录 / 状态增量 / PropertyBatch 反例（切片 4 决策稿 §13 C4-2、C4-3 与 §9 清单）。偏移从本条记录第 0 字节起。
def put_u8(h, off, v): return h[:off*2] + u(v, 8) + h[off*2+2:]
def put_hex(h, off, part): return h[:off*2] + part + h[off*2+len(part):]
lamp_hex = record_parts["lamp_born"].hex()
flight_hex = record_parts["fireball_flight"].hex()
contact_hex = record_parts["fireball_contact"].hex()
deleted_hex = record_parts["deleted"].hex()
assert lamp_hex[22*2:23*2] == "02" and contact_hex[22*2:23*2] == "01"
structure_negatives = [
    ("structure_live_7", "invalid_structure", "lamp_born 偏移 12 的 live 改为 7（Hello 46 只定义 0–6）", put_u8(lamp_hex, 12, 7)),
    ("structure_shape_3", "invalid_structure", "lamp_born 偏移 21 的 shape 改为 3（只收 0 球 / 1 块 / 2 板）", put_u8(lamp_hex, 21, 3)),
    ("structure_flags_reserved", "invalid_structure", "lamp_born 偏移 22 的 flags 由 0x02 改为 0x06（第 2 位是保留位）", put_u8(lamp_hex, 22, 6)),
    ("structure_temperature_negative", "invalid_structure", "fireball_flight 偏移 31 的 temperature_k 改为 −1.0", put_hex(flight_hex, 31, f64(-1.0))),
    ("structure_live2_without_contact", "invalid_structure", "fireball_contact（live 2）偏移 22 的 flags 由 0x01 改为 0x00：接触终止要求 ends_on_contact", put_u8(contact_hex, 22, 0)),
    ("structure_coupling_reserved", "invalid_structure", "lamp_born 偏移 141 的 coupling_mask 由 0x0002 改为 0x0012（第 4 位是保留位）", put_hex(lamp_hex, 141, u(0x12, 16))),
    ("structure_status_reserved", "invalid_structure", "lamp_born 偏移 145 的 status 改为 0x40（第 6 位是保留位）", put_u8(lamp_hex, 145, 0x40)),
    ("structure_sphere_size2", "invalid_structure", "lamp_born（球）偏移 135 的 size2_mm 改为 1（球的尺寸 2、3 必须为 0）", put_hex(lamp_hex, 135, u(1, 16))),
    ("structure_anchor_type_2", "invalid_structure", "lamp_born 偏移 147 的 anchor_type 改为 2（只收 0 手边 / 1 格面）", put_u8(lamp_hex, 147, 2)),
    ("structure_deleted_nonzero", "invalid_structure", "deleted（live 0）偏移 40 改为 1：删除记录除 id 外必须全 0", put_u8(deleted_hex, 40, 1)),
    ("structure_unsorted", "invalid_structure", "fireball_flight {102, 0} 在前、lamp_born {101, 0} 在后：id 必须升序且唯一", flight_hex + lamp_hex),
    ("structure_truncated", "invalid_structure", "lamp_born 去掉最后 1 B（159 B）", lamp_hex[:-2]),
]
s_lamp, s_ember = state_segs[0].hex(), state_segs[1].hex()
structure_negatives += [
    ("structure_states_unsorted", "invalid_structure_state", "structure_states_v2 的两条倒序（{107, 0} 在 {101, 0} 之前）", s_ember + s_lamp),
    ("structure_states_duplicate", "invalid_structure_state", "structure_states_v2 的第一条重复两次", s_lamp + s_lamp),
    ("structure_states_status_reserved", "invalid_structure_state", "structure_states_v2 第一条偏移 14 的 status 改为 0x80（第 7 位是保留位）", put_u8(s_lamp, 14, 0x80) + s_ember),
]
batch_negatives = [
    ("property_batch_complete_with_terminal", "完整批（complete 1）含 lamp_born（live 1）与 lamp_exhausted（live 3）：完整快照只能含存在中的结构",
     property_batch(1, [record_parts["lamp_born"], record_parts["lamp_exhausted"]], [])),
    ("property_batch_complete_with_deleted", "完整批含 deleted（live 0）与 fireball_flight（live 1）：完整快照不含删除",
     property_batch(1, [record_parts["deleted"], record_parts["fireball_flight"]], [])),
    ("property_batch_complete_with_states", "完整批只含 fireball_flight（live 1），却带 structure_states_v2：完整批不带状态增量",
     property_batch(1, [record_parts["fireball_flight"]], state_segs)),
    ("property_batch_state_overlaps_record", "增量批含 lamp_born {101, 0}，structure_states_v2 也有 {101, 0}：同批已有结构记录的 id 不得再出现在增量里",
     property_batch(0, [record_parts["lamp_born"]], state_segs)),
]
negatives += [{"id": i, "frame": "PropertyBatch structures（结构记录 v2）" if e == "invalid_structure" else "PropertyBatch structure_states（结构状态增量）",
               "expect": e, "mutation": m, "hex": h} for i, e, m, h in structure_negatives]
negatives += [{"id": i, "frame": "M1 Voxel PropertyBatch（domain 3，kind 5）", "expect": "invalid_m1_message", "mutation": m,
               "complete": int(f.segs[[x["field"] for x in f.segs].index("complete")]["hex"], 16), "hex": f.hex()} for i, m, f in batch_negatives]

doc = {
    "source": "ex_mmo_cluster docs/10-active/magic/2026-11-19-slice3-protocol.md §3.1–3.3、2026-11-26-p1-closure-slices4-8.md §3；TheWorldBook docs/2026-11-19-glyph-composition-game-design.md v2.11 §11.1–11.3、§11.4.6",
    "note": "Hello 46 魔法线协议 v2 冻结样本：服务端 mmo_contracts 与 Voxim 测试读同一份字节，不另存副本。"
            "每个样本的 segments 逐字段列出偏移（从本帧/本段第 0 字节起）、类型与字节，hex 是 segments 的拼接；"
            "全部大端，f64 为 IEEE 754 binary64 位型。fields 是解码后的字段值（0x83 是编码输入）。改样本前先通知客户端，提交后附 commit。",
    "protocol_version": 46,
    "catalog_digest": digest,
    "ir_samples": "apps/voxel_region/test/fixtures/magic/ir-v2-samples.json（program_hex 的唯一来源；本文件的程序字节须与之相同，catalog_digest 亦同）",
    "quote_samples": "apps/voxel_region/test/fixtures/magic/quote-v2-samples.json（0x83 报价字段与施放记录 steps 的来源）",
    "structure_samples": "apps/voxel_region/test/fixtures/magic/structure-v2-samples.json（结构记录与状态增量字段值的来源：服务端 Program.decode_ir/2、Cost.quote_structure/3、Structure.new/4、step/4、respond/3、wire/1 的产出）",
    "structure_flag_bits": ["ends_on_contact", "massless"],
    "structure_coupling_bits": COUPLING_BITS,
    "structure_status_bits": STATUS_BITS,
    "structure_live": {"0": "无事件删除（id 之外 147 B 全 0）", "1": "存在", "2": "接触触发的〈散〉（含〈遇〉→〈散〉；要求 ends_on_contact）",
                       "3": "断供衰竭", "4": "过载崩解", "5": "驱散", "6": "非接触读数（〈时〉〈满〉）触发的〈散〉", "≥7": "Hello 46 拒绝"},
    "structure_note": "结构记录 v2 每条 160 B（前 135 B 沿用原拟态记录偏移，135 起为新增字段），按 id 升序且唯一；live 2–6 一律带终态完整快照，"
                      "完整快照批（complete 1）只含 live 1 且不带 structure_states。状态增量每条 20 B，按 id 升序且唯一，"
                      "temperature_dk = round(T·10)、glow_w = round(W)（半数远离零），饱和到 65535；同批已有结构记录的 id 不得再出现在增量里。"
                      "flags 第 1 位 massless 为 1 时客户端插值不加重力项。",
    "rejects_bits": ["capacity", "domain", "first_tick", "ambient_floor", "thermal_step"],
    "rejects_note": "0x83 rejects 位掩码的第 i 位 = rejects_bits[i]（T5、T6、T13、T14、T15）；0x68 拒绝原因串 \"rejects:<检查名,…>\" 按同一位序以逗号连接，如 \"rejects:first_tick,thermal_step\"；射线在射程内没命中为 \":no_target\"",
    "generator": "apps/mmo_contracts/test/fixtures/gen_wire_v2_samples.py（仓库根为参数）；不调用被测 codec",
    "verified_by": "测试 apps/mmo_contracts/test/mmo_contracts/magic_wire_test.exs 只读本文件：断言 segments 拼接 = hex、解码/编码与 hex 逐字节一致；本文件不由测试改写",
    "samples": [spell, caster, casts] + structure_samples + [states_sample, batch_sample],
    "negatives": negatives,
}
out = f"{root}/apps/mmo_contracts/test/fixtures/wire-v2-samples.json"
import os; os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2); fh.write("\n")
print(out, spell["total_bytes"], caster["total_bytes"], casts["total_bytes"], len(structure_samples), states_sample["total_bytes"], batch_sample["total_bytes"], len(negatives))
