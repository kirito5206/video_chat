import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../viewmodels/call_viewmodel.dart';
import 'call_page.dart';

/// 首页 - 服务器连接 + 房间入口
///
/// 两个核心功能：
/// 1. 配置信令服务器地址并连接
/// 2. 输入/生成房间号，进入通话页面
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _serverController = TextEditingController(
    text: 'ws://localhost:8765',
  );
  final _roomController = TextEditingController();

  bool _isConnecting = false;

  /// 分享给手机端的服务器地址（连接成功后解析出局域网 IP 填充）
  String? _lanAddress;

  @override
  void dispose() {
    _serverController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Consumer<CallViewModel>(
              builder: (context, vm, _) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ─── Logo 区域 ────────────────────
                  Icon(
                    Icons.video_call_rounded,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'P2P 视频通话',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Flutter + WebRTC 点对点加密通信',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 40),

                  // ─── 服务器配置 ──────────────────
                  _buildSectionTitle('信令服务器'),
                  TextField(
                    controller: _serverController,
                    enabled: vm.state == CallState.idle ||
                        vm.state == CallState.connected,
                    decoration: InputDecoration(
                      hintText: 'ws://192.168.x.x:8765',
                      prefixIcon: const Icon(Icons.dns_rounded),
                      suffixText: vm.state == CallState.connected ? '已连接' : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '默认连接本机服务器 ws://localhost:8765；'
                        '跨设备通话时请改为电脑局域网地址',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_isConnecting || vm.state == CallState.connecting)
                          ? null
                          : (vm.state == CallState.connected
                              ? () => _handleDisconnect(vm)
                              : () => _handleConnect(vm)),
                      icon: _isConnecting || vm.state == CallState.connecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              vm.state == CallState.connected
                                  ? Icons.link_off_rounded
                                  : Icons.link_rounded,
                            ),
                      label: Text(
                        vm.state == CallState.connected ? '断开' : '连接服务器',
                      ),
                    ),
                  ),
                  if (vm.statusMessage != null &&
                      (vm.state == CallState.connected ||
                          vm.state == CallState.connecting)) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: vm.state == CallState.connected
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            vm.state == CallState.connected
                                ? Icons.check_circle_rounded
                                : Icons.info_outline,
                            size: 16,
                            color: vm.state == CallState.connected
                                ? Colors.green
                                : Colors.orange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(vm.statusMessage ?? '')),
                        ],
                      ),
                    ),
                  ],

                  // ─── 分享给手机端（连接成功后显示）────────
                  if (vm.state == CallState.connected && _lanAddress != null) ...[
                    const SizedBox(height: 16),
                    _buildShareCard(),
                  ],

                  const SizedBox(height: 28),

                  // ─── 房间操作 ────────────────────
                  _buildSectionTitle('房间'),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _roomController,
                          enabled: vm.state == CallState.connected,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            hintText: '输入或生成房间号',
                            prefixIcon: Icon(Icons.meeting_room_rounded),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: vm.state == CallState.connected
                              ? () => setState(() =>
                                  _roomController.text = _generateRoomId())
                              : null,
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text('生成'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 进入房间按钮（仅在已连接+房间号非空时可点）
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _canJoinRoom(vm)
                          ? () => _enterRoom(vm)
                          : null,
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('进入房间'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),

                  // 禁用原因提示（帮助用户排查）
                  if (!_canJoinRoom(vm) && vm.state != CallState.idle)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _joinDisabledReason(vm),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),

                  const SizedBox(height: 24),

                  // ─── 技术信息卡片 ────────────────
                  _buildInfoCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 判断是否可以进入房间
  bool _canJoinRoom(CallViewModel vm) {
    if (vm.state != CallState.connected) return false;
    return _roomController.text.trim().isNotEmpty;
  }

  /// 返回按钮禁用的原因（用于提示用户）
  String _joinDisabledReason(CallViewModel vm) {
    if (vm.state != CallState.connected) {
      return '请先连接信令服务器';
    }
    if (_roomController.text.trim().isEmpty) {
      return '请输入或生成房间号';
    }
    return '';
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text('技术架构',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    )),
              ],
            ),
            const SizedBox(height: 10),
            _buildTechRow('客户端', 'Flutter + flutter_webrtc'),
            _buildTechRow('传输', 'WebRTC P2P（SRTP 加密）'),
            _buildTechRow('信令', 'WebSocket（Python asyncio）'),
            _buildTechRow('NAT 穿透', 'STUN / TURN'),
            const SizedBox(height: 4),
            Text(
              '媒体流不经过服务器，端对端直连',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTechRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                )),
          ),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Future<void> _handleConnect(CallViewModel vm) async {
    final url = _serverController.text.trim();
    if (url.isEmpty) return;

    setState(() => _isConnecting = true);
    try {
      await vm.connect(url);
      // 连接成功后解析出可分享给手机端的局域网地址
      await _refreshShareableAddress();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败: $e')),
        );
      }
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _handleDisconnect(CallViewModel vm) async {
    setState(() => _isConnecting = true);
    try {
      await vm.disconnect();
      // 断开后清除分享地址
      if (mounted) setState(() => _lanAddress = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('断开失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _enterRoom(CallViewModel vm) {
    final roomId = _roomController.text.trim();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CallPage()),
    );

    // 延迟执行，等页面加载完再初始化 WebRTC
    Future.microtask(() => vm.joinOrCreateRoom(roomId));
  }

  String _generateRoomId() {
    final now = DateTime.now();
    return '${now.year}${now.month.toString().padLeft(2, '0')}'
           '${now.day.toString().padLeft(2, '0')}-'
           '${now.millisecondsSinceEpoch.toString().substring(6)}';
  }

  /// 连接成功后，解析出可分享给手机端的局域网地址
  Future<void> _refreshShareableAddress() async {
    final url = _serverController.text.trim();
    final addr = await _resolveShareableAddress(url);
    if (mounted) setState(() => _lanAddress = addr);
  }

  /// 根据已连接的服务器地址，生成可分享给手机端的 ws:// 地址。
  /// 若连接的是 localhost/127.0.0.1，则替换为本机局域网 IP。
  Future<String?> _resolveShareableAddress(String connectedUrl) async {
    Uri? uri;
    try {
      uri = Uri.parse(connectedUrl);
    } catch (_) {
      return null;
    }
    final host = uri.host;
    final port = uri.port;

    // 已经是一个具体的非回环地址（比如用户手动填了局域网 IP），直接复用
    if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
      final ip = InternetAddress.tryParse(host);
      if (ip != null && !ip.isLoopback) return connectedUrl;
    }

    // 否则解析本机局域网 IP（信令服务器通常就在这台电脑上）
    final lanIp = await _getLocalLanIp();
    if (lanIp == null) return null;
    return 'ws://$lanIp:$port';
  }

  /// 获取本机用于局域网通信的 IPv4 地址。
  /// 优先用 UDP 连接技巧取出口网卡 IP，失败则枚举网卡兜底。
  Future<String?> _getLocalLanIp() async {
    // 1) UDP 连接技巧：内核据此选出默认路由对应的本地地址（与服务器同款逻辑）
    try {
      final sock = await RawSocket.connect(
        InternetAddress('8.8.8.8'),
        80,
        timeout: const Duration(milliseconds: 800),
      );
      final ip = sock.address.address;
      sock.close();
      if (_isLanIp(ip)) return ip;
    } catch (_) {
      // 忽略，进入兜底
    }

    // 2) 兜底：枚举物理网卡，取第一个私有网段地址
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (_isLanIp(a.address)) return a.address;
        }
      }
    } catch (_) {
      // 忽略
    }
    return null;
  }

  /// 判断是否为私有/局域网 IPv4 地址（10./192.168./172.16~31.）
  bool _isLanIp(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('172.')) {
      final second = int.tryParse(ip.split('.').elementAtOrNull(1) ?? '');
      if (second != null && second >= 16 && second <= 31) return true;
    }
    return false;
  }

  /// 复制分享地址到剪贴板，并提示用户
  Future<void> _copyAddress() async {
    if (_lanAddress == null) return;
    await Clipboard.setData(ClipboardData(text: _lanAddress!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制: $_lanAddress')),
      );
    }
  }

  /// 分享给手机端的地址卡片（含复制按钮）
  Widget _buildShareCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.share_location_rounded, size: 18,
                  color: colorScheme.primary),
              const SizedBox(width: 8),
              Text('分享给手机端',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      )),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '把这个地址发给手机，在手机端粘贴即可连接同一台服务器：',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.outline,
                ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: SelectableText(
                    _lanAddress!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _copyAddress,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('复制'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
