import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/device/internal/embedded_extension.dart';
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';

IosAppExtension _extension({
  String name = 'Share Extension',
  String bundleId = 'com.example.App.Share-Extension',
  List<String> sources = const [
    '/ios/Share Extension/ShareViewController.swift',
  ],
  List<String> resources = const [],
  List<String> appGroups = const [],
}) => IosAppExtension(
  name: name,
  bundleId: bundleId,
  infoPlistPath: null,
  sources: sources,
  resources: resources,
  entitlementsPath: null,
  swiftVersion: '5.0',
  deploymentTarget: null,
  appGroups: appGroups,
);

void main() {
  group('compileArguments', () {
    List<String> argumentsWith({
      String? pluginsLibrary,
      String? pluginModulesDir,
    }) => AppExtensionBuilder.compileArguments(
      iosSdk: '/sdk/iPhoneOS.sdk',
      resourceDir: '/sdk/toolchain/usr/lib/swift',
      sources: const ['/ios/Share Extension/ShareViewController.swift'],
      outputPath: '/out/Share Extension.appex/Share Extension',
      deploymentTarget: const IosDeploymentTarget('15.0'),
      flutterSlice: '/engine/Flutter.xcframework/ios-arm64',
      moduleCache: '/out/.module-cache',
      ld64lld: '/usr/bin/ld64.lld',
      sdkVersion: '26.5',
      pluginsLibrary: pluginsLibrary,
      pluginModulesDir: pluginModulesDir,
    );

    test('marks the binary as app-extension safe', () {
      final arguments = argumentsWith();

      expect(arguments, contains('-application-extension'));
      expect(
        arguments,
        containsAllInOrder(['-Xcc', '-fapplication-extension']),
      );
    });

    test('entry point is _NSExtensionMain, not main', () {
      expect(
        argumentsWith(),
        containsAllInOrder(['-e', '-Xlinker', '_NSExtensionMain']),
      );
    });

    test('rpath reaches the host app Frameworks two levels up', () {
      expect(
        argumentsWith(),
        containsAllInOrder([
          '-rpath',
          '-Xlinker',
          '@executable_path/../../Frameworks',
        ]),
      );
    });

    test('uses the Darwin SDK Swift resources, not the host toolchain', () {
      expect(
        argumentsWith(),
        containsAllInOrder(['-resource-dir', '/sdk/toolchain/usr/lib/swift']),
      );
    });

    test('links and imports the plugins library when present', () {
      final arguments = argumentsWith(
        pluginsLibrary: '/build/libFlutterPluginsGenerated.dylib',
        pluginModulesDir: '/build/Modules',
      );

      expect(arguments, containsAllInOrder(['-I', '/build/Modules']));
      expect(
        arguments,
        containsAllInOrder([
          '-Xlinker',
          '/build/libFlutterPluginsGenerated.dylib',
        ]),
      );
    });

    test('omits plugin flags for a project without plugins', () {
      final arguments = argumentsWith();

      expect(arguments, isNot(contains('-I')));
      expect(arguments.where((a) => a.endsWith('.dylib')), isEmpty);
    });

    test(
      'passes -arch and -platform_version explicitly for non-Apple clang',
      () {
        expect(
          argumentsWith(),
          containsAllInOrder([
            '-arch',
            '-Xlinker',
            'arm64',
            '-Xlinker',
            '-platform_version',
            '-Xlinker',
            'ios',
            '-Xlinker',
            '15.0',
            '-Xlinker',
            '26.5',
          ]),
        );
      },
    );
  });

  group('expandExtensionVars', () {
    test('substitutes the app group into CUSTOM_GROUP_ID', () {
      final xml = AppExtensionBuilder.expandExtensionVars(
        r'<key>AppGroupId</key><string>$(CUSTOM_GROUP_ID)</string>',
        extension: _extension(appGroups: const ['group.com.example.Shared']),
      );

      expect(xml, contains('<string>group.com.example.Shared</string>'));
    });

    test('substitutes the bundle identifier', () {
      final xml = AppExtensionBuilder.expandExtensionVars(
        r'<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>',
        extension: _extension(),
      );

      expect(xml, contains('com.example.App.Share-Extension'));
    });

    test('leaves CUSTOM_GROUP_ID alone when no app group is declared', () {
      const source = r'<string>$(CUSTOM_GROUP_ID)</string>';

      expect(
        AppExtensionBuilder.expandExtensionVars(
          source,
          extension: _extension(),
        ),
        source,
      );
    });
  });

  group('replaceStoryboardWithPrincipalClass', () {
    test('swaps the storyboard for the module-qualified principal class', () {
      final xml = AppExtensionBuilder.replaceStoryboardWithPrincipalClass(
        '<dict>\n'
        '\t\t<key>NSExtensionMainStoryboard</key>\n'
        '\t\t<string>MainInterface</string>\n'
        '</dict>',
        extension: _extension(),
      );

      expect(xml, isNot(contains('NSExtensionMainStoryboard')));
      expect(xml, contains('<key>NSExtensionPrincipalClass</key>'));
      expect(
        xml,
        contains('<string>Share_Extension.ShareViewController</string>'),
      );
    });

    test('leaves a plist that already names a principal class', () {
      const source =
          '<dict><key>NSExtensionPrincipalClass</key>'
          '<string>Custom.Controller</string></dict>';

      expect(
        AppExtensionBuilder.replaceStoryboardWithPrincipalClass(
          source,
          extension: _extension(),
        ),
        source,
      );
    });

    test('keeps the storyboard key when no controller class can be found', () {
      const source =
          '<dict><key>NSExtensionMainStoryboard</key>'
          '<string>MainInterface</string></dict>';

      expect(
        AppExtensionBuilder.replaceStoryboardWithPrincipalClass(
          source,
          extension: _extension(sources: const ['/ios/Helpers.swift']),
        ),
        source,
      );
    });
  });

  group('buildAll', () {
    test('skips a non-Swift extension instead of failing the app', () async {
      // An Objective-C extension target must not sink the whole app build.
      final built = await AppExtensionBuilder.buildAll(
        projectRoot: '/project',
        extensions: [
          _extension(sources: const ['/ios/Share Extension/View.m']),
        ],
        deploymentTarget: const IosDeploymentTarget('15.0'),
        outputDir: '/out',
        flutterXcframework: '/engine/Flutter.xcframework',
        versions: IosBundleVersions.fallback,
      );

      expect(built, isEmpty);
    });

    test('does nothing for a project with no extensions', () async {
      expect(
        await AppExtensionBuilder.buildAll(
          projectRoot: '/project',
          extensions: const [],
          deploymentTarget: const IosDeploymentTarget('15.0'),
          outputDir: '/out',
          flutterXcframework: '/engine/Flutter.xcframework',
          versions: IosBundleVersions.fallback,
        ),
        isEmpty,
      );
    });
  });

  group('AppExtensionPlist.setAppGroups', () {
    test('round-trips app groups through a built appex Info.plist', () async {
      final xml = AppExtensionPlist.setAppGroups('<dict>\n</dict>', const [
        'group.com.example.Shared',
        'group.com.example.Other',
      ]);

      final dir = await Directory.systemTemp.createTemp('xcross_appex_groups-');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'Info.plist')).writeAsString(xml);

      // The sign/install stage recovers the groups without the Xcode project.
      expect(AppExtensionEntitlements.appGroupsOf(dir.path), [
        'group.com.example.Shared',
        'group.com.example.Other',
      ]);
    });

    test('leaves the plist untouched when there are no groups', () {
      const source = '<dict>\n</dict>';

      expect(AppExtensionPlist.setAppGroups(source, const []), source);
    });

    test('replaces a previous group list instead of appending', () {
      final once = AppExtensionPlist.setAppGroups('<dict>\n</dict>', const [
        'group.old',
      ]);
      final twice = AppExtensionPlist.setAppGroups(once, const ['group.new']);

      expect(twice, isNot(contains('group.old')));
      expect(twice, contains('group.new'));
    });
  });

  group('AppExtensionPlist.forceKeys', () {
    String forced(String xml) => AppExtensionPlist.forceKeys(
      xml,
      bundleId: 'com.example.App.Share-Extension',
      executableName: 'Share Extension',
      bundleName: 'Share Extension',
      minimumOsVersion: '15.0',
      versions: const IosBundleVersions(
        shortVersion: '2.4.1',
        bundleVersion: '37',
      ),
    );

    test('sets the identity keys installd validates', () {
      final xml = forced('<dict>\n</dict>');

      expect(xml, contains('<string>com.example.App.Share-Extension</string>'));
      expect(xml, contains('<key>CFBundleExecutable</key>'));
      // installd rejects an appex with no display name.
      expect(xml, contains('<key>CFBundleDisplayName</key>'));
      expect(xml, contains('<string>XPC!</string>'));
      expect(xml, contains('<key>MinimumOSVersion</key>'));
    });

    test('versions match the host app instead of being hardcoded', () {
      // iOS refuses an extension whose versions differ from its host app's.
      final xml = forced('<dict>\n</dict>');

      expect(xml, contains('<string>2.4.1</string>'));
      expect(xml, contains('<string>37</string>'));
      expect(xml, isNot(contains('<string>1.0.0</string>')));
    });

    test('overwrites an existing value instead of duplicating the key', () {
      final xml = forced(
        '<dict><key>CFBundleIdentifier</key><string>stale</string></dict>',
      );

      expect(xml, isNot(contains('stale')));
      expect(RegExp('<key>CFBundleIdentifier</key>').allMatches(xml).length, 1);
    });
  });

  group('copyResources', () {
    late Directory tmp;
    late Directory bundle;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xcross_copy_resources-');
      bundle = Directory(p.join(tmp.path, 'Share Extension.appex'));
      await bundle.create(recursive: true);
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<String> writeResource(String relative, String contents) async {
      final file = File(p.join(tmp.path, 'src', relative));
      await file.parent.create(recursive: true);
      await file.writeAsString(contents);
      return file.path;
    }

    test('keeps localized resources inside their .lproj directory', () async {
      final english = await writeResource(
        p.join('en.lproj', 'Localizable.strings'),
        '"key" = "english";',
      );
      final german = await writeResource(
        p.join('de.lproj', 'Localizable.strings'),
        '"key" = "german";',
      );

      await AppExtensionBuilder.copyResources(
        extension: _extension(resources: [english, german]),
        bundleDir: bundle.path,
      );

      // Flattening onto the bundle root would make one language overwrite the
      // other, and iOS would find no localization at all.
      expect(
        File(
          p.join(bundle.path, 'en.lproj', 'Localizable.strings'),
        ).readAsStringSync(),
        '"key" = "english";',
      );
      expect(
        File(
          p.join(bundle.path, 'de.lproj', 'Localizable.strings'),
        ).readAsStringSync(),
        '"key" = "german";',
      );
    });

    test('copies unlocalized resources to the bundle root', () async {
      final resource = await writeResource('config.json', '{}');

      await AppExtensionBuilder.copyResources(
        extension: _extension(resources: [resource]),
        bundleDir: bundle.path,
      );

      expect(File(p.join(bundle.path, 'config.json')).existsSync(), isTrue);
    });

    test('places a compiled storyboard next to its localization', () async {
      final storyboard = await writeResource(
        p.join('Base.lproj', 'MainInterface.storyboard'),
        '<document/>',
      );
      final compiled = Directory(
        p.join(p.dirname(storyboard), 'MainInterface.storyboardc'),
      );
      await compiled.create(recursive: true);
      await File(p.join(compiled.path, 'Info.plist')).writeAsString('<plist/>');

      await AppExtensionBuilder.copyResources(
        extension: _extension(resources: [storyboard]),
        bundleDir: bundle.path,
      );

      expect(
        File(
          p.join(
            bundle.path,
            'Base.lproj',
            'MainInterface.storyboardc',
            'Info.plist',
          ),
        ).existsSync(),
        isTrue,
      );
    });

    test('skips an uncompiled storyboard rather than shipping it', () async {
      final storyboard = await writeResource(
        'MainInterface.storyboard',
        '<document/>',
      );

      await AppExtensionBuilder.copyResources(
        extension: _extension(resources: [storyboard]),
        bundleDir: bundle.path,
      );

      expect(
        File(p.join(bundle.path, 'MainInterface.storyboard')).existsSync(),
        isFalse,
      );
    });
  });
}
