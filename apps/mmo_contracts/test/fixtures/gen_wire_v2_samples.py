# 生成 wire-v2-samples.json（魔法线协议 v2 冻结样本）的作者工具。
#
# 为什么用独立脚本：golden 必须独立于被测的 MmoContracts codec，否则编解码错了样本也会跟着错。
# 本脚本只读 voxel_region 的 ir-v2-samples.json（程序字节）与 quote-v2-samples.json（报价数值），
# 用 struct 按切片 3 决策稿 §3 的字段表逐段拼出大端字节；测试只读结果、从不改写。
#
# 用法（仓库根目录为参数）：python -I apps/mmo_contracts/test/fixtures/gen_wire_v2_samples.py <仓库根>
# 何时重跑：目录 digest、程序样本或报价样本变化后。重跑前先通知客户端，提交后附 commit。
import json, struct, sys

root = sys.argv[1]
ir = json.load(open(f"{root}/apps/voxel_region/test/fixtures/magic/ir-v2-samples.json", encoding="utf-8"))
qs = json.load(open(f"{root}/apps/voxel_region/test/fixtures/magic/quote-v2-samples.json", encoding="utf-8"))
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

doc = {
    "source": "ex_mmo_cluster docs/10-active/magic/2026-11-19-slice3-protocol.md §3.1–3.3；TheWorldBook docs/2026-11-19-glyph-composition-game-design.md v2.11 §11.4.6",
    "note": "Hello 45 魔法线协议 v2 冻结样本：服务端 mmo_contracts 与 Voxim 测试读同一份字节，不另存副本。"
            "每个样本的 segments 逐字段列出偏移（从本帧/本段第 0 字节起）、类型与字节，hex 是 segments 的拼接；"
            "全部大端，f64 为 IEEE 754 binary64 位型。fields 是解码后的字段值（0x83 是编码输入）。改样本前先通知客户端，提交后附 commit。",
    "protocol_version": 45,
    "catalog_digest": digest,
    "ir_samples": "apps/voxel_region/test/fixtures/magic/ir-v2-samples.json（program_hex 的唯一来源；本文件的程序字节须与之相同，catalog_digest 亦同）",
    "quote_samples": "apps/voxel_region/test/fixtures/magic/quote-v2-samples.json（0x83 报价字段与施放记录 steps 的来源）",
    "rejects_bits": ["capacity", "domain", "first_tick", "ambient_floor", "thermal_step"],
    "rejects_note": "0x83 rejects 位掩码的第 i 位 = rejects_bits[i]（T5、T6、T13、T14、T15）；0x68 拒绝原因串 \"rejects:<检查名,…>\" 按同一位序以逗号连接，如 \"rejects:first_tick,thermal_step\"；射线在射程内没命中为 \":no_target\"",
    "generator": "apps/mmo_contracts/test/fixtures/gen_wire_v2_samples.py（仓库根为参数）；不调用被测 codec",
    "verified_by": "测试 apps/mmo_contracts/test/mmo_contracts/magic_wire_test.exs 只读本文件：断言 segments 拼接 = hex、解码/编码与 hex 逐字节一致；本文件不由测试改写",
    "samples": [spell, caster, casts],
    "negatives": negatives,
}
out = f"{root}/apps/mmo_contracts/test/fixtures/wire-v2-samples.json"
import os; os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2); fh.write("\n")
print(out, spell["total_bytes"], caster["total_bytes"], casts["total_bytes"])
