import 'dart:async';
import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart' as db;

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

class _Profiles extends Profiles {
  final Completer<void> write;

  _Profiles(this.write);

  @override
  Future<void> persistProfile(Profile profile) => write.future;
}

class _SqliteProfiles extends Profiles {
  final db.Database database;
  _SqliteProfiles(this.database);

  @override
  Future<void> persistProfile(Profile profile) async {
    await database.profiles.put(profile.toCompanion());
  }
}

void main() {
  const original = Profile(
    id: 1,
    label: 'managed',
    url: 'https://example.com/subscription',
    autoUpdateDuration: Duration(days: 1),
  );
  late StreamController<List<Profile>> stream;
  late ProviderContainer container;
  late Completer<void> write;

  setUp(() async {
    stream = StreamController<List<Profile>>(sync: true);
    write = Completer<void>();
    container = ProviderContainer(
      overrides: [
        profilesStreamProvider.overrideWith((ref) => stream.stream),
        profilesProvider.overrideWith(() => _Profiles(write)),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
      ],
    );
    container.listen(currentProfileProvider, (_, _) {});
    final loaded = container.read(profilesStreamProvider.future);
    stream.add([original]);
    await loaded;
    await container.pump();
    addTearDown(() async {
      container.dispose();
      await stream.close();
    });
  });

  test(
    'an older DB snapshot cannot revert a refreshed selected profile',
    () async {
      final updated = original.copyWith(lastUpdateDate: DateTime(2026, 10, 20));
      final pending = container
          .read(profilesProvider.notifier)
          .putAndWait(updated);
      expect(container.read(currentProfileProvider), updated);
      stream.add([original]);
      await container.pump();
      expect(container.read(currentProfileProvider), updated);
      write.complete();
      await pending;
      expect(container.read(currentProfileProvider), updated);
      stream.add([updated]);
      await container.pump();
      final external = updated.copyWith(label: 'renamed');
      stream.add([external]);
      await container.pump();
      expect(container.read(currentProfileProvider), external);
    },
  );

  test('failed profile persistence restores the previous selection', () async {
    final updated = original.copyWith(url: 'https://example.com/new');
    final pending = container
        .read(profilesProvider.notifier)
        .putAndWait(updated);
    final failed = expectLater(pending, throwsStateError);
    write.completeError(StateError('disk full'));
    await failed;
    expect(container.read(currentProfileProvider), original);
  });

  test(
    'real SQLite timestamps cannot invalidate the selected subscription',
    () async {
      final database = db.Database(NativeDatabase.memory());
      final persisted = original.copyWith(
        lastUpdateDate: DateTime(2026, 10, 20),
      );
      await database.profiles.put(persisted.toCompanion());
      final live = ProviderContainer(
        overrides: [
          profilesStreamProvider.overrideWith(
            (ref) => database.profilesDao.query().watch(),
          ),
          profilesProvider.overrideWith(() => _SqliteProfiles(database)),
          currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      live.listen(currentProfileProvider, (_, _) {});
      addTearDown(() async {
        live.dispose();
        await database.close();
      });
      await live.read(profilesStreamProvider.future);
      final updated = original.copyWith(
        lastUpdateDate: DateTime(2026, 10, 20, 0, 0, 1, 123, 456),
      );
      final acknowledged = Completer<void>();
      live.listen(profilesStreamProvider, (_, next) {
        if (next.value?.single.lastUpdateDate ==
                updated.withDatabasePrecision.lastUpdateDate &&
            !acknowledged.isCompleted) {
          acknowledged.complete();
        }
      });
      await live.read(profilesProvider.notifier).putAndWait(updated);
      final selected = live.read(currentProfileProvider);
      await acknowledged.future;
      await live.pump();
      expect(live.read(currentProfileProvider), selected);
      expect(selected, updated.withDatabasePrecision);
    },
  );
}
