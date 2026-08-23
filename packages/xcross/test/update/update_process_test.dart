import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/update_process.dart';

void main() {
  test(
    'missing required executable becomes an actionable XcrossError',
    () async {
      const executable = 'xcross-guaranteed-missing-update-executable';

      await expectLater(
        () => runUpdateProcess(executable, const []),
        throwsA(
          isA<XcrossError>()
              .having((error) => error.message, 'message', contains(executable))
              .having((error) => error.message, 'message', contains('PATH')),
        ),
      );
    },
  );
}
