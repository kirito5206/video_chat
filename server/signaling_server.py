"""
P2P 视频通话 - WebSocket 信令服务器

技术栈：Python 3.11+ / asyncio / websockets
职责：
  1. 房间管理：创建、加入、离开、销毁
  2. 消息中继：SDP Offer/Answer、ICE Candidate 转发（不处理媒体流）
  3. 呼叫控制：call/accept/reject/hangup 消息路由
  4. 连接管理：心跳检测、异常断开清理

架构说明：
  ┌─────────┐    WebSocket    ┌──────────────┐    WebSocket    ┌─────────┐
  │ Client A│ ◄──────────────► │ Signaling    │ ◄──────────────► │ Client B│
  └─────────┘                  │ Server       │                  └─────────┘
                               │ (本文件)      │
                               └──────────────┘
  媒体流走 WebRTC P2P，本服务器仅转发信令消息。

启动方式：
  python server/signaling_server.py [--host 0.0.0.0] [--port 8765]
"""

import asyncio
import json
import logging
import socket
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

try:
    import websockets
except ImportError:
    print("请先安装依赖: pip install websockets")
    sys.exit(1)

# ─── 日志配置 ───────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("signaling")


# ─── 数据模型 ───────────────────────────────────────────────

@dataclass
class ConnectedClient:
    """已连接的客户端"""
    user_id: str
    websocket: any  # websockets.WebSocketServerProtocol
    room_id: Optional[str] = None
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class Room:
    """房间 - 最多支持 2 人 P2P"""
    room_id: str
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    members: dict[str, ConnectedClient] = field(default_factory=dict)


# ─── 服务器状态 ─────────────────────────────────────────────

# user_id → ConnectedClient
clients: dict[str, ConnectedClient] = {}

# room_id → Room
rooms: dict[str, Room] = {}

# 心跳间隔（秒）
HEARTBEAT_INTERVAL = 30
# 房间空闲超时（秒）- 超时自动清理
ROOM_IDLE_TIMEOUT = 3600


# ─── 工具函数 ───────────────────────────────────────────────

def _make_response(msg_type: str, from_id: str, to_id: Optional[str],
                   room_id: Optional[str], data=None) -> dict:
    """构造标准信令消息格式"""
    msg = {"type": msg_type, "from": from_id}
    if to_id:
        msg["to"] = to_id
    if room_id:
        msg["roomId"] = room_id
    if data is not None:
        msg["data"] = data
    return msg


async def _safe_send(client: ConnectedClient, message: dict):
    """安全发送消息（捕获连接已关闭等异常）

    注意：不能简单用 asyncio.create_task(ws.send(...)) 包裹——create_task
    只是调度协程，真实的网络异常会在 task 内部异步抛出，外层 try/except
    抓不到，最终变成 "Task exception was never retrieved" 刷屏。
    正确做法：直接 await 发送，捕获 ConnectionClosed 系列异常。
    """
    ws = client.websocket
    # 发送前先判断连接是否已关闭，避免竞态窗口
    if getattr(ws, "close_code", None) is not None:
        return
    try:
        await ws.send(json.dumps(message))
    except websockets.exceptions.ConnectionClosed:
        # 客户端在发送过程中断开，属正常情况，静默忽略
        pass
    except Exception as e:
        log.warning(f"发送消息给 {client.user_id} 失败: {e}")


async def broadcast_to_room(room: Room, message: dict, exclude_user: str = None):
    """向房间内所有人广播消息（可排除指定用户）"""
    for uid, client in list(room.members.items()):
        if uid != exclude_user:
            await _safe_send(client, message)


# ─── 消息处理器 ───────────────────────────────────────────

async def handle_join(client: ConnectedClient, msg: dict):
    """处理加入房间请求"""
    room_id = msg.get("roomId")
    if not room_id:
        await _send_error(client, "缺少 roomId")
        return

    # 如果已在其他房间，先离开
    if client.room_id and client.room_id != room_id:
        await _leave_room_internal(client)

    # 获取或创建房间
    if room_id not in rooms:
        rooms[room_id] = Room(room_id=room_id)
        log.info(f"新建房间: {room_id}")

    room = rooms[room_id]

    # 检查房间是否已满（P2P 最多 2 人）
    if len(room.members) >= 2 and client.user_id not in room.members:
        await _send_error(client, f"房间 {room_id} 已满（最多2人）")
        return

    # 加入房间
    client.room_id = room_id
    room.members[client.user_id] = client

    log.info(f"[{room_id}] {client.user_id} 加入 ({len(room.members)}/2)")

    # 通知房间内其他人
    notify_msg = _make_response("join", client.user_id, None, room_id)
    await broadcast_to_room(room, notify_msg, exclude_user=client.user_id)

    # 回复加入成功 + 当前成员列表
    response = _make_response("join", "server", client.user_id, room_id,
                              data={
                                  "members": list(room.members.keys()),
                                  "status": "ok",
                              })
    await _safe_send(client, response)


async def handle_leave(client: ConnectedClient):
    """处理离开房间"""
    await _leave_room_internal(client)


async def _leave_room_internal(client: ConnectedClient):
    """内部方法：将客户端从其当前房间移除"""
    if not client.room_id or client.room_id not in rooms:
        return

    room = rooms[client.room_id]
    room_id = client.room_id

    if client.user_id in room.members:
        del room.members[client.user_id]

    log.info(f"[{room_id}] {client.user_id} 离开 ({len(room.members)}/2)")

    # 通知房间内剩余的人
    notify_msg = _make_response("leave", client.user_id, None, room_id)
    await broadcast_to_room(room, notify_msg)

    # 清理空房间
    if len(room.members) == 0:
        del rooms[room_id]
        log.info(f"房间 {room_id} 已销毁")

    client.room_id = None


async def handle_relay(client: ConnectedClient, msg: dict):
    """
    中继 WebRTC 信令消息（offer/answer/candidate）
    
    核心原则：只做消息搬运工，不修改内容。
    根据目标字段决定投递方式：
      - 有 'to' 字段 → 点对点投递
      - 无 'to' 字段 → 向房间内其他人广播
    """
    target = msg.get("to")
    room_id = client.room_id

    if target and target in clients:
        # 点对点投递
        target_client = clients[target]
        relay_msg = {
            "type": msg["type"],
            "from": client.user_id,
            "to": target,
            "roomId": room_id,
            "data": msg.get("data"),
        }
        await _safe_send(target_client, relay_msg)
        log.debug(f"中继 [{msg['type']}] {client.user_id} → {target}")
    elif room_id and room_id in rooms:
        # 广播到房间内其他人
        room = rooms[room_id]
        relay_msg = {
            "type": msg["type"],
            "from": client.user_id,
            "roomId": room_id,
            "data": msg.get("data"),
        }
        await broadcast_to_room(room, relay_msg, exclude_user=client.user_id)
        log.debug(f"广播 [{msg['type']}] {client.user_id} → 房间 {room_id}")


async def handle_call_control(client: ConnectedClient, msg: dict):
    """
    处理呼叫控制消息（call/accept/reject/hangup）
    """
    msg_type = msg.get("type")
    target = msg.get("to") or msg.get("roomId")
    room_id = client.room_id

    control_msg = {
        "type": msg_type,
        "from": client.user_id,
        "to": target,
        "roomId": room_id,
    }

    if target and target in clients:
        # 发给指定用户
        await _safe_send(clients[target], control_msg)
        log.info(f"呼叫控制 [{msg_type}] {client.user_id} → {target}")
    elif room_id and room_id in rooms:
        # 广播到房间
        await broadcast_to_room(rooms[room_id], control_msg,
                                exclude_user=client.user_id)
        log.info(f"呼叫控制 [{msg_type}] {client.user_id} → 房间 {room_id}")


async def _send_error(client: ConnectedClient, error_msg: str):
    """发送错误响应"""
    error = _make_response("error", "server", client.user_id, client.room_id,
                           data={"message": error_msg})
    await _safe_send(client, error)


# ─── 主连接处理器 ──────────────────────────────────────────

async def handle_connection(websocket, path: str = ""):
    """处理单个 WebSocket 连接的完整生命周期"""

    # 第一步：等待注册消息（必须包含 userId）
    try:
        raw = await asyncio.wait_for(websocket.recv(), timeout=10.0)
        msg = json.loads(raw)

        user_id = msg.get("from") or msg.get("userId")
        if not user_id:
            await websocket.send(json.dumps({
                "type": "error",
                "message": "首条消息必须包含 userId",
            }))
            await websocket.close(4001, "Missing userId")
            return

        # 检查重复登录
        if user_id in clients:
            old = clients[user_id]
            log.warning(f"用户 {user_id} 重复连接，踢出旧连接")
            try:
                await old.websocket.close(4000, "Replaced by new connection")
            except Exception:
                pass

        # 注册新客户端
        client = ConnectedClient(user_id=user_id, websocket=websocket)
        clients[user_id] = client

        log.info(f"✓ {user_id} 已连接 | 总在线: {len(clients)}")

        # 确认注册成功
        await websocket.send(json.dumps({
            "type": "registered",
            "userId": user_id,
            "serverTime": datetime.now(timezone.utc).isoformat(),
        }))

        # 兼容 Flutter 客户端：首条消息即 {type:'join', from, roomId}（注册+入房合一）。
        # 此时 msg 仍在函数作用域内，不会进入下方 async for 消息循环，
        # 故在此直接处理 join，使 Flutter 无需修改即可正常进入房间。
        # Web 端首条消息为 {userId:...}、无 type=='join'，不受影响，仍由消息循环里的 join 分支处理。
        if msg.get("type") == "join":
            await handle_join(client, msg)

    except json.JSONDecodeError:
        await websocket.close(4002, "Invalid JSON")
        return
    except TimeoutError:
        await websocket.close(4003, "Registration timeout")
        return
    except Exception as e:
        log.error(f"注册阶段异常: {e}")
        return

    # 第二步：进入消息循环
    try:
        async for raw in websocket:
            try:
                msg = json.loads(raw)
                msg_type = msg.get("type", "")

                log.debug(f"[{user_id}] → {msg_type}")

                # 路由到对应的处理器
                match msg_type:
                    case "join":
                        await handle_join(client, msg)
                    case "leave":
                        await handle_leave(client)
                    case "offer" | "answer" | "candidate":
                        await handle_relay(client, msg)
                    case "call" | "accept" | "reject" | "hangup":
                        await handle_call_control(client, msg)
                    case "ping":
                        # 心跳响应
                        await _safe_send(client, {"type": "pong"})
                    case _:
                        log.warning(f"[{user_id}] 未知消息类型: {msg_type}")
                        await _send_error(client, f"未知消息类型: {msg_type}")

            except json.JSONDecodeError:
                await _send_error(client, "JSON 解析失败")
            except Exception as e:
                log.error(f"[{user_id}] 处理消息出错: {e}", exc_info=True)

    except websockets.exceptions.ConnectionClosed as e:
        log.info(f"✗ {user_id} 断开连接 (code={e.code})")
    except Exception as e:
        log.error(f"[{user_id}] 连接异常断开: {e}")
    finally:
        # 清理资源
        await _cleanup_client(client)


async def _cleanup_client(client: ConnectedClient):
    """清理断开的客户端资源"""
    # 离开房间
    await _leave_room_internal(client)

    # 从全局列表移除
    if client.user_id in clients:
        del clients[client.user_id]

    log.info(f"清理完成 {client.user_id} | 总在线: {len(clients)} | 活跃房间: {len(rooms)}")


# ─── 后台任务 ──────────────────────────────────────────────

async def heartbeat_task():
    """定期输出服务器状态日志"""
    while True:
        await asyncio.sleep(60)  # 每 60 秒输出一次
        log.debug(
            f"状态: 在线={len(clients)} 房间={len(rooms)} "
            f"| 房间详情: {[(rid, len(r.members)) for rid, r in rooms.items()]}"
        )


# ─── 局域网地址 ────────────────────────────────────────────

def _is_usable_lan_ip(ip: str) -> bool:
    """是否是可用于局域网访问的 IPv4 地址（排除回环与链路本地 169.254.x）。"""
    if not ip:
        return False
    if ip.startswith("127.") or ip.startswith("169.254."):
        return False
    return True


def _get_lan_ip() -> str:
    """获取本机用于访问局域网的出口 IP（即信令服务器对外的 LAN 地址）。

    使用 UDP 连接技巧：向一个公网地址 connect 一个 UDP socket（SOCK_DGRAM
    不会真正发包），内核据此选出默认路由对应的本地网卡地址——正是与外网/
    局域网通信的出口 IP，天然避开 Hyper-V / WSL 等虚拟网卡。

    此法为纯 socket、毫秒级完成，替代旧的 PowerShell 子进程方案
    （拉起 powershell.exe 需 3-5 秒，且依赖其存在性/输出编码，中文 Windows
    下解码异常会让服务器启动直接崩溃）。
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 连接外部地址以取得本地出口 IP（不会真正发包）
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        if _is_usable_lan_ip(ip):
            return ip
    except OSError:
        pass
    finally:
        s.close()

    # 兜底：从枚举到的所有网卡地址里取第一个可用的
    all_ips = _get_all_lan_ips()
    return all_ips[0] if all_ips else "127.0.0.1"


def _get_all_lan_ips() -> list[str]:
    """枚举本机所有可用于局域网访问的 IPv4 地址（默认出口 IP 排在最前）。

    用于启动横幅里列出全部候选地址：当默认出口网卡与手机不在同一网段时，
    用户可从候选里挑正确的地址手动填到手机端。
    """
    ips: list[str] = []

    # 1) 默认出口 IP 优先（UDP 连接技巧）
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        primary = s.getsockname()[0]
        if _is_usable_lan_ip(primary):
            ips.append(primary)
    except OSError:
        pass
    finally:
        s.close()

    # 2) 追加主机名解析出的其余地址（可能含以太网/其它物理网卡）
    #    过滤末位为 .1 的地址：这类几乎总是路由器 / Hyper-V / WSL 虚拟交换机的
    #    宿主地址，手机无法连到，列进候选只会误导用户。默认出口 IP（上面已加入）
    #    不受此过滤影响。
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not _is_usable_lan_ip(ip) or ip in ips:
                continue
            if ip.rsplit(".", 1)[-1] == "1":
                continue
            ips.append(ip)
    except OSError:
        pass

    return ips


# ─── 启动入口 ──────────────────────────────────────────────

async def main(host: str = "0.0.0.0", port: int = 8765):
    """启动信令服务器"""

    lan_ips = _get_all_lan_ips()
    primary_ip = lan_ips[0] if lan_ips else "127.0.0.1"

    log.info("=" * 50)
    log.info("  P2P 视频通话 - 信令服务器")
    log.info("=" * 50)
    log.info(f"  监听地址: ws://{host}:{port}")
    log.info(f"  手机端请复制此地址: ws://{primary_ip}:{port}")
    if len(lan_ips) > 1:
        log.info("  若上面地址手机连不上，可换用以下候选地址：")
        for ip in lan_ips[1:]:
            log.info(f"      ws://{ip}:{port}")
    log.info(f"  协议版本: v1.0 (WebRTC P2P)")
    log.info(f"  Python:   {sys.version.split()[0]}")
    log.info(f"  启动时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log.info("=" * 50)

    # 启动心跳任务
    asyncio.create_task(heartbeat_task())

    # 启动 WebSocket 服务
    async with websockets.serve(
        handle_connection,
        host,
        port,
        ping_interval=HEARTBEAT_INTERVAL,
        ping_timeout=10,
        max_size=1024 * 256,  # 256KB 单条消息上限
        max_queue=32,
    ):
        log.info(f"🚀 服务器已启动，监听 ws://{host}:{port}")
        log.info("按 Ctrl+C 停止服务\n")
        await asyncio.Future()  # 永久运行


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="P2P 视频通话信令服务器")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址 (默认: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8765, help="监听端口 (默认: 8765)")
    args = parser.parse_args()

    try:
        asyncio.run(main(args.host, args.port))
    except KeyboardInterrupt:
        log.info("\n服务器已停止")
