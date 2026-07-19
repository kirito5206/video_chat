// 无头双端 WebRTC 连通测试（复刻 video_chat 原生 app 协议）
// 两个真实 RTCPeerConnection 通过【真实在跑的信令服务器】进同一房间，
// 验证：register 不超时 / join 互相发现 / offer-answer-candidate 房间广播可达 / ICE 真正连通。
const WebSocket = require('ws');
const { RTCPeerConnection } = require('node-datachannel');

const SIGNAL = 'ws://127.0.0.1:8765';
const ROOM = 'VT' + Math.floor(Math.random() * 1e6).toString().padStart(6, '0');
const LOG = [];
const t0 = Date.now();
const ts = () => ((Date.now() - t0) / 1000).toFixed(2) + 's';
function log(...a) { const s = `[${ts()}] ${a.join(' ')}`; LOG.push(s); console.log(s); }

function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

class Peer {
  constructor(uid) {
    this.uid = uid;
    this.ws = null;
    this.pc = null;
    this.remoteUid = null;
    this.registered = false;
    this.joinEchoMembers = null;   // 自己 join 回执里的 members
    this.peerJoinSeen = false;     // 收到对方 join 广播
    this.offerSeen = false;
    this.answerSeen = false;
    this.candCount = 0;
    this.iceConnected = false;
    this.dcOpen = false;
    this.remoteSet = false;
    this.candQueue = [];
    this._waiters = {};
  }
  _fire(name) { const w = this._waiters[name]; if (w) { delete this._waiters[name]; w(); } }
  waitFor(name, ms = 25000) {
    return new Promise((res, rej) => {
      if (this['_done_' + name]) return res();
      const t = setTimeout(() => rej(new Error('timeout:' + name)), ms);
      this._waiters[name] = () => { clearTimeout(t); res(); };
    });
  }
  send(type, data) {
    const msg = { type, from: this.uid, to: ROOM, roomId: ROOM, data };
    this.ws.send(JSON.stringify(msg));
    log(`[${this.uid}] SENT ${type}`);
  }
  async connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(SIGNAL);
      this.ws.on('open', () => {
        // 关键：首条消息必须是 register（复刻 app 修复，避免 10s 注册超时断连）
        this.ws.send(JSON.stringify({ type: 'register', from: this.uid }));
        log(`[${this.uid}] SENT register (首条消息)`);
      });
      this.ws.on('message', (raw) => this._onMsg(raw));
      this.ws.on('error', (e) => { log(`[${this.uid}] WS error ${e.message}`); });
      this.waitFor('registered').then(resolve).catch(reject);
    });
  }
  join() {
    this.ws.send(JSON.stringify({ type: 'join', from: this.uid, roomId: ROOM }));
    log(`[${this.uid}] SENT join room=${ROOM}`);
  }
  _onMsg(raw) {
    let m; try { m = JSON.parse(raw); } catch { return; }
    const type = m.type;
    if (type === 'registered') {
      this.registered = true; log(`[${this.uid}] RECV registered ✔`); this._fire('registered'); return;
    }
    if (type === 'join') {
      if (m.from === 'server') {
        this.joinEchoMembers = (m.data && m.data.members) || [];
        log(`[${this.uid}] RECV join回执 members=${JSON.stringify(this.joinEchoMembers)}`);
        for (const mem of this.joinEchoMembers) {
          if (mem !== this.uid && mem !== 'server') this.remoteUid = mem;
        }
        this._done_joinEcho = true; this._fire('joinEcho');
      } else {
        this.peerJoinSeen = true; this.remoteUid = m.from;
        log(`[${this.uid}] RECV 对方join广播 from=${m.from} ✔`);
        this._done_peerJoin = true; this._fire('peerJoin');
      }
      return;
    }
    if (type === 'offer') {
      this.offerSeen = true; log(`[${this.uid}] RECV offer from=${m.from} ✔`);
      this._handleOffer(m.data); return;
    }
    if (type === 'answer') {
      this.answerSeen = true; log(`[${this.uid}] RECV answer from=${m.from} ✔`);
      this._setRemote(m.data).then(() => this._flushCand());
      this._done_answer = true; this._fire('answer'); return;
    }
    if (type === 'candidate') {
      this.candCount++;
      log(`[${this.uid}] RECV candidate #${this.candCount} from=${m.from}`);
      this._addCand(m.data);
      return;
    }
  }
  _newPc() {
    this.pc = new RTCPeerConnection({ iceServers: [] });
    this.pc.onIceCandidate = (cand) => {
      if (cand && cand.candidate) this.send('candidate', { candidate: cand.candidate, sdpMid: cand.mid });
    };
    this.pc.onIceStateChange = (state) => {
      log(`[${this.uid}] ICE state=${state}`);
      if (state === 'connected' || state === 'completed') { this.iceConnected = true; this._done_connected = true; this._fire('connected'); }
    };
  }
  async setupInitiator() {
    this._newPc();
    this.dc = this.pc.createDataChannel('chat');
    this.dc.onOpen = () => { this.dcOpen = true; this._done_connected = true; this._fire('connected'); log(`[${this.uid}] DataChannel OPEN ✔`); };
    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    this.send('offer', offer);
    log(`[${this.uid}] 创建并发送 OFFER (initiator)`);
  }
  async _handleOffer(offer) {
    this._newPc();
    this.pc.onDataChannel = (dc) => {
      this.dc = dc;
      dc.onOpen = () => { this.dcOpen = true; this._done_connected = true; this._fire('connected'); log(`[${this.uid}] DataChannel OPEN ✔`); };
    };
    await this._setRemote(offer);
    this._flushCand();
    const answer = await this.pc.createAnswer();
    await this.pc.setLocalDescription(answer);
    this.send('answer', answer);
    log(`[${this.uid}] 创建并发送 ANSWER (responder)`);
  }
  async _setRemote(desc) { await this.pc.setRemoteDescription(desc); this.remoteSet = true; }
  _flushCand() {
    while (this.candQueue.length) {
      const c = this.candQueue.shift();
      try { this.pc.addIceCandidate({ candidate: c.candidate, mid: c.sdpMid }); } catch (e) { log(`[${this.uid}] addIce err ${e.message}`); }
    }
  }
  _addCand(c) {
    if (this.pc && this.remoteSet) {
      try { this.pc.addIceCandidate({ candidate: c.candidate, mid: c.sdpMid }); } catch (e) { log(`[${this.uid}] addIce err ${e.message}`); }
    } else {
      this.candQueue.push(c);
    }
  }
}

(async () => {
  log(`==== 无头双端测试 房间=${ROOM} 信令=${SIGNAL} ====`);
  const a = new Peer('AAA_' + Date.now());
  const b = new Peer('BBB_' + Date.now());
  const initiator = (a.uid < b.uid) ? a : b;
  const responder = (initiator === a) ? b : a;
  log(`initiator=${(initiator === a) ? 'A' : 'B'} responder=${(responder === a) ? 'A' : 'B'}`);

  let fail = null;
  try {
    await Promise.all([a.connect(), b.connect()]);           // register + registered
    a.join(); b.join();
    await Promise.all([a.waitFor('joinEcho'), b.waitFor('joinEcho')]);  // members 回执
    await Promise.all([a.waitFor('peerJoin'), b.waitFor('peerJoin')]);  // 互相看到 join 广播
    log(`>>> 双向发现成功: A.remote=${a.remoteUid} B.remote=${b.remoteUid}`);

    await initiator.setupInitiator();                         // 发 offer
    // responder 在收到 offer 时自动应答；此处等两端连通
    await Promise.all([a.waitFor('connected'), b.waitFor('connected')]);
    log(`>>> ICE 连通 + DataChannel 打开：A.ice=${a.iceConnected}/dc=${a.dcOpen}  B.ice=${b.iceConnected}/dc=${b.dcOpen}`);
  } catch (e) {
    fail = e.message || String(e);
    log(`!!! 失败: ${fail}`);
  }

  // 汇总判定
  const checks = {
    'A 注册成功': a.registered,
    'B 注册成功': b.registered,
    'A 收到 members 含双方': !!a.joinEchoMembers && a.joinEchoMembers.length >= 2,
    'B 收到 members 含双方': !!b.joinEchoMembers && b.joinEchoMembers.length >= 2,
    'A 看到对方 join 广播': a.peerJoinSeen,
    'B 看到对方 join 广播': b.peerJoinSeen,
    '发起方发出 OFFER 并被收到': initiator.offerSeen || responder.offerSeen,
    '接收方回 ANSWER 并被收到': initiator.answerSeen || responder.answerSeen,
    '双向 CANDIDATE 交换(A/B 各>0)': a.candCount > 0 && b.candCount > 0,
    'ICE 真正连通(A&B)': a.iceConnected && b.iceConnected,
    'DataChannel 打开(A&B)': a.dcOpen && b.dcOpen,
  };
  log('==== 判定 ====');
  let allPass = true;
  for (const [k, v] of Object.entries(checks)) { log(`${v ? 'PASS' : 'FAIL'} ${k}`); if (!v) allPass = false; }
  log(allPass ? '==== RESULT: PASS ✅ 双端通过真实信令服务器完成 WebRTC 连通 ====' : '==== RESULT: FAIL ❌ 见上 ====');
  try { a.ws && a.ws.close(); b.ws && b.ws.close(); } catch {}
  process.exit(allPass ? 0 : 1);
})();
