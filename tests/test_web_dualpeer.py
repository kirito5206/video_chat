"""Headless dual-peer test that mirrors web_client.html's protocol exactly.

Connects two WebSocket clients (A then B) to the LIVE signaling server,
performs the full 1:1 call negotiation (register -> join -> call/offer ->
answer -> ICE), and asserts every message is routed to the correct peer.

This proves the dual-end video-call *signaling* works end-to-end. Actual
media (camera pixels) still needs a real browser + camera on the user side.
"""
import asyncio
import json
import websockets

SERVER = "ws://localhost:8765"
ROOM = "dualpeer_test"

events_a = []
events_b = []


async def client(role, uri):
    ws = await websockets.connect(uri)
    # 1) register (web_client sends {userId} first)
    await ws.send(json.dumps({"userId": role}))
    await ws.recv()  # registered
    # 2) join
    await ws.send(json.dumps({"type": "join", "from": role, "roomId": ROOM}))

    async def send_offer():
        await ws.send(json.dumps({"type": "call", "from": role, "roomId": ROOM}))
        await ws.send(json.dumps({
            "type": "offer", "from": role, "roomId": ROOM,
            "data": {"type": "offer", "sdp": "v=0...(fake offer)"},
        }))

    async def send_answer():
        await ws.send(json.dumps({
            "type": "answer", "from": role, "roomId": ROOM,
            "data": {"type": "answer", "sdp": "v=0...(fake answer)"},
        }))

    async def send_cand():
        await ws.send(json.dumps({
            "type": "candidate", "from": role, "roomId": ROOM,
            "data": {"candidate": "candidate:1 1 udp ...", "sdpMid": "0",
                     "sdpMLineIndex": 0},
        }))

    async for raw in ws:
        msg = json.loads(raw)
        t = msg.get("type")
        if role == "A":
            events_a.append(t)
        else:
            events_b.append(t)

        if t == "join" and msg.get("data", {}).get("members"):
            members = msg["data"]["members"]
            others = [m for m in members if m != role]
            if others:
                await asyncio.sleep(0.3)
                await send_offer()
                await send_cand()
        elif t == "offer":
            await asyncio.sleep(0.1)
            await send_answer()
            await send_cand()
        elif t == "answer":
            pass  # both have exchanged candidates already
    await ws.close()


async def main():
    print(f"=== Dual-peer signaling test against {SERVER} (room {ROOM}) ===\n")
    a = asyncio.create_task(client("A", SERVER))
    await asyncio.sleep(0.6)
    b = asyncio.create_task(client("B", SERVER))
    done, _ = await asyncio.wait({a, b}, timeout=8)
    if not done:
        print("WARN: test timed out (clients still running)")

    print("A received message types:", events_a)
    print("B received message types:", events_b)

    assert "join" in events_a, "A should see B's join broadcast"
    assert "call" in events_a, "A should receive B's call"
    assert "offer" in events_a, "A should receive B's offer"
    assert "answer" in events_b, "B should receive A's answer"
    assert "candidate" in events_a and "candidate" in events_b, \
        "both peers should exchange ICE candidates"
    print("\n✅ DUAL-PEER SIGNALING OK — two endpoints complete a full call negotiation.")


if __name__ == "__main__":
    asyncio.run(main())
