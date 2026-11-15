import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'client_background_service.dart';
import 'client_launch_policy.dart';
import 'device_identity.dart';
import 'direct_chat.dart';
import 'server_tls.dart';
import 'secure_cache.dart';

const _uuid = Uuid();

Future<String> _readDeviceName() async {
  try {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      final model = info.model.trim();
      final manufacturer = info.manufacturer.trim();
      if (model.isNotEmpty &&
          !model.toLowerCase().contains(manufacturer.toLowerCase())) {
        return '$manufacturer $model'.trim();
      }
      if (model.isNotEmpty) return model;
    } else if (Platform.isIOS) {
      final name = (await deviceInfo.iosInfo).name.trim();
      if (name.isNotEmpty) return name;
    }
  } catch (error, stackTrace) {
    AppLogger.log(
      'client.device_name_read_failed',
      level: 'error',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return Platform.isIOS ? 'iPhone' : 'Android device';
}

class InviteGateApp extends StatefulWidget {
  const InviteGateApp({
    required this.serverUri,
    required this.cache,
    this.startupBlockReason,
    super.key,
  });

  final Uri serverUri;
  final SecureCache cache;
  final String? startupBlockReason;

  @override
  State<InviteGateApp> createState() => _InviteGateAppState();
}

class _InviteGateAppState extends State<InviteGateApp>
    with WidgetsBindingObserver {
  final _inviteCode = TextEditingController();
  String _deviceName = '';
  Timer? _timer;
  String? _code;
  String? _error;
  String? _clientId;
  String? _connectedClientName;
  String? _connectedDeviceName;
  DirectChatApi? _chatApi;
  bool _busy = false;
  bool _checking = false;
  bool _restoring = false;
  String? _blockedMessage;

  @override
  void initState() {
    super.initState();
    _blockedMessage = widget.startupBlockReason ??
        (widget.cache.text(clientBlacklistCacheKey) == 'true'
            ? '此设备已被拉黑，应用已锁定。'
            : null);
    if (_blockedMessage != null) return;
    unawaited(widget.cache.putText('direct-client-identity-number', ''));
    unawaited(_loadDeviceName());
    WidgetsBinding.instance.addObserver(this);
    final savedCode = widget.cache.text('direct-invite-code');
    final savedClientId = widget.cache.text('direct-client-id');
    if (savedCode != null &&
        savedCode.isNotEmpty &&
        savedClientId != null &&
        savedClientId.isNotEmpty) {
      _inviteCode.text = savedCode;
      _restoring = true;
      unawaited(_restoreSession(savedCode, savedClientId));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _chatApi?.close();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _loadDeviceName() async {
    final deviceName = await _readDeviceName();
    try {
      await widget.cache.putText('direct-client-device-name', deviceName);
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.device_name_cache_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (mounted) setState(() => _deviceName = deviceName);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogger.log('app.lifecycle', details: {'state': state.name});
    setClientAppForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed && _clientId != null) {
      unawaited(_revalidate());
    }
  }

  Future<void> _restoreSession(
    String code,
    String clientId,
  ) async {
    AppLogger.log('client.session_restore_started');
    try {
      final deviceIdentity = await persistentDeviceIdentity(widget.cache);
      if (!mounted) return;
      await ensureServerCertificatePinned(
        context,
        widget.serverUri,
        widget.cache,
        confirmOnFirstUse: false,
      );
      final deviceName = await _readDeviceName();
      final clientName = widget.cache.text('direct-client-name') ?? deviceName;
      final api = _createApi(code);
      late final Map<String, dynamic> response;
      try {
        response = await api.validate(
          code: code,
          clientId: clientId,
          clientName: clientName,
          deviceName: deviceName,
          deviceIdentity: deviceIdentity,
          token: widget.cache.text('direct-token:$clientId') ?? '',
        );
      } finally {
        api.close();
      }
      if (response['valid'] != true) {
        await _lock(
          _invalidInviteMessage(response['error']),
          permanent: true,
        );
        return;
      }
      final token = response['token'];
      if (token is! String || token.isEmpty) {
        throw const FormatException('Server did not return a client token.');
      }
      final resolvedClientId = response['client_id'] as String? ?? clientId;
      await widget.cache.putText('direct-client-id', resolvedClientId);
      await widget.cache.putText('direct-token:$resolvedClientId', token);
      await _startBackgroundService(code, resolvedClientId, token);
      if (!mounted) return;
      setState(() {
        _code = code;
        _clientId = resolvedClientId;
        _connectedClientName = clientName;
        _connectedDeviceName = deviceName;
        _error = null;
      });
      AppLogger.log('client.session_restored');
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_revalidate()),
      );
    } on DirectChatValidationRejectedException catch (error) {
      await _lock(
        '服务器拒绝了邀请码验证（HTTP ${error.statusCode}），设备已被拉黑，应用已锁定。',
        permanent: true,
      );
    } catch (error) {
      AppLogger.log(
        'client.session_restore_failed',
        level: 'error',
        error: error,
      );
      AppLogger.log(
        'client.server_connection_failed',
        level: 'error',
        error: error,
      );
      if (mounted) {
        setState(() => _error = serverConnectionErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _submit() async {
    final code = _inviteCode.text.trim();
    if (code.isEmpty || _busy || _blockedMessage != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    AppLogger.log('client.invite_submit_started');
    try {
      final deviceName =
          _deviceName.isEmpty ? await _readDeviceName() : _deviceName;
      final clientName = widget.cache.text('direct-client-name') ?? deviceName;
      if (!mounted) return;
      await ensureServerCertificatePinned(
        context,
        widget.serverUri,
        widget.cache,
        confirmOnFirstUse: false,
      );
      await widget.cache.putText('direct-client-name', clientName);
      await widget.cache.putText('direct-client-device-name', deviceName);
      final deviceIdentity = await persistentDeviceIdentity(widget.cache);
      final clientId = widget.cache.text('direct-client-id') ?? _uuid.v4();
      await widget.cache.putText('direct-client-id', clientId);
      final api = _createApi(code);
      late final Map<String, dynamic> response;
      try {
        response = await api.validate(
          code: code,
          clientId: clientId,
          clientName: clientName,
          deviceName: deviceName,
          deviceIdentity: deviceIdentity,
          token: widget.cache.text('direct-token:$clientId') ?? '',
        );
      } finally {
        api.close();
      }
      if (response['valid'] != true) {
        await _lock(
          _invalidInviteMessage(response['error']),
          permanent: true,
        );
        return;
      }
      final token = response['token'];
      if (token is! String || token.isEmpty) {
        throw const FormatException('Server did not return a client token.');
      }
      final resolvedClientId = response['client_id'] as String? ?? clientId;
      await widget.cache.putText('direct-client-id', resolvedClientId);
      await widget.cache.putText('direct-token:$resolvedClientId', token);
      await widget.cache.putText('direct-invite-code', code);
      await _startBackgroundService(code, resolvedClientId, token);
      _inviteCode.clear();
      if (!mounted) return;
      setState(() {
        _code = code;
        _clientId = resolvedClientId;
        _connectedClientName = clientName;
        _connectedDeviceName = deviceName;
        _error = null;
      });
      AppLogger.log('client.authorized');
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_revalidate()),
      );
    } on DirectChatValidationRejectedException catch (error) {
      await _lock(
        '服务器拒绝了邀请码验证（HTTP ${error.statusCode}），设备已被拉黑，应用已锁定。',
        permanent: true,
      );
    } catch (error) {
      AppLogger.log(
        'client.invite_submit_failed',
        level: 'error',
        error: error,
      );
      final connectionError = serverConnectionErrorMessage(error);
      if (mounted) {
        setState(() => _error = connectionError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revalidate() async {
    if (_checking || _clientId == null || _code == null) return;
    _checking = true;
    AppLogger.log('client.authorization_check_started');
    try {
      final api = DirectChatApi(
        widget.serverUri,
        messageCode: _code!,
        certificateFingerprint: _certificateFingerprint,
      );
      late final Map<String, dynamic> response;
      try {
        response = await api.validate(
          code: _code!,
          clientId: _clientId!,
          clientName: widget.cache.text('direct-client-name') ??
              _connectedClientName ??
              'Client phone',
          deviceName: _connectedDeviceName ?? 'Client phone',
          deviceIdentity: await persistentDeviceIdentity(widget.cache),
          token: widget.cache.text('direct-token:$_clientId') ?? '',
        );
      } finally {
        api.close();
      }
      if (response['valid'] != true) {
        await _lock(
          '邀请码已失效或客户端授权已撤销，设备已被拉黑，应用已锁定。',
          permanent: true,
        );
        return;
      }
      final clientName =
          widget.cache.text('direct-client-name') ?? _connectedClientName;
      if (clientName != null) {
        _connectedClientName = clientName;
      }
      final token = response['token'];
      if (token is! String || token.isEmpty) {
        throw const FormatException('Server did not return a client token.');
      }
      await widget.cache.putText('direct-token:$_clientId', token);
    } on DirectChatValidationRejectedException catch (error) {
      await _lock(
        '服务器拒绝了客户端授权验证（HTTP ${error.statusCode}），设备已被拉黑，应用已锁定。',
        permanent: true,
      );
    } catch (error) {
      AppLogger.log(
        'client.authorization_check_failed',
        level: 'error',
        error: error,
      );
      await _lock(serverConnectionErrorMessage(error));
    } finally {
      _checking = false;
    }
  }

  Future<void> _startBackgroundService(
    String code,
    String clientId,
    String token,
  ) async {
    try {
      await startClientBackgroundService(
        clientId: clientId,
        inviteCode: code,
        token: token,
        certificateFingerprint: _certificateFingerprint,
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.background_service_start_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _lock(String reason, {bool permanent = false}) async {
    AppLogger.log('client.session_locked', details: {'reason': reason});
    var displayedReason = reason;
    if (permanent) {
      try {
        await widget.cache.putText(clientBlacklistCacheKey, 'true');
        await markClientBackgroundServiceBlocked();
      } catch (error, stackTrace) {
        AppLogger.log(
          'client.blacklist_cache_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
        displayedReason = '$reason 本机锁定状态保存失败。';
      }
      try {
        await widget.cache.purgeClientChatData(
          widget.cache.text('direct-client-id') ?? '',
        );
      } catch (error, stackTrace) {
        AppLogger.log(
          'client.chat_data_purge_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
        displayedReason = '$displayedReason 本地聊天记录清理未能完成。';
      }
      try {
        await clearServerCertificatePin(widget.serverUri, widget.cache);
      } catch (error, stackTrace) {
        AppLogger.log(
          'client.server_pin_clear_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
        displayedReason = '$displayedReason 本地服务器记录清理未能完成。';
      }
    }
    _timer?.cancel();
    _chatApi?.close();
    _chatApi = null;
    try {
      await stopClientBackgroundService();
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.background_service_stop_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      displayedReason = '$displayedReason 后台连接停止失败，请立即关闭应用。';
    }
    if (permanent) {
      try {
        await AppLogger.clearClientLogs();
      } catch (error, stackTrace) {
        AppLogger.log(
          'client.local_log_purge_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
        displayedReason = '$displayedReason 本地客户端日志清理未能完成。';
      }
    }
    if (!mounted) return;
    setState(() {
      _clientId = null;
      _connectedClientName = null;
      _connectedDeviceName = null;
      _code = null;
      _inviteCode.clear();
      _error = displayedReason;
      if (permanent) {
        _blockedMessage = displayedReason;
      }
    });
    try {
      await widget.cache.putText('direct-invite-code', '');
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.invite_code_cache_clear_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _error = '本地邀请码清理失败：$error');
      }
    }
  }

  String _invalidInviteMessage(Object? error) => switch (error) {
        'invite_already_assigned' => '此邀请码已绑定其他设备，设备已被拉黑，应用已锁定。',
        _ => '邀请码错误或已失效，设备已被拉黑，应用已锁定。',
      };

  @override
  Widget build(BuildContext context) {
    final blockedMessage = _blockedMessage;
    if (blockedMessage != null) {
      return MaterialApp(
        title: 'Consent Chat',
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                blockedMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ),
      );
    }
    final clientId = _clientId;
    final clientName = _connectedClientName;
    final token =
        clientId == null ? null : widget.cache.text('direct-token:$clientId');
    if (clientId != null && clientName != null && token != null) {
      return DirectChatClientApp(
        api: _chatApi ??= _createApi(_code!),
        clientId: clientId,
        clientName: clientName,
        deviceName: _connectedDeviceName ?? '我的手机',
        inviteCode: _code!,
        cache: widget.cache,
      );
    }
    if (_restoring) {
      return const MaterialApp(
        title: 'Consent Chat',
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return MaterialApp(
      title: 'Consent Chat',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Text(
                  '输入邀请码',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _inviteCode,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: '验证码'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? '正在验证…' : '验证并继续'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _certificateFingerprint =>
      widget.cache.text(serverCertificatePinCacheKey(widget.serverUri)) ??
      (throw StateError('服务器证书尚未验证。'));

  DirectChatApi _createApi(String code) => DirectChatApi(
        widget.serverUri,
        messageCode: code,
        certificateFingerprint: _certificateFingerprint,
      );
}

class ClientServerAddressScreen extends StatefulWidget {
  const ClientServerAddressScreen({
    required this.cache,
    required this.onConnect,
    super.key,
  });

  final SecureCache cache;
  final ValueChanged<Uri> onConnect;

  @override
  State<ClientServerAddressScreen> createState() =>
      _ClientServerAddressScreenState();
}

class _ClientServerAddressScreenState extends State<ClientServerAddressScreen> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final TextEditingController _address;
  String? _error;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(
      text: widget.cache.text('direct-server-address') ?? '',
    );
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final input = _address.text.trim();
    if (input.isEmpty) {
      setState(() => _error = '请输入服务器地址。');
      return;
    }
    final uri = Uri.tryParse(input.contains('://') ? input : 'https://$input');
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      setState(
        () => _error = '请输入有效的服务器地址。',
      );
      return;
    }
    try {
      final dialogContext = _navigatorKey.currentState?.overlay?.context;
      if (dialogContext == null) {
        throw StateError('The connection dialog is not available.');
      }
      await ensureServerCertificatePinned(
        dialogContext,
        uri,
        widget.cache,
        confirmOnFirstUse: false,
      );
      await widget.cache.putText('direct-server-address', uri.toString());
      if (mounted) widget.onConnect(uri);
    } catch (error) {
      AppLogger.log(
        'client.server_connection_failed',
        level: 'error',
        error: error,
      );
      if (mounted) {
        setState(() => _error = serverConnectionErrorMessage(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: '连接管理端',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(title: const Text('连接管理端')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('连接聊天服务器', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(
                '请输入管理端运行设备提供的 HTTPS 地址，并确保设备和网络可正常访问。',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _address,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _continue(),
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '192.168.1.10:8443',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(onPressed: _continue, child: const Text('继续')),
            ],
          ),
        ),
      );
}
