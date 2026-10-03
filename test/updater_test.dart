import 'package:flutter_test/flutter_test.dart';
import 'package:mawqi_now/services/updater.dart';

void main() {
  test('version compare', () {
    expect(Updater.compare('1.2.0', '1.1.0'), 1);
    expect(Updater.compare('1.1.0', '1.1.0'), 0);
    expect(Updater.compare('1.1.9', '1.2.0'), -1);
    expect(Updater.compare('1.10.0', '1.9.3'), 1);
    expect(Updater.compare('2.0', '1.99.99'), 1);
  });
}
