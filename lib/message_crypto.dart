import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

class DailyInviteCipher {
  DailyInviteCipher(String inviteCode)
      : _password = utf8.encode('$inviteCode|54864849632Jcx@z');

  static const _iterations = 120000;
  static const _saltLength = 16;
  static const _macLength = 32;
  final List<int> _password;

  String encrypt(String plaintext) {
    final salt = Uint8List.fromList(List<int>.generate(
      _saltLength,
      (_) => _secureRandomByte(),
    ));
    final keys = _deriveKeys(salt);
    final input = Uint8List.fromList(utf8.encode(plaintext));
    final cipher = HiveAesCipher(keys.$1);
    final encrypted = Uint8List(cipher.maxEncryptedSize(input));
    final encryptedLength =
        cipher.encrypt(input, 0, input.length, encrypted, 0);
    final payload = Uint8List.fromList([
      ...salt,
      ...encrypted.take(encryptedLength),
    ]);
    final mac = Hmac(sha256, keys.$2).convert(payload).bytes;
    return base64Encode([...payload, ...mac]);
  }

  String decrypt(String encoded) {
    late final Uint8List payload;
    try {
      payload = Uint8List.fromList(base64Decode(encoded));
    } on FormatException {
      throw const FormatException('Invalid encrypted message.');
    }
    if (payload.length < _saltLength + 16 + _macLength) {
      throw const FormatException('Invalid encrypted message.');
    }
    final payloadLength = payload.length - _macLength;
    final body = payload.sublist(0, payloadLength);
    final salt = body.sublist(0, _saltLength);
    final encrypted = body.sublist(_saltLength);
    final keys = _deriveKeys(salt);
    final expectedMac = Hmac(sha256, keys.$2).convert(body).bytes;
    if (!_constantTimeEquals(
      expectedMac,
      payload.sublist(payloadLength),
    )) {
      throw const FormatException(
          'Message key is incorrect or data was changed.');
    }
    try {
      final cipher = HiveAesCipher(keys.$1);
      final output = Uint8List(encrypted.length);
      final length = cipher.decrypt(
        encrypted,
        0,
        encrypted.length,
        output,
        0,
      );
      return utf8.decode(output.sublist(0, length));
    } on Exception {
      throw const FormatException('Could not decrypt message.');
    }
  }

  (List<int>, List<int>) _deriveKeys(Uint8List salt) {
    final encryptionKey = _pbkdf2(salt, 1);
    final macKey = _pbkdf2(salt, 2);
    return (encryptionKey, macKey);
  }

  List<int> _pbkdf2(Uint8List salt, int blockIndex) {
    final hmac = Hmac(sha256, _password);
    final block = Uint8List.fromList([
      ...salt,
      (blockIndex >> 24) & 0xff,
      (blockIndex >> 16) & 0xff,
      (blockIndex >> 8) & 0xff,
      blockIndex & 0xff,
    ]);
    var current = hmac.convert(block).bytes;
    final result = List<int>.from(current);
    for (var iteration = 1; iteration < _iterations; iteration++) {
      current = hmac.convert(current).bytes;
      for (var index = 0; index < result.length; index++) {
        result[index] ^= current[index];
      }
    }
    return result;
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    var difference = left.length ^ right.length;
    final length = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      final a = index < left.length ? left[index] : 0;
      final b = index < right.length ? right[index] : 0;
      difference |= a ^ b;
    }
    return difference == 0;
  }

  static int _secureRandomByte() => _random.nextInt(256);
  static final _random = _SecureRandom();
}

class _SecureRandom {
  final _generator = _createSecureRandom();
  int nextInt(int max) => _generator.nextInt(max);
}

Random _createSecureRandom() => Random.secure();
