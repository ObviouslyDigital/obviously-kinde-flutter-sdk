import 'package:flutter_test/flutter_test.dart';
import 'package:kinde_flutter_sdk/src/additional_params.dart';

void main() {
  group('InternalAdditionalParameters.fromUserAdditionalParams prompt', () {
    test('defaults to prompt=login when the caller sets no prompt', () {
      final params = InternalAdditionalParameters.fromUserAdditionalParams(
        const AdditionalParameters(orgCode: 'org_1'),
      );

      expect(params.promptValues, ['login']);
      expect(params.toWebParams()['prompt'], 'login');
    });

    test('sends the caller prompt instead of the default', () {
      final params = InternalAdditionalParameters.fromUserAdditionalParams(
        const AdditionalParameters(promptValues: ['none']),
      );

      expect(params.toWebParams()['prompt'], 'none');
    });

    test('omits prompt when the caller passes an empty list', () {
      final params = InternalAdditionalParameters.fromUserAdditionalParams(
        const AdditionalParameters(promptValues: []),
      );

      expect(params.promptValues, isNull);
      expect(params.toWebParams().containsKey('prompt'), isFalse);
    });

    test('joins several prompt values with a space', () {
      final params = InternalAdditionalParameters.fromUserAdditionalParams(
        const AdditionalParameters(promptValues: ['login', 'consent']),
      );

      expect(params.toWebParams()['prompt'], 'login consent');
    });

    test('keeps the other caller parameters', () {
      final params = InternalAdditionalParameters.fromUserAdditionalParams(
        const AdditionalParameters(orgCode: 'org_1', promptValues: []),
      );

      expect(params.toWebParams(), {'org_code': 'org_1'});
    });
  });
}
