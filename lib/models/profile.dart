// ignore_for_file: invalid_annotation_target
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluxora/clash/core.dart';
import 'package:fluxora/common/archive.dart'
    show profileFilesLock, replaceDataFiles;
import 'package:fluxora/common/common.dart';
import 'package:fluxora/common/data_path.dart';
import 'package:fluxora/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'clash_config.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

typedef SelectedMap = Map<String, String>;

@freezed
abstract class SubscriptionInfo with _$SubscriptionInfo {
  const factory SubscriptionInfo({
    @Default(0) int upload,
    @Default(0) int download,
    @Default(0) int total,
    @Default(0) int expire,
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final map = <String, int>{};
    for (final field in info.split(';')) {
      final separator = field.indexOf('=');
      if (separator < 1) continue;
      final value = int.tryParse(field.substring(separator + 1).trim());
      if (value != null) map[field.substring(0, separator).trim()] = value;
    }
    return SubscriptionInfo(
      upload: map['upload'] ?? 0,
      download: map['download'] ?? 0,
      total: map['total'] ?? 0,
      expire: map['expire'] ?? 0,
    );
  }
}

extension SubscriptionInfoExtension on SubscriptionInfo {
  String? get expireDesc {
    if (expire > 0) {
      final expireDate =
          DateTime.fromMillisecondsSinceEpoch(expire * 1000).show;
      final isExpired =
          expire * 1000 < DateTime.now().millisecondsSinceEpoch;
      return isExpired
          ? '${appLocalizations.expired} · $expireDate'
          : expireDate;
    }
    return total > 0 ? appLocalizations.infiniteTime : null;
  }
}

enum ProfilePortalSource { unset, subscription, manual }

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required String id,
    String? label,
    String? currentGroupName,
    @Default('') String url,
    @Default('') String portalUrl,
    @Default('') String portalLabel,
    @Default(ProfilePortalSource.unset) ProfilePortalSource portalSource,
    DateTime? lastUpdateDate,
    required Duration autoUpdateDuration,
    SubscriptionInfo? subscriptionInfo,
    @Default(true) bool autoUpdate,
    @Default({}) SelectedMap selectedMap,
    @Default({}) Set<String> unfoldSet,
    @Default(OverrideData()) OverrideData overrideData,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool isUpdating,
    @Default(true) bool useScriptOverride,
    String? scriptId,
    String? ageSecretKey,
    @JsonKey(name: 'group-switches') @Default({}) Map<String, bool> groupSwitches,

    /// 是否参与多订阅聚合。
    ///
    /// 打开后这个订阅会作为一个 `proxy-providers` 条目注入运行配置，节点出现在
    /// 「聚合节点」组里。聚合由内核完成，我们只负责把 provider 写进 YAML。
    @Default(false) bool joinAggregate,

    /// 聚合时的节点名前缀，留空则用 label。
    @Default('') String aggregateAlias,
  }) = _Profile;

  factory Profile.fromJson(Map<String, Object?> json) =>
      _$ProfileFromJson(json);

  factory Profile.normal({String? label, String url = '', String? ageSecretKey}) {
    return Profile(
      label: label,
      url: url,
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      autoUpdateDuration: defaultUpdateDuration,
      ageSecretKey: ageSecretKey,
    );
  }
}

@freezed
abstract class OverrideData with _$OverrideData {
  const factory OverrideData({
    @Default(false) bool enable,
    @Default(OverrideRule()) OverrideRule rule,
  }) = _OverrideData;

  factory OverrideData.fromJson(Map<String, Object?> json) =>
      _$OverrideDataFromJson(json);
}

extension OverrideDataExt on OverrideData {
  List<String> get runningRule {
    if (!enable) {
      return [];
    }
    return rule.rules.map((item) => item.value).toList();
  }
}

@freezed
abstract class OverrideRule with _$OverrideRule {
  const factory OverrideRule({
    @Default(OverrideRuleType.override) OverrideRuleType type,
    @Default([]) List<Rule> overrideRules,
    @Default([]) List<Rule> addedRules,
  }) = _OverrideRule;

  factory OverrideRule.fromJson(Map<String, Object?> json) =>
      _$OverrideRuleFromJson(json);
}

extension OverrideRuleExt on OverrideRule {
  List<Rule> get rules => switch (type == OverrideRuleType.override) {
    true => overrideRules,
    false => addedRules,
  };

  OverrideRule updateRules(List<Rule> Function(List<Rule> rules) builder) {
    if (type == OverrideRuleType.added) {
      return copyWith(addedRules: builder(addedRules));
    }
    return copyWith(overrideRules: builder(overrideRules));
  }
}

extension ProfilesExt on List<Profile> {
  Profile? getProfile(String? profileId) {
    final index = indexWhere((profile) => profile.id == profileId);
    return index == -1 ? null : this[index];
  }
}

extension ProfileExtension on Profile {
  ProfileType get type =>
      url.isEmpty == true ? ProfileType.file : ProfileType.url;

  bool get realAutoUpdate => url.isEmpty == true ? false : autoUpdate;

  bool isUpdateDue(DateTime now) =>
      realAutoUpdate &&
      !isUpdating &&
      (lastUpdateDate == null ||
          !now.isBefore(lastUpdateDate!.add(autoUpdateDuration)));

  /// Applies an optional `profile-web-page-url` response header.
  ///
  /// A manual value (including an explicitly cleared one) always wins; an
  /// invalid header never erases an existing subscription link.
  Profile withSubscriptionPortalHeader(String? header) {
    final normalized = header?.trim() ?? '';
    final adopt =
        portalSource != ProfilePortalSource.manual &&
        normalized.isSafeWebUrl;
    if (!adopt) return this;
    return copyWith(
      portalUrl: normalized,
      portalSource: ProfilePortalSource.subscription,
    );
  }

  Future<bool> check() async {
    final profilePath = await appPath.getProfilePath(id);
    return await File(profilePath).exists();
  }

  Future<File> getFile() async {
    final path = await appPath.getProfilePath(id);
    final file = File(path);
    final isExists = await file.exists();
    if (!isExists) {
      await file.create(recursive: true);
    }
    return file;
  }

  Future<int> get profileLastModified async {
    final file = await getFile();
    return (await file.lastModified()).microsecondsSinceEpoch;
  }

  Future<Profile> update({
    bool Function()? canCommit,
    Future<String> Function(String)? mergeManualNodes,
  }) async {
    final response = await request.getFileResponseForUrl(url);
    if (canCommit?.call() == false) return this;
    final disposition = response.headers['content-disposition']?.firstOrNull;
    final userinfo = response.headers['subscription-userinfo']?.firstOrNull;
    final portalHeader = response.headers['profile-web-page-url']?.firstOrNull
        ?.trim();
    final updated = withSubscriptionPortalHeader(portalHeader).copyWith(
      label: label ?? utils.getFileNameForDisposition(disposition) ?? id,
      subscriptionInfo: SubscriptionInfo.formHString(userinfo),
    );
    var content = await _validatedContent(utf8.decode(response.data));
    return profileFilesLock.synchronized(() async {
      if (canCommit?.call() == false) return this;
      if (mergeManualNodes != null) {
        final merged = await mergeManualNodes(content);
        if (merged != content) content = await _validatedContent(merged);
      }
      return updated._writeContent(content, canCommit: canCommit);
    });
  }

  Future<Profile> saveFile(
    Uint8List bytes, {
    bool Function()? canCommit,
  }) async {
    final content = await _validatedContent(utf8.decode(bytes));
    return profileFilesLock.synchronized(
      () => _writeContent(content, canCommit: canCommit),
    );
  }

  Future<Profile> saveFileWithString(
    String value, {
    List<Map<String, dynamic>>? manualNodes,
  }) async {
    final content = await _validatedContent(value);
    return profileFilesLock.synchronized(() async {
      if (manualNodes == null) return _writeContent(content);
      checkedDataPathSegment(id);
      await replaceDataFiles(await appPath.homeDirPath, [
        MapEntry('$profilesDirectoryName/$id.yaml', utf8.encode(content)),
        MapEntry('manual_proxies_$id.json', utf8.encode(jsonEncode(manualNodes))),
      ]);
      return copyWith(lastUpdateDate: DateTime.now());
    });
  }

  Future<String> _validatedContent(String content) async {
    if (content.trim().isEmpty) {
      throw const FormatException('Subscription is empty');
    }
    final key = ageSecretKey;
    if (key != null && key.isNotEmpty) {
      try {
        final decrypted = await clashCore.decryptAgeConfig(content, key);
        if (decrypted.isNotEmpty) {
          content = decrypted;
        }
      } catch (_) {}
    }
    content = utils.patchYamlConfig(content);
    final message = await clashCore.validateConfig(
      content,
      ageSecretKey: ageSecretKey,
    );
    if (message.isEmpty) return content;
    final patched = utils.patchValidateConfig(content);
    if (patched != content &&
        (await clashCore.validateConfig(
          patched,
          ageSecretKey: ageSecretKey,
        )).isEmpty) {
      return patched;
    }
    throw message;
  }

  Future<Profile> _writeContent(
    String content, {
    bool Function()? canCommit,
  }) async {
    final path = await appPath.getProfilePath(id);
    final temporary = File('$path.${utils.uuidV4}.tmp');
    await temporary.parent.create(recursive: true);
    var published = false;
    try {
      await temporary.writeAsString(content, flush: true);
      // Keep the final stale-request check and the rename in one isolate turn.
      if (canCommit?.call() == false) return this;
      temporary.renameSync(path);
      published = true;
      return copyWith(lastUpdateDate: DateTime.now());
    } finally {
      if (!published && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}
