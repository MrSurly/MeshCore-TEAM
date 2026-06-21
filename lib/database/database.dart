// Copyright (c) 2026 tmacinc
// Licensed under CC BY-NC-SA 4.0
// http://creativecommons.org/licenses/by-nc-sa/4.0/
//
// This file is part of TEAM-Flutter.
// Non-commercial use only. See LICENSE file for details.

import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'tables.dart';
import 'daos/contacts_dao.dart';
import 'daos/channels_dao.dart';
import 'daos/messages_dao.dart';
import 'daos/waypoints_dao.dart';
import 'daos/ack_records_dao.dart';
import 'daos/companion_devices_dao.dart';
import 'daos/offline_map_areas_dao.dart';
import 'daos/imported_overlay_maps_dao.dart';

part 'database.g.dart';

// Type aliases for convenience
typedef Contact = NodeData;
typedef ContactData = NodeData; // backward-compat alias for legacy call sites
typedef Channel = ChannelData;
typedef Message = MessageData;
typedef Waypoint = WaypointData;
typedef CompanionDevice = CompanionDeviceData;
typedef ContactDisplayState = ContactDisplayStateData;
typedef ContactPositionHistory = ContactPositionHistoryData;
typedef AckRecord = AckRecordData;

/// Main database class for TEAM-Flutter
///
/// Manages all database tables and DAOs for the mesh networking app.
/// Uses Drift (SQLite) for local data persistence.
///
/// Schema matches Android TEAM app (meshcore-team) exactly.
@DriftDatabase(
  tables: [
    Nodes,
    Channels,
    Messages,
    Waypoints,
    CompanionDevices,
    ContactDisplayStates,
    ContactPositionHistories,
    AckRecords,
    OfflineMapAreas,
    ImportedOverlayMaps,
  ],
  daos: [
    ContactsDao,
    ChannelsDao,
    MessagesDao,
    WaypointsDao,
    AckRecordsDao,
    CompanionDevicesDao,
    OfflineMapAreasDao,
    ImportedOverlayMapsDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // Test constructor for in-memory database
  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Migration from schema version 1 to 2: Add isRead column to Messages table
          if (from == 1 && to >= 2) {
            await m.addColumn(messages, messages.isRead);
          }

          // Migration from schema version 2 to 3: Fix isPrivate flag for channel messages
          if (from <= 2 && to >= 3) {
            // Get all channel hashes
            final channelHashes =
                await (select(channels)).map((c) => c.hash).get();

            // Update messages that belong to channels to have isPrivate=false
            for (final channelHash in channelHashes) {
              await (update(messages)
                    ..where((t) => t.channelHash.equals(channelHash)))
                  .write(MessagesCompanion(
                isPrivate: const Value(false),
              ));
            }

            print(
                '[Migration] Fixed isPrivate flag for ${channelHashes.length} channels');
          }

          // Migration from schema version 3 to 4: Add companionDeviceKey to AckRecords table
          if (from <= 3 && to >= 4) {
            await m.addColumn(ackRecords, ackRecords.companionDeviceKey);
            print('[Migration] Added companionDeviceKey to ack_records table');
          }

          // Migration from schema version 4 to 5: Add offline_map_areas table
          if (from <= 4 && to >= 5) {
            await m.createTable(offlineMapAreas);
            print('[Migration] Created offline_map_areas table');
          }

          // Migration from schema version 5 to 6: Add isAutonomousDevice to contacts
          if (from <= 5 && to >= 6) {
            await customStatement(
                'ALTER TABLE contacts ADD COLUMN is_autonomous_device INTEGER NOT NULL DEFAULT 0');
            print('[Migration] Added isAutonomousDevice to contacts table');
          }

          // Migration from schema version 6 to 7: Add isAutonomousDevice to contact_display_states
          if (from <= 6 && to >= 7) {
            await m.addColumn(
                contactDisplayStates, contactDisplayStates.isAutonomousDevice);
            print(
                '[Migration] Added isAutonomousDevice to contact_display_states table');
          }

          // Migration from schema version 7 to 8: Add imported_overlay_maps table
          if (from <= 7 && to >= 8) {
            await m.createTable(importedOverlayMaps);
            print('[Migration] Created imported_overlay_maps table');
          }

          // Migration from schema version 8 to 9: Replace contacts table with
          // nodes, using a proper NodeType enum instead of boolean flags.
          if (from <= 8 && to >= 9) {
            await m.createTable(nodes);
            final rows = await customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='contacts'",
            ).get();
            if (rows.isNotEmpty) {
              await customStatement('''
                INSERT INTO nodes (
                  public_key, hash, name, latitude, longitude, last_seen,
                  companion_battery_milli_volts, phone_battery_milli_volts,
                  node_type, is_direct, hop_count,
                  last_telemetry_channel_idx, last_telemetry_timestamp,
                  is_out_of_range, is_autonomous_device, companion_device_key
                )
                SELECT
                  public_key, hash, name, latitude, longitude, last_seen,
                  companion_battery_milli_volts, phone_battery_milli_volts,
                  CASE
                    WHEN is_repeater  = 1 THEN 2
                    WHEN is_room_server = 1 THEN 3
                    ELSE 1
                  END,
                  is_direct, hop_count,
                  last_telemetry_channel_idx, last_telemetry_timestamp,
                  is_out_of_range, COALESCE(is_autonomous_device, 0),
                  companion_device_key
                FROM contacts
              ''');
              print('[Migration] Migrated contacts -> nodes');
            }
          }
        },
      );
}

/// Opens a connection to the database
LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'meshcore_team.db'));
    return NativeDatabase(file);
  });
}
