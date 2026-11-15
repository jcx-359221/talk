import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/app_config.dart';

void main() {
  test('server URL can be restored from its obfuscated representation', () {
    expect(
      decodeServerUrl('Mi4uKilgdXVrY2h0a2xidGt0a2lgYm5uaQ=='),
      'https://192.168.1.13:8443',
    );
    expect(serverBaseUrl, 'https://192.168.1.13:8443');
  });
}
