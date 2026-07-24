import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';

class Metadata {
  String? device;
  String? locale;

  Metadata(this.device, this.locale);

  Metadata.create()
    : this(
        kIsWeb ? "web" : Platform.operatingSystem,
        ui.PlatformDispatcher.instance.locale.toLanguageTag(),
      );

  Map<String, dynamic> toMap() {
    return {'device': device, 'locale': locale};
  }
}
