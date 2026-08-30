import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop runners target Windows, Linux, and macOS as Zommi', () {
    final root = Directory.current;
    expect(Directory('${root.path}/windows/runner').existsSync(), isTrue);
    expect(Directory('${root.path}/linux/runner').existsSync(), isTrue);
    expect(Directory('${root.path}/macos/Runner').existsSync(), isTrue);

    expect(
      File('${root.path}/windows/CMakeLists.txt').readAsStringSync(),
      contains('set(BINARY_NAME "Zommi")'),
    );
    expect(
      File('${root.path}/linux/CMakeLists.txt').readAsStringSync(),
      allOf(
        contains('set(BINARY_NAME "zommi")'),
        contains('set(APPLICATION_ID "com.zommi.desktop")'),
      ),
    );
    expect(
      File('${root.path}/macos/Runner/Configs/AppInfo.xcconfig')
          .readAsStringSync(),
      allOf(
        contains('PRODUCT_NAME = Zommi'),
        contains('PRODUCT_BUNDLE_IDENTIFIER = com.zommi.desktop'),
      ),
    );
  });
}
