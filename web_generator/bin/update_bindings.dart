// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:args/args.dart';
import 'package:io/ansi.dart' as ansi;
import 'package:io/io.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

void main(List<String> arguments) async {
  final ArgResults argResult;

  try {
    argResult = _parser.parse(arguments);
  } on FormatException catch (e) {
    print('''
${ansi.lightRed.wrap(e.message)}

$_usage''');
    exitCode = ExitCode.usage.code;
    return;
  }

  if (argResult['help'] as bool) {
    print(_usage);
    return;
  }

  assert(p.fromUri(Platform.script).endsWith(_thisScript.toFilePath()));

  // Run `npm install` or `npm update` as needed.
  final update = argResult['update'] as bool;
  await _runProc(
    'npm',
    [update ? 'update' : 'install'],
    workingDirectory: _bindingsGeneratorPath,
  );

  // Compute JS type supertypes for union calculation in translator.
  await _generateJsTypeSupertypes();

  if (argResult['compile'] as bool) {
    final webPkgLangVersion = await _webPackageLanguageVersion(_webPackagePath);
    // Compile Dart to Javascript.
    await _runProc(
      Platform.executable,
      [
        'compile',
        'js',
        '--enable-asserts',
        '--server-mode',
        '-DlanguageVersion=$webPkgLangVersion',
        'dart_main.dart',
        '-o',
        'dart_main.js',
      ],
      workingDirectory: _bindingsGeneratorPath,
    );
  }

  // Determine the set of previously generated files.
  final domDir = Directory(p.join(_webPackagePath, 'lib', 'src', 'dom'));
  final existingFiles =
      domDir.listSync(recursive: true).whereType<File>().where((file) {
    if (!file.path.endsWith('.dart')) return false;

    final contents = file.readAsStringSync();
    return contents.contains('Generated from Web IDL definitions');
  }).toList();
  final timeStamps = {
    for (final file in existingFiles) file.path: file.lastModifiedSync(),
  };

  // Run app with `node`.
  final generateAll = argResult['generate-all'] as bool;
  await _runProc(
    'node',
    [
      'main.mjs',
      '--output-directory=${p.join(_webPackagePath, 'lib', 'src')}',
      if (generateAll) '--generate-all',
    ],
    workingDirectory: _bindingsGeneratorPath,
  );

  // Delete previously generated files that have not been updated.
  for (final file in existingFiles) {
    final stamp = timeStamps[file.path];
    if (stamp == file.lastModifiedSync()) {
      file.deleteSync();
    }
  }

  // Update readme.
  final readmeFile =
      File(p.normalize(p.fromUri(Platform.script.resolve('../README.md'))));

  final sourceContent = readmeFile.readAsStringSync();

  final cssVersion = _packageLockVersion(_webRefCss);
  final elementsVersion = _packageLockVersion(_webRefElements);
  final idlVersion = _packageLockVersion(_webRefIdl);
  final versions = '''
$_startComment
| Item | Version |
| --- | --: |
| `$_webRefCss` | [$cssVersion](https://www.npmjs.com/package/$_webRefCss/v/$cssVersion) |
| `$_webRefElements` | [$elementsVersion](https://www.npmjs.com/package/$_webRefElements/v/$elementsVersion) |
| `$_webRefIdl` | [$idlVersion](https://www.npmjs.com/package/$_webRefIdl/v/$idlVersion) |
''';

  final newContent =
      sourceContent.substring(0, sourceContent.indexOf(_startComment)) +
          versions +
          sourceContent.substring(sourceContent.indexOf(_endComment));
  if (newContent == sourceContent) {
    print(ansi.styleBold.wrap('No update for readme.'));
  } else {
    print(ansi.styleBold.wrap('Updating readme for IDL version $idlVersion'));
    readmeFile.writeAsStringSync(newContent, mode: FileMode.writeOnly);
  }
}

Future<String> _webPackageLanguageVersion(String pkgPath) async {
  final packageConfig = await findPackageConfig(Directory(pkgPath));
  if (packageConfig == null) {
    throw StateError('No package config for "$pkgPath"');
  }
  final package =
      packageConfig.packageOf(Uri.file(p.join(pkgPath, 'pubspec.yaml')));
  if (package == null) {
    throw StateError('No package at "$pkgPath"');
  }
  final languageVersion = package.languageVersion;
  if (languageVersion == null) {
    throw StateError('No language version "$pkgPath"');
  }
  return '$languageVersion.0';
}

final _webPackagePath = p.fromUri(Platform.script.resolve('../../web'));

String _packageLockVersion(String package) {
  final packageLockData = jsonDecode(
    File(p.join(_bindingsGeneratorPath, 'package-lock.json'))
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  final packages = packageLockData['packages'] as Map<String, dynamic>;
  final webRefIdl = packages['node_modules/$package'] as Map<String, dynamic>;
  return webRefIdl['version'] as String;
}

final _bindingsGeneratorPath = p.fromUri(Platform.script.resolve('../lib/src'));

const _webRefCss = '@webref/css';
const _webRefElements = '@webref/elements';
const _webRefIdl = '@webref/idl';

final _thisScript = Uri.parse('bin/update_bindings.dart');
final _scriptPOSIXPath = _thisScript.toFilePath(windows: false);

final _startComment =
    '<!-- START updated by $_scriptPOSIXPath. Do not modify by hand -->';
final _endComment =
    '<!-- END updated by $_scriptPOSIXPath. Do not modify by hand -->';

Future<void> _runProc(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  print(ansi.styleBold.wrap(['*', executable, ...arguments].join(' ')));
  final proc = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
    workingDirectory: workingDirectory,
  );
  final procExit = await proc.exitCode;
  if (procExit != 0) {
    throw ProcessException(executable, arguments, 'Process failed', procExit);
  }
}

// Generates a map of the JS type hierarchy defined in `dart:js_interop` that is
// used by the translator to handle IDL types.
Future<void> _generateJsTypeSupertypes() async {
  // Use a file that uses `dart:js_interop` for analysis.
  final contextCollection = AnalysisContextCollection(
      includedPaths: [p.join(_webPackagePath, 'lib', 'src', 'dom.dart')]);
  final dartJsInterop = (await contextCollection.contexts.single.currentSession
          .getLibraryByUri('dart:js_interop') as LibraryElementResult)
      .element2;
  final definedNames = dartJsInterop.exportNamespace.definedNames2;
  // `SplayTreeMap` to avoid moving types around in `dart:js_interop` affecting
  // the code generation.
  final jsTypeSupertypes = SplayTreeMap<String, String?>();
  for (final name in definedNames.keys) {
    final element = definedNames[name];
    if (element is ExtensionTypeElement2) {
      // JS types are any extension type that starts with 'JS' in
      // `dart:js_interop`.
      bool isJSType(InterfaceElement2 element) =>
          element is ExtensionTypeElement2 &&
          element.library2 == dartJsInterop &&
          element.name3!.startsWith('JS');
      if (!isJSType(element)) continue;

      String? parentJsType;
      final supertype = element.supertype;
      final immediateSupertypes = <InterfaceType>[
        if (supertype != null) supertype,
        ...element.interfaces,
      ]..removeWhere((supertype) => supertype.isDartCoreObject);
      // We should have at most one non-trivial supertype.
      assert(immediateSupertypes.length <= 1);
      for (final supertype in immediateSupertypes) {
        if (isJSType(supertype.element3)) {
          parentJsType = "'${supertype.element3.name3!}'";
        }
      }
      // Ensure that the hierarchy forms a tree.
      assert((parentJsType == null) == (name == 'JSAny'));
      jsTypeSupertypes["'$name'"] = parentJsType;
    }
  }

  final jsTypeSupertypesScript = '''
// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Updated by $_scriptPOSIXPath. Do not modify by hand.

const Map<String, String?> jsTypeSupertypes = {
${jsTypeSupertypes.entries.map((e) => "  ${e.key}: ${e.value},").join('\n')}
};
''';
  final jsTypeSupertypesPath =
      p.join(_bindingsGeneratorPath, 'js_type_supertypes.dart');
  await File(jsTypeSupertypesPath).writeAsString(jsTypeSupertypesScript);
}

final _usage = '''
Usage:
${_parser.usage}''';

final _parser = ArgParser()
  ..addFlag('update', abbr: 'u', help: 'Update npm dependencies')
  ..addFlag('compile', defaultsTo: true)
  ..addFlag('help', negatable: false)
  ..addFlag('generate-all',
      negatable: false,
      help: 'Generate bindings for all IDL definitions, including experimental '
          'and non-standard APIs.');
