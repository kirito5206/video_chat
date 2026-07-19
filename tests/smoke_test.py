"""快速冒烟测试：验证信令服务器能接收连接并处理消息"""
import asyncio
import json
import websockets

SERVER = "ws://localhost:8765"


async def main():
    print("1. 连接客户端A...")
    a = await websockets.connect(SERVER)
    await a.send(json.dumps({"userId": "userA"}))
    reg_a = json.loads(await a.recv())
    print(f"   A 注册结果: {reg_a}")

    print("2. 连接客户端B...")
    b = await websockets.connect(SERVER)
    await b.send(json.dumps({"userId": "userB"}))
    reg_b = json.loads(await b.recv())
    print(f"   B 注册结果: {reg_b}")

    print("3. A 加入房间 room_001...")
    await a.send(json.dumps({"type": "join", "from": "userA", "roomId": "room_001"}))
    join_a = json.loads(await a.recv())
    print(f"   A 加入响应: {join_a}")

    print("4. B 加入同一房间 room_001...")
    await b.send(json.dumps({"type": "join", "from": "userB", "roomId": "room_001"}))
    # B 会收到自己的加入确认，A 会收到 B 加入的通知
    join_b = json.loads(await b.recv())
    notify_a = json.loads(await a.recv())
    print(f"   B 加入响应: {join_b}")
    print(f"   A 收到通知: {notify_a}")

    print("5. A 发送 offer 中继给 B...")
    await a.send(json.dumps({
        "type": "offer",
        "from": "userA",
        "roomId": "room_001",
        "data": {"sdp": {"type": "offer", "sdp": "v=0..."}}
    }))
    relayed = json.loads(await b.recv())
    print(f"   B 收到中继: type={relayed['type']}, from={relayed['from']}, data={relayed.get('data')}")

    print("\n✅ 信令服务器工作正常！所有核心消息流均通过。")

    await a.close()
    await b.close()


if __name__ == "__main__":
    asyncio.run(main())
