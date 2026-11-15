import 'dart:io';

String clientApkFileName(String requestedName) {
  final safeName = requestedName
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[ .]+$'), '');
  if (safeName.isEmpty || safeName == '.' || safeName == '..') {
    throw ArgumentError.value(requestedName, 'requestedName', '名称不能为空。');
  }
  return 'chat_client_$safeName.apk';
}

Future<String> buildDeviceClientApk({
  required String requestedName,
  required String deviceIdentity,
  required String serverUrl,
}) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('只能在 Windows 服务端上编译客户端 APK。');
  }
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(deviceIdentity)) {
    throw const FormatException('设备标识缺失或格式无效，无法编译专属 APK。');
  }

  const projectRoot = r'D:\talk';
  const buildScript = r'D:\talk\scripts\build-client.ps1';
  final scriptFile = File(buildScript);
  if (!await scriptFile.exists()) {
    throw FileSystemException('找不到客户端构建脚本。', buildScript);
  }

  final fileName = clientApkFileName(requestedName);
  final arguments = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    buildScript,
    '-ExpectedDeviceIdentity',
    deviceIdentity,
    '-OutputName',
    fileName,
    '-ServerUrl',
    serverUrl,
    '-SkipPreparation',
  ];
  final result = await Process.run(
    'powershell.exe',
    arguments,
    workingDirectory: projectRoot,
  );
  if (result.exitCode != 0) {
    final details = '${result.stderr}\n${result.stdout}'.trim();
    throw ProcessException(
      'powershell.exe',
      arguments,
      details.isEmpty ? '客户端 APK 编译失败。' : details,
      result.exitCode,
    );
  }
  return '$projectRoot\\dist\\$fileName';
}
