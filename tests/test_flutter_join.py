"""
针对两个 P0 bug 的回归测试（模拟"Flutter 风格"客户端）：

Bug1：Flutter 客户端把 {type:'join', from, roomId} 作为**首条消息**发送，
      服务端需在此消息上同时完成注册 + 入房（而不是只在消息循环里处理 join）。
      断言：首条 join 后能依次收到 `registered` 与一条 `join` 响应且其
      data.members 包含自己；第二个客户端首条 join 同一房间后，第一个客户端
      能收到 `join` 广播。

Bug2：SDP 单包格式。Flutter 修复后发送 data = {type, sdp}（单包）。
      断言：offer 经服务端中继后，对端收到的 data.sdp 为字符串（非内层字典）。

独立启动修复后的信令服务器（子进程），测试结束关闭子进程。
"""
import asyncio
import json
import subprocess
import sys
import time

import websockets

SERVER_PORT = 8799
SERVER_URL = f"ws://localhost:{SERVER_PORT}"
ROOM = "R1"


class Client:
    """每个客户端一个独立 reader 协程，消息全部追加到 self.msgs（单读者，避免竞态）。"""

    def __init__(self, ws, msgs):
        self.ws = ws
        self.msgs = msgs
        self._task = asyncio.create_task(self._read())

    async def _read(self):
        try:
            async for raw in self.ws:
                self.msgs.append(json.loads(raw))
        except Exception:
            pass

    async def close(self):
        self._task.cancel()
        try:
            await self.ws.close()
        except Exception:
            pass

    def find(self, predicate):
        for m in self.msgs:
            if predicate(m):
                return m
        return None


async def connect_first_join(user_id):
    """模拟 Flutter 客户端：首条消息即 join（注册+入房合一）。"""
    ws = await websockets.connect(SERVER_URL)
    msgs = []
    c = Client(ws, msgs)
    await ws.send(json.dumps({"type": "join", "from": user_id, "roomId": ROOM}))
    return c


async def wait_for(c, predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        m = c.find(predicate)
        if m is not None:
            return m
        await asyncio.sleep(0.05)
    return None


async def main():
    failures = []

    # ── Bug1：flA 首条消息即 join，应既注册又入房 ──
    ca = await connect_first_join("flA")

    reg = await wait_for(ca, lambda m: m.get("type") == "registered", 5.0)
    if reg is None:
        failures.append("Bug1: flA 首条消息后未收到 registered")
    else:
        print("[OK] Bug1: flA 收到 registered")

    join_resp = await wait_for(
        ca, lambda m: m.get("type") == "join" and m.get("data", {}).get("members"), 5.0
    )
    if join_resp is None:
        failures.append("Bug1: flA 未收到 join 响应")
    elif "flA" not in join_resp["data"]["members"]:
        failures.append(f"Bug1: join 响应 members 不含自己: {join_resp['data']['members']}")
    else:
        print(f"[OK] Bug1: flA join 响应 members={join_resp['data']['members']}（已入房）")

    # ── Bug1：flB 首条 join 同一房间，flA 应收到 join 广播 ──
    cb = await connect_first_join("flB")
    bcast = await wait_for(ca, lambda m: m.get("type") == "join" and m.get("from") == "flB", 5.0)
    if bcast is None:
        failures.append("Bug1: flA 未收到 flB 加入房间的广播（房间成员未互通）")
    else:
        print("[OK] Bug1: flA 收到 flB 的 join 广播（房间成员互通）")

    # ── Bug2：单包 SDP 经中继，对端 data.sdp 应为字符串 ──
    offer = {"type": "offer", "from": "flA", "to": "flB", "roomId": ROOM,
             "data": {"type": "offer", "sdp": "v=0..."}}
    await ca.ws.send(json.dumps(offer))

    got_offer = await wait_for(cb, lambda m: m.get("type") == "offer", 5.0)
    if got_offer is None:
        failures.append("Bug2: flB 未收到 offer 中继")
    else:
        sdp_val = got_offer.get("data", {}).get("sdp")
        if not isinstance(sdp_val, str):
            failures.append(f"Bug2: flB 收到的 offer data.sdp 不是字符串（双包？）: {sdp_val!r}")
        else:
            print(f"[OK] Bug2: flB 收到 offer，data.sdp 为字符串: {sdp_val!r}")

    await ca.close()
    await cb.close()

    print()
    if failures:
        print("❌ 测试失败:")
        for f in failures:
            print("  -", f)
        return 1
    print("✅ 全部断言通过（Bug1 + Bug2 修复有效）")
    return 0


if __name__ == "__main__":
    proc = subprocess.Popen(
        [sys.executable, "server/signaling_server.py", "--port", str(SERVER_PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(1.5)  # 等待服务器就绪
        code = asyncio.run(main())
        sys.exit(code)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
