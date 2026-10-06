import 'package:flutter_test/flutter_test.dart';
import 'package:kinde_flutter_sdk/src/additional_params.dart';
import 'package:kinde_flutter_sdk/src/model/kinde_prompt.dart';

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
        const AdditionalParameters(prompt: KindePrompt.none),
      );

      expect(params.toWebParams()['prompt'], 'none');
    });

    test('omits prompt for useSession', () {
      final params = InternalAdditionalParameters.fromUserAdditionalParams(
        const AdditionalParameters(
            orgCode: 'org_1', prompt: KindePrompt.useSession),
      );

      expect(params.promptValues, isNull);
      expect(params.toWebParams(), {'org_code': 'org_1'});
    });
  });
}
