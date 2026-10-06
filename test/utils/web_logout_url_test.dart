import 'package:flutter_test/flutter_test.dart';
import 'package:kinde_flutter_sdk/src/utils/helpers.dart';

void main() {
  group('webLogoutUrl', () {
    test('returns to the app directly when the Kinde session is kept', () {
      final url = webLogoutUrl(
        endSessionEndpoint: 'https://auth.example.com/logout',
        logoutRedirectUri: 'https://app.example.com/',
        endSession: false,
      );

      expect(url, 'https://app.example.com/');
    });

    test('goes through the Kinde logout endpoint when ending the session', () {
      final url = Uri.parse(
        webLogoutUrl(
          endSessionEndpoint: 'https://auth.example.com/logout',
          logoutRedirectUri: 'https://app.example.com/',
          endSession: true,
        ),
      );

      expect(url.origin, 'https://auth.example.com');
      expect(url.path, '/logout');
      expect(url.queryParameters, {'redirect': 'https://app.example.com/'});
      expect(isSafeWebUrl(url.toString()), isTrue);
    });
  });
}
