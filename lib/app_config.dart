import 'dart:convert';

const _encodedServerUrl = String.fromEnvironment(
  'CLIENT_SERVER_URL_XOR_B64',
  defaultValue: 'Mi4uKilgdXUBaG5qYmBiaGk5YG47a29gbGg5OWBiaWxtYGg5bzlgaGo7aWBpYj9vB2Bibm5p',
);

String decodeServerUrl(String encodedUrl) {
  final bytes = base64Decode(encodedUrl);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] ^= 0x5A;
  }
  return utf8.decode(bytes);
}

final serverBaseUrl = decodeServerUrl(_encodedServerUrl);
