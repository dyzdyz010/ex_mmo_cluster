"""只测试：从权威发言逐笔核对双端投递，和真实请求/回执关联。"""

FIELDS = ("conversation_id", "turn", "speaker_id", "target_id", "text")


def npc_ready(row):
    """夹具就绪必须有正式 Body 的权威位置，缓存准备好不等于入场成功。"""
    return bool(row['body']['position'] is not None and row['body']['tick'] > 0 and
                row['life']['state'] and row['life']['cache'] and row['life']['error'] is None)


def authority_events(rows):
    """保留 Scene 本轮完整接纳/投递证据；不能静默丢重复或漏掉收件人。"""
    speeches, results = {}, {}
    for row in rows:
        if row["event"] == "dialogue.speech":
            identity = key(row)
            if identity not in speeches:
                speeches[identity] = {**{f: row[f] for f in FIELDS}, "recipients": []}
            event = speeches[identity]
            assert all(event[f] == row[f] for f in FIELDS), f"authority content {identity}"
            assert row["receiver_id"] not in event["recipients"], f"duplicate recipient {identity}"
            event["recipients"].append(row["receiver_id"])
        elif row["event"] == "dialogue.result" and row["reason"] == "ok" and row["recipients"] > 0:
            identity = key(row)
            assert identity not in results, f"duplicate acceptance {identity}"
            results[identity] = row["recipients"]
    assert results.keys() == speeches.keys(), "missing acceptance/speech evidence"
    for identity, count in results.items():
        assert len(speeches[identity]["recipients"]) == count, f"missing recipient evidence {identity}"
    return list(speeches.values())


def key(event):
    return event["conversation_id"], event["turn"]


def indexed(events):
    result = {}
    for event in events:
        identity = key(event)
        assert identity not in result, f"duplicate speech {identity}"
        result[identity] = event
    return result


def delivery(authority, received, actors, npcs):
    truth = indexed(authority)
    assert truth, "no authoritative speech"
    counts = {}
    for role, cid in actors.items():
        heard = indexed(received[role])
        assert all(e["receiver_id"] == cid for e in heard.values()), f"{role}: receiver mismatch"
        expected = {k: e for k, e in truth.items() if cid in e["recipients"]}
        assert not expected.keys() - heard.keys(), f"{role}: missing {expected.keys() - heard.keys()}"
        assert not heard.keys() - expected.keys(), f"{role}: unexpected {heard.keys() - expected.keys()}"
        for identity, event in heard.items():
            assert all(event[f] == expected[identity][f] for f in FIELDS), f"{role}: content {identity}"
        counts[role] = len(heard)
    assert len(npcs) == 2 and len(set(npcs)) == 2, "two distinct NPCs required"
    first, second = npcs
    initiated = {e["conversation_id"] for e in truth.values()
                 if (e["speaker_id"], e["target_id"]) == (first, second)}
    answered = {e["conversation_id"] for e in truth.values()
                if (e["speaker_id"], e["target_id"]) == (second, first)}
    assert initiated & answered, "missing two-way NPC conversation"
    return {"delivered": counts, "npc_to_npc": [list(k) for k, e in truth.items()
            if e["speaker_id"] in npcs and e["target_id"] in npcs and e["speaker_id"] != e["target_id"]]}


def player_request(sent, result, authority, actor):
    assert sent["request_id"] == result["request_id"], "request mismatch"
    assert result["reason"] == "ok", "request not confirmed"
    event = indexed(authority).get(key(result))
    assert event is not None, "confirmed event missing"
    assert (event["speaker_id"], event["target_id"], event["text"]) == (
        actor, sent["target_id"], sent["text"]), "request content mismatch"
    return list(key(event))
