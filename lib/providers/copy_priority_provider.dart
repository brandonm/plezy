import 'package:flutter/foundation.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../services/storage_service.dart';

/// The profile's ranking of libraries (`serverId:libraryId` keys, best first)
/// used to pick which copy of a title plays. Stored per device.
class CopyPriorityProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  StorageService? _storageService;
  final String? profileId;
  String? _scopedProfileId;
  List<String> _priority = const [];
  late final Future<void> _initFuture;

  CopyPriorityProvider({this._storageService, this.profileId}) {
    // Start initialization eagerly to reduce race conditions
    _initFuture = _initialize();
  }

  /// Ensures the stored list has been loaded. Await before reading [priority]
  /// where the persisted value matters.
  Future<void> ensureInitialized() => _initFuture;

  List<String> get priority => _priority;

  Future<void> _initialize() async {
    final storage = _storageService ??= await StorageService.getInstance();
    // Without an explicit profile, fall back to the active one.
    final scopedProfileId = _scopedProfileId = profileId ?? storage.getActiveProfileId();
    if (scopedProfileId != null) _priority = storage.getCopyPriorityForProfile(scopedProfileId);
    safeNotifyListeners();
  }

  Future<void> setPriority(List<String> libraryKeys) async {
    await ensureInitialized();
    if (isDisposed) return;
    final scopedProfileId = _scopedProfileId;
    final next = List<String>.unmodifiable(libraryKeys);
    if (scopedProfileId != null) {
      await _storageService!.saveCopyPriorityForProfile(scopedProfileId, next);
    }
    if (isDisposed) return;
    _priority = next;
    safeNotifyListeners();
  }
}
