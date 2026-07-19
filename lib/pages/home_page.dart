import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/call_viewmodel.dart';
import '../services/server_discovery_service.dart';
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

  /// 根据手机 Wi-Fi IP 扫描同一网段的固定端口 8765。
  bool _userEditedServer = false; // 用户手动改过地址则不自动覆盖
  String? _discoveredUrl;
  Timer? _scanTimeout; // 扫描超时提示定时器
  bool _scanning = false; // 是否正在扫描（显示"正在自动发现…"）
  String? _discoveryHint; // 扫描未找到时给用户的可视提示（避免无反应黑洞）
  final _discoveryService = ServerDiscoveryService();

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  /// 启动局域网发现；查到后立即补全地址并自动连接。
  Future<void> _startDiscovery() async {
    _startScanTimeout();
    await _discoveryService.start(_onServerFound);
  }

  /// 启动扫描超时：一开始显示"正在自动发现"，若 8 秒内未自动发现且用户未手动改地址，
  /// 给出温和提示（含手动地址与手机实际网段，便于排查），但后台扫描不停止。
  void _startScanTimeout() {
    _scanTimeout?.cancel();
    if (mounted) setState(() => _scanning = true);
    _scanTimeout = Timer(const Duration(seconds: 8), () {
      if (_discoveredUrl == null && !_userEditedServer && mounted) {
        setState(() {
          _scanning = false;
          _discoveryHint = '暂未在手机 Wi-Fi 网段发现服务器。请确认手机和电脑连接同一 Wi-Fi，'
              '且电脑防火墙已允许 TCP 8765。';
        });
      }
    });
  }

  /// 统一的"发现到服务器"处理：任一发现通道命中后调用。
  /// 查到立即填入地址、停止扫描超时提示、自动连接（幂等，只生效一次）。
  void _onServerFound(String ip, int port) {
    if (_userEditedServer || _discoveredUrl != null) return;
    final url = 'ws://$ip:$port';
    _scanTimeout?.cancel();
    _scanTimeout = null;
    if (!mounted) return;
    setState(() {
      _serverController.text = url;
      _discoveredUrl = url;
      _scanning = false;
      _discoveryHint = null;
    });
    unawaited(_discoveryService.stop());
    // 自动连接（仅在当前未连接时）
    final vm = context.read<CallViewModel>();
    if (vm.state != CallState.connected && vm.state != CallState.connecting) {
      _autoConnect(vm);
    }
  }

  /// 重新扫描：清空手动标记与已发现标记并重启发现服务。
  Future<void> _rescan() async {
    _scanTimeout?.cancel();
    await _discoveryService.stop();
    if (!mounted) return;
    setState(() {
      _userEditedServer = false;
      _discoveredUrl = null;
      _scanning = true;
      _discoveryHint = null;
      _serverController.text = 'ws://localhost:8765';
    });
    _startDiscovery();
  }

  Future<void> _autoConnect(CallViewModel vm) async {
    if (vm.state == CallState.connected || vm.state == CallState.connecting) {
      return;
    }
    setState(() => _isConnecting = true);
    try {
      await vm.connect(_serverController.text.trim());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自动连接失败，请手动连接: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  void dispose() {
    _scanTimeout?.cancel();
    unawaited(_discoveryService.stop());
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
                    onChanged: (_) {
                      // 用户手动修改地址后，后续发现信标不再覆盖
                      _userEditedServer = true;
                      unawaited(_discoveryService.stop());
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      hintText: 'ws://192.168.x.x:8765',
                      prefixIcon: const Icon(Icons.dns_rounded),
                      suffixText: vm.state == CallState.connected ? '已连接' : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (_discoveredUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.wifi_find_rounded,
                              size: 15, color: Colors.green),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '已自动发现服务器: $_discoveredUrl',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.green,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 正在扫描提示（打开 app 后短暂显示，避免"毫无反应"）
                  if (vm.state != CallState.connected && _scanning)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '正在自动发现局域网服务器…',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 扫描失败提示（含手动地址），不做成黑洞
                  if (vm.state != CallState.connected && _discoveryHint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                size: 16, color: Colors.orange),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _discoveryHint!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.orange,
                                ),
                              ),
                            ),
                          ],
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
                  // 重新扫描局域网（自动发现失效时手动触发）
                  if (vm.state != CallState.connected)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _isConnecting ? null : _rescan,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('重新扫描局域网'),
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
}
