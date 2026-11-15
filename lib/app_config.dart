import 'dart:convert';

const _encodedServerUrl = String.fromEnvironment(
  'CLIENT_SERVER_URL_XOR_B64',
  defaultValue: 'Mi4uKilgdXVrY2h0a2xidGt0a2lgYm5uaQ==',
);

String decodeServerUrl(String encodedUrl) {
  final bytes = base64Decode(encodedUrl);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] ^= 0x5A;
  }
  return utf8.decode(bytes);
}

final serverBaseUrl = decodeServerUrl(_encodedServerUrl);
