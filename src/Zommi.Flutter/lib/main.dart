import 'package:flutter/material.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ZommiApp(core: ProcessCoreBridge()));
}
