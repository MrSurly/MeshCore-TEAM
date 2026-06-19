import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class FakeGpsSource extends ChangeNotifier {
  bool _enabled = false;
  bool _hasFix = true;
  LatLng _position = const LatLng(37.7749, -122.4194);
  double? _speedMps;
  double? _headingDegrees;

  bool get enabled => _enabled;
  bool get hasFix => _hasFix;
  LatLng get position => _position;
  double? get speedMps => _speedMps;
  double? get headingDegrees => _headingDegrees;

  set enabled(bool v) {
    _enabled = v;
    notifyListeners();
  }

  set hasFix(bool v) {
    _hasFix = v;
    notifyListeners();
  }

  set position(LatLng v) {
    _position = v;
    notifyListeners();
  }

  set speedMps(double? v) {
    _speedMps = v;
    notifyListeners();
  }

  set headingDegrees(double? v) {
    _headingDegrees = v;
    notifyListeners();
  }

  void update({
    bool? enabled,
    bool? hasFix,
    LatLng? position,
    double? speedMps,
    double? headingDegrees,
  }) {
    if (enabled != null) _enabled = enabled;
    if (hasFix != null) _hasFix = hasFix;
    if (position != null) _position = position;
    if (speedMps != null) _speedMps = speedMps;
    if (headingDegrees != null) _headingDegrees = headingDegrees;
    notifyListeners();
  }
}

class LocationDebugOverride extends ChangeNotifier {
  LocationDebugOverride() {
    phone.addListener(notifyListeners);
    companion.addListener(notifyListeners);
  }

  final FakeGpsSource phone = FakeGpsSource();
  final FakeGpsSource companion = FakeGpsSource();

  @override
  void dispose() {
    phone.removeListener(notifyListeners);
    companion.removeListener(notifyListeners);
    phone.dispose();
    companion.dispose();
    super.dispose();
  }
}
