"""
验证 Web 客户端自动呼叫流程（顺序加入版，模拟真实操作：
先开一个标签页加入，再过一会开第二个标签页加入）。

同时打印每条消息的 类型/from/to，用于确认信令服务器路由正确。
"""
import asyncio
import json
import websockets

SERVER = "ws://localhost:8765"
ROOM = "verify_room_002"


async def client(role: str, uri: str, delay_before_join: float = 0):
    ws = await websockets.connect(uri)
    await ws.send(json.dumps({"userId": role}))
    await ws.recv()

    if delay_before_join:
        await asyncio.sleep(delay_before_join)

    await ws.send(json.dumps({"type": "join", "from": role, "roomId": ROOM}))
    sent_candidate = {"v": False}

    async def send_offer():
        await ws.send(json.dumps({"type": "call", "from": role, "roomId": ROOM}))
        await ws.send(json.dumps({
            "type": "offer", "from": role, "roomId": ROOM,
            "data": {"sdp": {"type": "offer", "sdp": "v=0..."}},
        }))

    async def send_answer():
        await ws.send(json.dumps({
            "type": "answer", "from": role, "roomId": ROOM,
            "data": {"sdp": {"type": "answer", "sdp": "v=0..."}},
        }))

    async def send_candidate():
        sent_candidate["v"] = True
        await ws.send(json.dumps({
            "type": "candidate", "from": role, "roomId": ROOM,
            "data": {"candidate": "candidate:...", "sdpMid": "0", "sdpMLineIndex": 0},
        }))

    got = []
    async for raw in ws:
        msg = json.loads(raw)
        t = msg["type"]
        got.append(t)
        print(f"  [{role}] <- {t:9s} from={msg.get('from')} to={msg.get('to')}")

        if t == "join" and msg.get("data", {}).get("members"):
            others = [m for m in msg["data"]["members"] if m != role]
            if others:
                remote = others[0]
                print(f"  [{role}] 后加入者，向 {remote} 发起呼叫")
                await asyncio.sleep(0.3)
                await send_offer()
        elif t == "offer":
            print(f"  [{role}] 收到 offer，回 answer + candidate")
            await asyncio.sleep(0.1)
            await send_answer()
            await send_candidate()
        elif t == "answer":
            print(f"  [{role}] 收到 answer，发 candidate")
            await send_candidate()
        elif t == "candidate":
            if sent_candidate["v"]:
                print(f"  [{role}] ICE 交换完成，关闭")
                await ws.close()
                return
    await ws.close()


async def main():
    print("=== 模拟：A 先加入，0.6s 后 B 加入（同房间）===\n")
    # 两个客户端并发运行，仅错开 join 时机，模拟真实先后开标签页
    await asyncio.gather(
        client("A", SERVER, delay_before_join=0.0),
        client("B", SERVER, delay_before_join=0.6),
    )
    print("\n✅ 验证结束（无异常即链路正常）")


if __name__ == "__main__":
    asyncio.run(main())
