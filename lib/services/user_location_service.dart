import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:meshcore_team/models/app_settings.dart';
import 'package:meshcore_team/services/location_debug_override.dart';
import 'package:meshcore_team/services/settings_service.dart';
import 'package:meshcore_team/viewmodels/connection_viewmodel.dart';

class UserLocationFix {
  const UserLocationFix({
    required this.position,
    required this.timestamp,
    required this.source,
    this.speedMps,
    this.headingDegrees,
  });

  final LatLng position;
  final DateTime timestamp;
  final String source; // LocationSource.phone or .companion
  final double? speedMps;
  final double? headingDegrees;
}

class UserLocationService extends ChangeNotifier {
  UserLocationService({
    required SettingsService settingsService,
    required ConnectionViewModel connectionVM,
    LocationDebugOverride? debugOverride,
  })  : _settingsService = settingsService,
        _connectionVM = connectionVM,
        _debugOverride = debugOverride {
    _settingsService.addListener(_onDependencyChanged);
    _connectionVM.addListener(_onDependencyChanged);
    _debugOverride?.addListener(_onDependencyChanged);
    applyPolicy();
  }

  final SettingsService _settingsService;
  final ConnectionViewModel _connectionVM;
  final LocationDebugOverride? _debugOverride;

  LocationDebugOverride? get debugOverride => _debugOverride;

  UserLocationFix? _latestFix;
  String? _locationError;
  bool _isLoadingLocation = false;

  UserLocationFix? get latestFix => _latestFix;
  String? get locationError => _locationError;
  bool get isLoadingLocation => _isLoadingLocation;

  StreamSubscription<Position>? _positionSub;
  Timer? _phonePollingTimer;
  Timer? _companionTelemetryTimer;
  bool? _lastShouldUseCompanion;
  LatLng? _lastCompanionPosition;
  // Once any external GPS injection is received, lock to fake phone GPS for
  // the lifetime of this session (until hot restart). Prevents companion noise
  // from overriding injected positions.
  bool _fakeGpsLocked = false;

  void applyPolicy() {
    final wantsCompanion =
        _settingsService.settings.locationSource == LocationSource.companion;

    final fakeCompanion = _debugOverride?.companion;
    final fakePhone = _debugOverride?.phone;

    if (fakePhone != null && fakePhone.enabled) {
      _fakeGpsLocked = true;
    }

    // --- Companion path ---
    final bool shouldUseCompanion;
    if (_fakeGpsLocked) {
      // Fake GPS injection has been received — lock out companion for this session.
      _stopCompanionTelemetry();
      shouldUseCompanion = false;
    } else if (fakeCompanion != null && fakeCompanion.enabled) {
      // Fake companion: skip real telemetry polling, honour hasFix flag.
      _stopCompanionTelemetry();
      shouldUseCompanion = wantsCompanion && fakeCompanion.hasFix;
    } else {
      final companionFixTime = _connectionVM.companionGpsFixTime;
      final hasRecentCompanionFix = _connectionVM.hasCompanionGpsFix &&
          companionFixTime != null &&
          DateTime.now().difference(companionFixTime) <
              const Duration(seconds: 10);

      final shouldPollCompanion = wantsCompanion && _connectionVM.isConnected;
      if (shouldPollCompanion && _companionTelemetryTimer == null) {
        _companionTelemetryTimer =
            Timer.periodic(const Duration(seconds: 2), (_) {
          _connectionVM.requestCompanionTelemetry();
        });
        _connectionVM.requestCompanionTelemetry();
      } else if (!shouldPollCompanion && _companionTelemetryTimer != null) {
        _stopCompanionTelemetry();
      }

      shouldUseCompanion =
          wantsCompanion && _connectionVM.isConnected && hasRecentCompanionFix;
    }

    if (shouldUseCompanion != _lastShouldUseCompanion) {
      debugPrint(
          '[UserLocationService] source switch: shouldUseCompanion=$shouldUseCompanion');
      _lastShouldUseCompanion = shouldUseCompanion;
    }

    if (shouldUseCompanion) {
      _stopPhoneTracking();

      LatLng? pos;
      if (fakeCompanion != null && fakeCompanion.enabled) {
        pos = fakeCompanion.position;
      } else {
        final lat = _connectionVM.companionLatitude;
        final lon = _connectionVM.companionLongitude;
        if (lat != null && lon != null) pos = LatLng(lat, lon);
      }

      if (pos != null) {
        if (_lastCompanionPosition?.latitude != pos.latitude ||
            _lastCompanionPosition?.longitude != pos.longitude) {
          _lastCompanionPosition = pos;
          _emitFix(UserLocationFix(
            position: pos,
            timestamp: DateTime.now(),
            source: LocationSource.companion,
          ));
        }
      }
    } else {
      // --- Phone path ---
      if (fakePhone != null && fakePhone.enabled) {
        _stopPhoneTracking();
        if (fakePhone.hasFix) {
          // Emit directly — the external sender (e.g. gps_replay.py) drives
          // the rate by pushing new positions, each of which triggers applyPolicy().
          _emitFix(UserLocationFix(
            position: fakePhone.position,
            timestamp: DateTime.now(),
            source: LocationSource.phone,
            speedMps: fakePhone.speedMps,
            headingDegrees: fakePhone.headingDegrees,
          ));
        }
      } else {
        if (_positionSub == null && (Platform.isAndroid || Platform.isIOS)) {
          _startPhoneTracking();
        }
      }
    }
  }

  Future<void> fetchNow() async {
    final fakePhone = _debugOverride?.phone;
    if (fakePhone != null && fakePhone.enabled) {
      if (fakePhone.hasFix) {
        _emitFix(UserLocationFix(
          position: fakePhone.position,
          timestamp: DateTime.now(),
          source: LocationSource.phone,
          speedMps: fakePhone.speedMps,
          headingDegrees: fakePhone.headingDegrees,
        ));
      }
      return;
    }

    if (!Platform.isAndroid && !Platform.isIOS) return;
    _locationError = null;
    _isLoadingLocation = true;
    notifyListeners();
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      _isLoadingLocation = false;
      _emitFix(UserLocationFix(
        position: LatLng(position.latitude, position.longitude),
        timestamp: DateTime.now(),
        source: LocationSource.phone,
        speedMps: position.speed.isFinite ? position.speed : null,
        headingDegrees: (position.heading.isFinite && position.heading >= 0)
            ? position.heading
            : null,
      ));
    } catch (e) {
      _isLoadingLocation = false;
      if (e is TimeoutException) {
        // Stream will deliver the first fix when GPS acquires; don't surface a
        // transient timeout as an error.
        notifyListeners();
        return;
      }
      _locationError = 'Failed to get location: $e';
      notifyListeners();
    }
  }

  void _startPhoneTracking() {
    _positionSub?.cancel();
    _phonePollingTimer?.cancel();

    fetchNow();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );

    _positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((position) {
      _emitFix(UserLocationFix(
        position: LatLng(position.latitude, position.longitude),
        timestamp: DateTime.now(),
        source: LocationSource.phone,
        speedMps: position.speed.isFinite ? position.speed : null,
        headingDegrees: (position.heading.isFinite && position.heading >= 0)
            ? position.heading
            : null,
      ));
    }, onError: (Object error) {
      _locationError = 'Location stream error: $error';
      notifyListeners();
    });

    // Safety-net poll in case the OS throttles the stream.
    _phonePollingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 3),
        );
        _emitFix(UserLocationFix(
          position: LatLng(position.latitude, position.longitude),
          timestamp: DateTime.now(),
          source: LocationSource.phone,
          speedMps: position.speed.isFinite ? position.speed : null,
          headingDegrees: (position.heading.isFinite && position.heading >= 0)
              ? position.heading
              : null,
        ));
      } catch (_) {}
    });
  }

  void _stopPhoneTracking() {
    _positionSub?.cancel();
    _positionSub = null;
    _phonePollingTimer?.cancel();
    _phonePollingTimer = null;
  }

  void _stopCompanionTelemetry() {
    _companionTelemetryTimer?.cancel();
    _companionTelemetryTimer = null;
  }

  void _emitFix(UserLocationFix fix) {
    _latestFix = fix;
    notifyListeners();
  }

  void _onDependencyChanged() => applyPolicy();

  @override
  void dispose() {
    _settingsService.removeListener(_onDependencyChanged);
    _connectionVM.removeListener(_onDependencyChanged);
    _debugOverride?.removeListener(_onDependencyChanged);
    _stopPhoneTracking();
    _stopCompanionTelemetry();
    super.dispose();
  }
}
