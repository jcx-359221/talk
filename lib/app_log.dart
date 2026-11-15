import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<void> purgeClientLogsInDirectory(Directory directory) async {
  final clientLogPattern =
      RegExp(r'^client-mobile-\d{4}-\d{2}-\d{2}\.log(?:\.1)?$');
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File ||
        !clientLogPattern.hasMatch(entity.uri.pathSegments.last)) {
      continue;
    }
    await entity.delete();
  }
}

class AppLogger {
  AppLogger._();

  static const _maxFileBytes = 1024 * 1024;
  static Directory? _directory;
  static String? _filePrefix;
  static String? _appName;
  static Future<void> _pendingWrites = Future<void>.value();

  static Future<void> initialize(String appName) async {
    final directory = Platform.isWindows
        ? Directory(
            '${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}logs',
          )
        : Directory(
            '${(await getApplicationSupportDirectory()).path}'
            '${Platform.pathSeparator}logs',
          );
    await directory.create(recursive: true);
    _directory = directory;
    _filePrefix = appName;
    _appName = appName;
    log(
      'app.started',
      details: {
        'platform': Platform.operatingSystem,
        'log_directory': directory.path,
      },
    );
  }

  static void log(
    String event, {
    String level = 'info',
    Map<String, Object?> details = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {
    final directory = _directory;
    final filePrefix = _filePrefix;
    if (directory == null || filePrefix == null) {
      return;
    }

    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'app': _appName,
      'event': event,
      if (details.isNotEmpty) 'details': details,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stack_trace': stackTrace.toString(),
    };
    final line = '${jsonEncode(record)}\n';
    _pendingWrites = _pendingWrites.then((_) async {
      try {
        await _append(
            directory, _fileNameForDate(filePrefix, DateTime.now()), line);
      } catch (writeError, writeStack) {
        debugPrint('Could not write app log: $writeError\n$writeStack');
      }
    });
  }

  static Future<String> readForUpload() async {
    await _pendingWrites;
    final directory = _directory;
    final filePrefix = _filePrefix;
    if (directory == null || filePrefix == null) {
      throw StateError('The app log has not been initialized.');
    }
    final today = DateTime.now();
    final files = <File>[];
    for (var daysAgo = 1; daysAgo >= 0; daysAgo--) {
      final date = today.subtract(Duration(days: daysAgo));
      final fileName = _fileNameForDate(filePrefix, date);
      files.add(File('${directory.path}${Platform.pathSeparator}$fileName.1'));
      files.add(File('${directory.path}${Platform.pathSeparator}$fileName'));
    }
    final contents = <String>[];
    for (final file in files) {
      if (await file.exists()) contents.add(await file.readAsString());
    }
    if (contents.isEmpty) {
      throw StateError('No app log is available to upload.');
    }
    return contents.join();
  }

  static Future<void> clearClientLogs() async {
    await _pendingWrites;
    final directory = _directory;
    if (directory == null || _filePrefix != 'client-mobile') {
      throw StateError('The client app logger has not been initialized.');
    }

    await purgeClientLogsInDirectory(directory);
  }

  static Future<void> saveUploadedLog({
    required String fileName,
    required String content,
  }) async {
    if (fileName != 'server-mobile' && fileName != 'client-mobile') {
      throw ArgumentError.value(fileName, 'fileName', 'Unsupported app log.');
    }
    final directory = _directory;
    if (directory == null) {
      throw StateError('The app logger has not been initialized.');
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      '${_fileNameForDate(fileName, DateTime.now())}',
    );
    await file.writeAsString(content, flush: true);
  }

  static Future<void> _append(
    Directory directory,
    String fileName,
    String line,
  ) async {
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    if (await file.exists() && await file.length() >= _maxFileBytes) {
      final rotated = File('$file.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
    }
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  static String _fileNameForDate(String prefix, DateTime date) =>
      '$prefix-${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}.log';
}
