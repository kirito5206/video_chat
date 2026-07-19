# 备用：信令级双端测试（无真实 WebRTC 栈，仅验证信令链路）
# 证明：register 不超时 / join 互相发现 / offer-answer-candidate 经房间广播可达对端
# 完全复刻 app 行为：字典序较小者为 initiator 主动发 offer，另一方自动回 answer，并互发 candidate
import asyncio, json, websockets, sys, time

SIGNAL = "ws://127.0.0.1:8765"
ROOM = "VTPY_" + str(abs(hash(time.time())))[-6:]

async def client(uid, peer_uid, is_initiator, results):
    async with websockets.connect(SIGNAL) as ws:
        # 1) register（复刻 run7 修复：连上即发 register，否则 10s 被服务器超时断连）
        await ws.send(json.dumps({"type": "register", "from": uid}))
        reg = json.loads(await asyncio.wait_for(ws.recv(), 5))
        results[uid]["registered"] = (reg.get("type") == "registered")
        # 2) join
        await ws.send(json.dumps({"type": "join", "from": uid, "roomId": ROOM}))
        peer_join = False
        members = []
        got_offer = False
        sent_offer = False
        sent_answer = False
        got_answer = False
        cand = 0
        while True:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), 10))
            except asyncio.TimeoutError:
                break
            t = m.get("type")
            if t == "join" and m.get("from") != "server" and m.get("from") != uid:
                peer_join = True
                # 发现对方后，initiator 主动发 offer（复刻 app 字典序发起），并补发 candidate
                if is_initiator and not sent_offer:
                    await asyncio.sleep(0.3)
                    await ws.send(json.dumps({"type": "offer", "from": uid, "to": ROOM, "roomId": ROOM, "data": {"type": "offer", "sdp": "<fake_sdp>"}}))
                    await asyncio.sleep(0.1)
                    await ws.send(json.dumps({"type": "candidate", "from": uid, "to": ROOM, "roomId": ROOM, "data": {"candidate": "<fake_candidate>"}}))
                    sent_offer = True
            if t == "join" and m.get("from") == "server":
                members = (m.get("data") or {}).get("members", [])
            if t == "offer":
                got_offer = True
                # 收到 offer 自动回 answer（复刻 app 自动应答），并补发 candidate
                await ws.send(json.dumps({"type": "answer", "from": uid, "to": ROOM, "roomId": ROOM, "data": {"type": "answer", "sdp": "<fake_sdp>"}}))
                sent_answer = True
                await asyncio.sleep(0.1)
                await ws.send(json.dumps({"type": "candidate", "from": uid, "to": ROOM, "roomId": ROOM, "data": {"candidate": "<fake_candidate>"}}))
            if t == "answer":
                got_answer = True
            if t == "candidate":
                cand += 1
        results[uid].update(peer_join=peer_join, members=members,
                             got_offer=got_offer, sent_offer=sent_offer,
                             sent_answer=sent_answer,
                             got_answer=got_answer, cand=cand)

async def main():
    ua = f"A_{int(time.time())}"
    ub = f"B_{int(time.time())}"
    print(f"ROOM={ROOM}  A(initiator={ua < ub})  B(initiator={ub < ua})")
    results = {ua: {}, ub: {}}
    await asyncio.gather(client(ua, ub, ua < ub, results), client(ub, ua, ub < ua, results))
    print("==== 信令级测试判定（按角色） ====")
    allpass = True
    for uid, r in results.items():
        role = "initiator" if r.get("sent_offer") else "answerer"
        # 发起方：注册 + 发现对方 + 发出 offer + 收到 answer + 收到 candidate
        # 应答方：注册 + 收到 offer + 发出 answer + 收到 candidate
        if role == "initiator":
            ok = (r.get("registered") and r.get("peer_join") and r.get("sent_offer")
                  and r.get("got_answer") and r.get("cand", 0) > 0)
        else:
            ok = (r.get("registered") and r.get("got_offer") and r.get("sent_answer")
                  and r.get("cand", 0) > 0)
        print(f"[{uid}] role={role} registered={r.get('registered')} peerJoin={r.get('peer_join')} sentOffer={r.get('sent_offer')} gotOffer={r.get('got_offer')} sentAnswer={r.get('sent_answer')} gotAnswer={r.get('got_answer')} cand={r.get('cand')} => {'OK' if ok else 'BAD'}")
        allpass = allpass and ok
    # 双方至少一方成功发现对方（discovery 生效）
    discovered = any(r.get("peer_join") for r in results.values())
    print("discovery(至少一方看到对方):", discovered)
    allpass = allpass and discovered
    print("RESULT:", "PASS" if allpass else "FAIL")
    sys.exit(0 if allpass else 1)

asyncio.run(main())
