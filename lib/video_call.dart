import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_log.dart';

typedef VideoCallSignalSender = Future<void> Function(
  String type, {
  String? sdp,
  Map<String, dynamic>? candidate,
});

typedef VideoCallSignalPoller = Future<List<Map<String, dynamic>>> Function();

class DirectVideoCallDialog extends StatefulWidget {
  const DirectVideoCallDialog({
    required this.callId,
    required this.clientSide,
    required this.iceServers,
    required this.sendSignal,
    required this.pollSignals,
    required this.onClose,
    super.key,
  });

  final String callId;
  final bool clientSide;
  final List<Map<String, dynamic>> iceServers;
  final VideoCallSignalSender sendSignal;
  final VideoCallSignalPoller pollSignals;
  final VoidCallback onClose;

  @override
  State<DirectVideoCallDialog> createState() => _DirectVideoCallDialogState();
}

class _DirectVideoCallDialogState extends State<DirectVideoCallDialog> {
  final _remoteRenderer = RTCVideoRenderer();
  final _localRenderer = RTCVideoRenderer();
  final _pendingCandidates = <RTCIceCandidate>[];
  final _seenSignals = <String>{};
  late final Future<void> _rendererInitialization;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  Timer? _signalTimer;
  Timer? _inviteTimeoutTimer;
  bool _polling = false;
  bool _startingPeer = false;
  bool _ended = false;
  bool _microphoneEnabled = true;
  bool _speakerEnabled = true;
  String _status = '等待客户端接听…';
  Object? _rendererInitializationError;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rendererInitialization = _initializeRenderers();
    _signalTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => unawaited(_pollSignals()),
    );
    if (!widget.clientSide) {
      _inviteTimeoutTimer = Timer(
        const Duration(minutes: 1),
        () => _finish('客户端暂未接听。', notifyPeer: true),
      );
    }
    unawaited(_pollSignals());
  }

  Future<void> _initializeRenderers() async {
    try {
      await _remoteRenderer.initialize();
      await _localRenderer.initialize();
      if (mounted) setState(() {});
    } catch (error, stackTrace) {
      _rendererInitializationError = error;
      _reportError('无法初始化视频窗口。', error, stackTrace);
    }
  }

  Future<void> _pollSignals() async {
    if (_polling || _ended) return;
    _polling = true;
    try {
      final events = await widget.pollSignals();
      for (final event in events) {
        if (event['call_id'] != widget.callId) continue;
        final signalId = event['id']?.toString();
        if (signalId != null && !_seenSignals.add(signalId)) continue;
        await _handleSignal(event);
      }
    } catch (error, stackTrace) {
      if (!_ended) {
        AppLogger.log(
          'video_call.signal_poll_failed',
          level: 'warning',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _handleSignal(Map<String, dynamic> signal) async {
    switch (signal['type']) {
      case 'accept':
        if (!widget.clientSide) {
          _inviteTimeoutTimer?.cancel();
          await _startPeer();
        }
        break;
      case 'reject':
        _finish('客户端拒绝了视频通话。', notifyPeer: false);
        break;
      case 'offer':
        if (widget.clientSide) await _answerOffer(signal);
        break;
      case 'answer':
        if (!widget.clientSide) await _applyAnswer(signal);
        break;
      case 'candidate':
        await _applyCandidate(signal);
        break;
      case 'hangup':
        _finish('对方已结束通话。', notifyPeer: false);
        break;
    }
  }

  Future<void> _startPeer() async {
    if (_startingPeer || _peerConnection != null || _ended) return;
    _startingPeer = true;
    if (mounted) setState(() => _status = '正在连接媒体设备…');
    try {
      await _rendererInitialization;
      if (_rendererInitializationError != null) {
        throw StateError('视频窗口初始化失败：$_rendererInitializationError');
      }
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': widget.clientSide
            ? {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
                'frameRate': {'ideal': 24, 'max': 30},
              }
            : false,
      });
      _localStream = stream;
      if (widget.clientSide) _localRenderer.srcObject = stream;

      final connection = await createPeerConnection({
        'iceServers': widget.iceServers,
        'sdpSemantics': 'unified-plan',
      });
      _peerConnection = connection;
      for (final track in stream.getTracks()) {
        await connection.addTrack(track, stream);
      }
      connection.onIceCandidate = (candidate) {
        final candidateValue = candidate.candidate;
        if (candidateValue == null || candidateValue.isEmpty) return;
        unawaited(
          _sendSignal(
            'candidate',
            candidate: {
              'candidate': candidateValue,
              'sdp_mid': candidate.sdpMid,
              'sdp_mline_index': candidate.sdpMLineIndex,
            },
          ),
        );
      };
      connection.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
        }
        if (_remoteStream != null) {
          _remoteRenderer.srcObject = _remoteStream;
          _applySpeakerSetting();
        }
        if (mounted) setState(() => _status = '视频通话中');
      };
      connection.onConnectionState = (state) {
        if (!mounted || _ended) return;
        setState(() {
          _status = switch (state) {
            RTCPeerConnectionState.RTCPeerConnectionStateConnected => '视频通话中',
            RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
              '正在建立通话…',
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
              '连接中断，正在尝试恢复…',
            RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
              '连接失败，请稍后重试。',
            RTCPeerConnectionState.RTCPeerConnectionStateClosed => '通话已结束',
            _ => '正在连接…',
          };
        });
      };
      if (!widget.clientSide) {
        final offer = await connection.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': true,
        });
        await connection.setLocalDescription(offer);
        await _sendSignal('offer', sdp: offer.sdp);
      }
      _applyMicrophoneSetting();
      if (mounted) setState(() => _status = '正在建立通话…');
    } catch (error, stackTrace) {
      _reportError(
        widget.clientSide ? '无法开启摄像头或麦克风。' : '无法开启麦克风。',
        error,
        stackTrace,
      );
      await _sendSignal('hangup');
    } finally {
      _startingPeer = false;
    }
  }

  Future<void> _answerOffer(Map<String, dynamic> signal) async {
    final sdp = signal['sdp'];
    if (sdp is! String || sdp.isEmpty) return;
    await _startPeer();
    final connection = _peerConnection;
    if (connection == null || _ended) return;
    try {
      await connection.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
      await _flushCandidates();
      final answer = await connection.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      await connection.setLocalDescription(answer);
      await _sendSignal('answer', sdp: answer.sdp);
    } catch (error, stackTrace) {
      _reportError('建立客户端视频连接失败。', error, stackTrace);
      await _sendSignal('hangup');
    }
  }

  Future<void> _applyAnswer(Map<String, dynamic> signal) async {
    final sdp = signal['sdp'];
    final connection = _peerConnection;
    if (sdp is! String || connection == null || _ended) return;
    try {
      await connection.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
      await _flushCandidates();
    } catch (error, stackTrace) {
      _reportError('处理客户端视频应答失败。', error, stackTrace);
      await _sendSignal('hangup');
    }
  }

  Future<void> _applyCandidate(Map<String, dynamic> signal) async {
    final data = signal['candidate'];
    if (data is! Map || data['candidate'] is! String) return;
    final candidate = RTCIceCandidate(
      data['candidate'] as String,
      data['sdp_mid'] as String?,
      data['sdp_mline_index'] as int?,
    );
    final connection = _peerConnection;
    if (connection == null || await connection.getRemoteDescription() == null) {
      _pendingCandidates.add(candidate);
      return;
    }
    await connection.addCandidate(candidate);
  }

  Future<void> _flushCandidates() async {
    final connection = _peerConnection;
    if (connection == null) return;
    for (final candidate in _pendingCandidates) {
      await connection.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> _sendSignal(
    String type, {
    String? sdp,
    Map<String, dynamic>? candidate,
  }) async {
    try {
      await widget.sendSignal(type, sdp: sdp, candidate: candidate);
    } catch (error, stackTrace) {
      _reportError('通话信令发送失败。', error, stackTrace);
    }
  }

  void _applyMicrophoneSetting() {
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = _microphoneEnabled;
    }
  }

  void _applySpeakerSetting() {
    for (final track in _remoteStream?.getAudioTracks() ?? const []) {
      track.enabled = _speakerEnabled;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(Helper.setSpeakerphoneOn(_speakerEnabled));
    }
  }

  void _toggleMicrophone() {
    setState(() => _microphoneEnabled = !_microphoneEnabled);
    _applyMicrophoneSetting();
  }

  void _toggleSpeaker() {
    setState(() => _speakerEnabled = !_speakerEnabled);
    _applySpeakerSetting();
  }

  void _reportError(String message, Object error, StackTrace stackTrace) {
    AppLogger.log(
      'video_call.media_error',
      level: 'error',
      error: error,
      stackTrace: stackTrace,
    );
    if (mounted) setState(() => _error = '$message $error');
  }

  void _finish(String status, {required bool notifyPeer}) {
    if (_ended) return;
    _ended = true;
    _signalTimer?.cancel();
    _inviteTimeoutTimer?.cancel();
    if (mounted) setState(() => _status = status);
    if (notifyPeer) unawaited(_sendSignal('hangup'));
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) widget.onClose();
    });
  }

  @override
  void dispose() {
    _signalTimer?.cancel();
    _inviteTimeoutTimer?.cancel();
    _remoteRenderer.srcObject = null;
    _localRenderer.srcObject = null;
    unawaited(_remoteRenderer.dispose());
    unawaited(_localRenderer.dispose());
    for (final track in _localStream?.getTracks() ?? const []) {
      unawaited(track.stop());
    }
    final stream = _localStream;
    if (stream != null) unawaited(stream.dispose());
    final remoteStream = _remoteStream;
    if (remoteStream != null) unawaited(remoteStream.dispose());
    final connection = _peerConnection;
    if (connection != null) {
      unawaited(connection.close());
      unawaited(connection.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasLocalVideo = widget.clientSide && _localStream != null;
    return PopScope<void>(
      canPop: _ended,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish('正在结束通话…', notifyPeer: true);
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(_status),
            leading: IconButton(
              tooltip: '结束通话',
              onPressed: () => _finish('正在结束通话…', notifyPeer: true),
              icon: const Icon(Icons.call_end, color: Colors.redAccent),
            ),
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.clientSide)
                hasLocalVideo
                    ? RTCVideoView(
                        _localRenderer,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : const Center(
                        child: Icon(
                          Icons.videocam,
                          color: Colors.white54,
                          size: 96,
                        ),
                      )
              else if (_remoteStream != null)
                RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                )
              else
                const Center(
                  child: Icon(Icons.person, color: Colors.white54, size: 96),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 20,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade900,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    Text(
                      widget.clientSide ? '摄像头与麦克风保持开启' : '本端不使用摄像头',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!widget.clientSide)
                          IconButton.filledTonal(
                            tooltip: _microphoneEnabled ? '关闭麦克风' : '打开麦克风',
                            onPressed: _toggleMicrophone,
                            icon: Icon(
                              _microphoneEnabled ? Icons.mic : Icons.mic_off,
                            ),
                          ),
                        const SizedBox(width: 20),
                        IconButton.filledTonal(
                          tooltip: _speakerEnabled ? '静音扬声器' : '打开扬声器',
                          onPressed: _toggleSpeaker,
                          icon: Icon(
                            _speakerEnabled
                                ? Icons.volume_up
                                : Icons.volume_off,
                          ),
                        ),
                        const SizedBox(width: 20),
                        IconButton.filled(
                          tooltip: '结束通话',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _finish('正在结束通话…', notifyPeer: true),
                          icon: const Icon(Icons.call_end),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
