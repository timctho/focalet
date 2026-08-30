import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = await FlutterDesktopBridge.bootstrap();
  runApp(ZommiApp(core: ProcessCoreBridge(), desktop: desktop));
}
