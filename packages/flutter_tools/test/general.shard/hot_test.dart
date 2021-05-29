// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'package:file/memory.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/compile.dart';
import 'package:flutter_tools/src/devfs.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/resident_devtools_handler.dart';
import 'package:flutter_tools/src/resident_runner.dart';
import 'package:flutter_tools/src/run_hot.dart';
import 'package:flutter_tools/src/vmservice.dart';
import 'package:meta/meta.dart';
import 'package:test/fake.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_vm_services.dart';

final vm_service.Isolate fakeUnpausedIsolate = vm_service.Isolate(
  id: '1',
  pauseEvent: vm_service.Event(
    kind: vm_service.EventKind.kResume,
    timestamp: 0
  ),
  breakpoints: <vm_service.Breakpoint>[],
  exceptionPauseMode: null,
  libraries: <vm_service.LibraryRef>[],
  livePorts: 0,
  name: 'test',
  number: '1',
  pauseOnExit: false,
  runnable: true,
  startTime: 0,
  isSystemIsolate: false,
  isolateFlags: <vm_service.IsolateFlag>[],
);

final FlutterView fakeFlutterView = FlutterView(
  id: 'a',
  uiIsolate: fakeUnpausedIsolate,
);

final FakeVmServiceRequest listViews = FakeVmServiceRequest(
  method: kListViewsMethod,
  jsonResponse: <String, Object>{
    'views': <Object>[
      fakeFlutterView.toJson(),
    ],
  },
);

void main() {
  group('validateReloadReport', () {
    testUsingContext('invalid', () async {
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{},
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <Map<String, dynamic>>[
          ],
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <String, dynamic>{
            'message': 'error',
          },
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <Map<String, dynamic>>[],
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <Map<String, dynamic>>[
            <String, dynamic>{'message': false},
          ],
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <Map<String, dynamic>>[
            <String, dynamic>{'message': <String>['error']},
          ],
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <Map<String, dynamic>>[
            <String, dynamic>{'message': 'error'},
            <String, dynamic>{'message': <String>['error']},
          ],
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': false,
        'details': <String, dynamic>{
          'notices': <Map<String, dynamic>>[
            <String, dynamic>{'message': 'error'},
          ],
        },
      })), false);
      expect(HotRunner.validateReloadReport(vm_service.ReloadReport.parse(<String, dynamic>{
        'type': 'ReloadReport',
        'success': true,
      })), true);
    });

    testWithoutContext('ReasonForCancelling toString has a hint for specific errors', () {
      final ReasonForCancelling reasonForCancelling = ReasonForCancelling(
        message: 'Const class cannot remove fields',
      );

      expect(reasonForCancelling.toString(), contains('Try performing a hot restart instead.'));
    });
  });

  group('hotRestart', () {
    final FakeResidentCompiler residentCompiler = FakeResidentCompiler();
    FileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    testUsingContext('setup function fails', () async {
      fileSystem.file('.packages')
        ..createSync(recursive: true)
        ..writeAsStringSync('\n');
      final FakeDevice device = FakeDevice();
      final List<FlutterDevice> devices = <FlutterDevice>[
        FlutterDevice(device, generator: residentCompiler, buildInfo: BuildInfo.debug)..devFS = FakeDevFs(),
      ];
      final OperationResult result = await HotRunner(
        devices,
        debuggingOptions: DebuggingOptions.disabled(BuildInfo.debug),
        target: 'main.dart',
        devtoolsHandler: createNoOpHandler,
      ).restart(fullRestart: true);
      expect(result.isOk, false);
      expect(result.message, 'setupHotRestart failed');
    }, overrides: <Type, Generator>{
      HotRunnerConfig: () => TestHotRunnerConfig(successfulSetup: false),
      Artifacts: () => Artifacts.test(),
      FileSystem: () => fileSystem,
      Platform: () => FakePlatform(operatingSystem: 'linux'),
      ProcessManager: () => FakeProcessManager.any(),
    });

    group('shutdown hook tests', () {
      TestHotRunnerConfig shutdownTestingConfig;

      setUp(() {
        shutdownTestingConfig = TestHotRunnerConfig(
          successfulSetup: true,
        );
      });

      testUsingContext('shutdown hook called after signal', () async {
        fileSystem.file('.packages')
          ..createSync(recursive: true)
          ..writeAsStringSync('\n');
        final FakeDevice device = FakeDevice();
        final List<FlutterDevice> devices = <FlutterDevice>[
          FlutterDevice(device, generator: residentCompiler, buildInfo: BuildInfo.debug),
        ];
        await HotRunner(
          devices,
          debuggingOptions: DebuggingOptions.disabled(BuildInfo.debug),
          target: 'main.dart',
        ).cleanupAfterSignal();
        expect(shutdownTestingConfig.shutdownHookCalled, true);
      }, overrides: <Type, Generator>{
        HotRunnerConfig: () => shutdownTestingConfig,
        Artifacts: () => Artifacts.test(),
        FileSystem: () => fileSystem,
        Platform: () => FakePlatform(operatingSystem: 'linux'),
        ProcessManager: () => FakeProcessManager.any(),
      });

      testUsingContext('shutdown hook called after app stop', () async {
        fileSystem.file('.packages')
          ..createSync(recursive: true)
          ..writeAsStringSync('\n');
        final FakeDevice device = FakeDevice();
        final List<FlutterDevice> devices = <FlutterDevice>[
          FlutterDevice(device, generator: residentCompiler, buildInfo: BuildInfo.debug),
        ];
        await HotRunner(
          devices,
          debuggingOptions: DebuggingOptions.disabled(BuildInfo.debug),
          target: 'main.dart',
        ).preExit();
        expect(shutdownTestingConfig.shutdownHookCalled, true);
      }, overrides: <Type, Generator>{
        HotRunnerConfig: () => shutdownTestingConfig,
        Artifacts: () => Artifacts.test(),
        FileSystem: () => fileSystem,
        Platform: () => FakePlatform(operatingSystem: 'linux'),
        ProcessManager: () => FakeProcessManager.any(),
      });
    });
  });

  group('hot attach', () {
    FileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    testUsingContext('Exits with code 2 when HttpException is thrown '
      'during VM service connection', () async {
      fileSystem.file('.packages')
        ..createSync(recursive: true)
        ..writeAsStringSync('\n');

      final FakeResidentCompiler residentCompiler = FakeResidentCompiler();
      final FakeDevice device = FakeDevice();
      final List<FlutterDevice> devices = <FlutterDevice>[
        TestFlutterDevice(
          device: device,
          generator: residentCompiler,
          exception: const HttpException('Connection closed before full header was received, '
              'uri = http://127.0.0.1:63394/5ZmLv8A59xY=/ws'),
        ),
      ];

      final int exitCode = await HotRunner(devices,
        debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
        target: 'main.dart',
      ).attach(
        enableDevTools: false,
      );
      expect(exitCode, 2);
    }, overrides: <Type, Generator>{
      HotRunnerConfig: () => TestHotRunnerConfig(successfulSetup: true),
      Artifacts: () => Artifacts.test(),
      FileSystem: () => fileSystem,
      Platform: () => FakePlatform(operatingSystem: 'linux'),
      ProcessManager: () => FakeProcessManager.any(),
    });
  });

  group('hot cleanupAtFinish()', () {
    testUsingContext('disposes each device', () async {
      final FakeDevice device1 = FakeDevice();
      final FakeDevice device2 = FakeDevice();
      final FakeFlutterDevice flutterDevice1 = FakeFlutterDevice(device1);
      final FakeFlutterDevice flutterDevice2 = FakeFlutterDevice(device2);

      final List<FlutterDevice> devices = <FlutterDevice>[
        flutterDevice1,
        flutterDevice2,
      ];

      await HotRunner(devices,
        debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
        target: 'main.dart',
      ).cleanupAtFinish();

      expect(device1.disposed, true);
      expect(device2.disposed, true);

      expect(flutterDevice1.stoppedEchoingDeviceLog, true);
      expect(flutterDevice2.stoppedEchoingDeviceLog, true);
    });
  });
}

class FakeDevFs extends Fake implements DevFS {
  @override
  Future<void> destroy() async { }
}

class FakeDevice extends Fake implements Device {
  bool disposed = false;

  @override
  bool isSupported() => true;

  @override
  bool supportsHotReload = true;

  @override
  bool supportsHotRestart = true;

  @override
  bool supportsFlutterExit = true;

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.tester;

  @override
  Future<String> get sdkNameAndVersion async => 'Tester';

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<bool> stopApp(
    covariant ApplicationPackage app, {
    String userIdentifier,
  }) async {
    return true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class FakeFlutterDevice extends Fake implements FlutterDevice {
  FakeFlutterDevice(this.device);

  bool stoppedEchoingDeviceLog = false;

  @override
  final FakeDevice device;

  @override
  Future<void> stopEchoingDeviceLog() async {
    stoppedEchoingDeviceLog = true;
  }

  @override
  DevFS devFS = FakeDevFs();
}

class TestFlutterDevice extends FlutterDevice {
  TestFlutterDevice({
    @required Device device,
    @required this.exception,
    @required ResidentCompiler generator,
  })  : assert(exception != null),
        super(device, buildInfo: BuildInfo.debug, generator: generator);

  /// The exception to throw when the connect method is called.
  final Exception exception;

  @override
  Future<void> connect({
    ReloadSources reloadSources,
    Restart restart,
    CompileExpression compileExpression,
    GetSkSLMethod getSkSLMethod,
    PrintStructuredErrorLogMethod printStructuredErrorLogMethod,
    bool disableServiceAuthCodes = false,
    bool enableDds = true,
    bool ipv6 = false,
    int hostVmServicePort,
    int ddsPort,
    bool allowExistingDdsInstance = false,
  }) async {
    throw exception;
  }
}

class TestHotRunnerConfig extends HotRunnerConfig {
  TestHotRunnerConfig({@required this.successfulSetup});
  bool successfulSetup;
  bool shutdownHookCalled = false;

  @override
  Future<bool> setupHotRestart() async {
    return successfulSetup;
  }

  @override
  Future<void> runPreShutdownOperations() async {
    shutdownHookCalled = true;
  }
}

class FakeResidentCompiler extends Fake implements ResidentCompiler {
  @override
  void accept() {}
}
