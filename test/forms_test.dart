import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/forms.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/types.dart';

class MockOneloClient extends Mock implements OneloClient {}

void main() {
  group('OneloForms.submit', () {
    test('delegates to OneloClient.submitForm', () async {
      final mockClient = MockOneloClient();
      when(() => mockClient.submitForm('feedback', {'message': 'hi'}, submitterEmail: null))
        .thenAnswer((_) async => const FormResult(success: true, message: 'ok'));
      final forms = OneloForms(mockClient);
      final result = await forms.submit('feedback', {'message': 'hi'});
      expect(result.success, isTrue);
      verify(() => mockClient.submitForm('feedback', {'message': 'hi'}, submitterEmail: null)).called(1);
    });

    test('passes submitterEmail through', () async {
      final mockClient = MockOneloClient();
      when(() => mockClient.submitForm(any(), any(), submitterEmail: 'a@b.com'))
        .thenAnswer((_) async => const FormResult(success: true, message: 'ok'));
      final forms = OneloForms(mockClient);
      await forms.submit('feedback', {}, submitterEmail: 'a@b.com');
      verify(() => mockClient.submitForm(any(), any(), submitterEmail: 'a@b.com')).called(1);
    });
  });
}
