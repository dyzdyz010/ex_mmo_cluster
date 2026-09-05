"""测量真实烘焙地形的一格修改：HTTP 全载荷与 entries；结束恢复原材质。"""
import json
import pathlib
import struct
import sys
import urllib.request
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[4] / "Voxim/Docs/R6/tools"))
import gate_client
import regions_client


def post(items, cv):
    req = urllib.request.Request(regions_client.URL, data=regions_client.request(items, cv),
                                 headers={"Content-Type": "application/octet-stream"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as response:
        return response.read()


coord = (40, 504, 39)
items = [(lv, tuple(v // (64 * (1 << lv)) for v in coord), 0, 0) for lv in range(6)]
(cv, replies), _, full_bytes = regions_client.post(items)
old = []
for lv, region, kind, payload in replies:
    if payload:
        header = regions_client.header(payload)
        old.append((lv, region, header["seq"], header["hash"]))
payload = replies[0][3]
header = regions_client.header(payload)
body = zlib.decompress(payload[54:])
local = tuple(coord[i] - header["region"][i] * 64 + 1 for i in range(3))
index = local[0] + 66 * (local[1] + 66 * local[2])
material = struct.unpack_from("<H", body, 4 + index * 2)[0]
gate, _ = gate_client.session("voxim_s3_http_probe")
gate.subscribe(max(item[2] for item in old), (-8, -8, -8, 8, 12, 8), 1)


def edit(m, seq):
    rid = gate.batch_edit([(*coord, m)], seq)
    frames, ref = {}, None
    while ref is None or ref not in frames:
        frame = gate.recv(300)
        if frame[0] == 0x79:
            frames[struct.unpack_from("<Q", frame, 1)[0]] = len(frame)
        if frame[0] == 0x68 and struct.unpack_from(">Q", frame, 1)[0] == rid:
            ref = struct.unpack_from(">Q", frame, 22)[0]
    return ref, frames[ref]


ref, wire_bytes = edit(11 if material == 0 else 0, 1)
try:
    response = post(old, cv)
    offset, kinds = 20, []
    for _ in old:
        level, x, y, z, kind = struct.unpack_from("<BiiiB", response, offset)
        offset += 14
        kinds.append((level, kind))
        if kind == 1:
            count = struct.unpack_from("<I", response, offset)[0]
            offset += 4
            for _ in range(count):
                size = struct.unpack_from("<I", response, offset)[0]
                offset += 4 + size
        elif kind == 2:
            size = struct.unpack_from("<I", response, offset)[0]
            offset += 4 + size
    assert offset == len(response)
    assert post(old, cv) == response
    print(json.dumps(dict(coord=coord, old_material=material, result_seq=ref,
                          transaction_bytes=wire_bytes, original_full_bytes=full_bytes,
                          http_bytes=len(response), kinds=kinds), indent=2))
finally:
    edit(material, 2)
    gate.s.close()
