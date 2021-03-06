// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:file/record_replay.dart';
import 'package:file/testing.dart';
import 'package:file/src/backends/record_replay/common.dart';
import 'package:file/src/backends/record_replay/mutable_recording.dart';
import 'package:file/src/backends/record_replay/recording_proxy_mixin.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'common_tests.dart';

void main() {
  group('SupportingClasses', () {
    _BasicClass delegate;
    _RecordingClass rc;
    MutableRecording recording;

    setUp(() {
      delegate = new _BasicClass();
      rc = new _RecordingClass(
        delegate: delegate,
        stopwatch: new _FakeStopwatch(10),
        destination: new MemoryFileSystem().directory('/tmp')..createSync(),
      );
      recording = rc.recording;
    });

    group('InvocationEvent', () {
      test('recordsAllPropertyGetMetadata', () {
        delegate.basicProperty = 'foo';
        String value = rc.basicProperty;
        expect(recording.events, hasLength(1));
        expect(
            recording.events[0],
            getsProperty('basicProperty')
                .on(rc)
                .withResult(value)
                .withTimestamp(10));
      });

      test('recordsAllPropertySetMetadata', () {
        rc.basicProperty = 'foo';
        expect(recording.events, hasLength(1));
        expect(
            recording.events[0],
            setsProperty('basicProperty')
                .on(rc)
                .toValue('foo')
                .withTimestamp(10));
      });

      test('recordsAllMethodInvocationMetadata', () {
        String result = rc.basicMethod('foo', namedArg: 'bar');
        expect(recording.events, hasLength(1));
        expect(
            recording.events[0],
            invokesMethod('basicMethod')
                .on(rc)
                .withPositionalArguments(<String>['foo'])
                .withNamedArgument('namedArg', 'bar')
                .withResult(result)
                .withTimestamp(10));
      });

      test('resultIncompleteUntilFutureCompletes', () async {
        delegate.basicProperty = 'foo';
        rc.futureProperty; // ignore: unawaited_futures
        expect(recording.events, hasLength(1));
        expect(
            recording.events[0],
            getsProperty('futureProperty')
                .on(rc)
                .withResult(isNull)
                .withTimestamp(10));
        await recording.events[0].done;
        expect(
            recording.events[0],
            getsProperty('futureProperty')
                .on(rc)
                .withResult('future.foo')
                .withTimestamp(10));
      });

      test('resultIncompleteUntilStreamCompletes', () async {
        Stream<String> stream = rc.streamMethod('foo', namedArg: 'bar');
        stream.listen((_) {});
        expect(recording.events, hasLength(1));
        expect(
            recording.events[0],
            invokesMethod('streamMethod')
                .on(rc)
                .withPositionalArguments(<String>['foo'])
                .withNamedArgument('namedArg', 'bar')
                .withResult(allOf(isList, isEmpty))
                .withTimestamp(10));
        await recording.events[0].done;
        expect(
            recording.events[0],
            invokesMethod('streamMethod')
                .on(rc)
                .withPositionalArguments(<String>['foo'])
                .withNamedArgument('namedArg', 'bar')
                .withResult(<String>['stream', 'foo', 'bar'])
                .withTimestamp(10));
      });
    });

    group('MutableRecording', () {
      group('flush', () {
        test('writesManifestToFileSystemAsJson', () async {
          rc.basicProperty = 'foo';
          String value = rc.basicProperty;
          rc.basicMethod(value, namedArg: 'bar');
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(3));
          expect(manifest[0], <String, dynamic>{
            'type': 'set',
            'property': 'basicProperty=',
            'value': 'foo',
            'object': '_RecordingClass',
            'result': null,
            'timestamp': 10,
          });
          expect(manifest[1], <String, dynamic>{
            'type': 'get',
            'property': 'basicProperty',
            'object': '_RecordingClass',
            'result': 'foo',
            'timestamp': 11,
          });
          expect(manifest[2], <String, dynamic>{
            'type': 'invoke',
            'method': 'basicMethod',
            'positionalArguments': <String>['foo'],
            'namedArguments': <String, dynamic>{'namedArg': 'bar'},
            'object': '_RecordingClass',
            'result': 'foo.bar',
            'timestamp': 12
          });
        });

        test('doesntAwaitPendingResultsUnlessToldToDoSo', () async {
          rc.futureMethod('foo', namedArg: 'bar'); // ignore: unawaited_futures
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest[0], containsPair('result', null));
        });

        test('succeedsIfAwaitPendingResultsThatComplete', () async {
          rc.futureMethod('foo', namedArg: 'bar'); // ignore: unawaited_futures
          await recording.flush(
              awaitPendingResults: const Duration(seconds: 30));
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest[0], containsPair('result', 'future.foo.bar'));
        });

        test('succeedsIfAwaitPendingResultsThatTimeout', () async {
          rc.veryLongFutureMethod(); // ignore: unawaited_futures
          DateTime before = new DateTime.now();
          await recording.flush(
              awaitPendingResults: const Duration(milliseconds: 250));
          DateTime after = new DateTime.now();
          Duration delta = after.difference(before);
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest[0], containsPair('result', isNull));
          expect(delta.inMilliseconds, greaterThanOrEqualTo(250));
        });

        test('throwsIfAlreadyFlushing', () {
          rc.basicProperty = 'foo';
          recording.flush();
          expect(recording.flush(), throwsA(isStateError));
        });
      });
    });
  });

  group('RecordingFileSystem', () {
    RecordingFileSystem fs;
    MemoryFileSystem delegate;
    LiveRecording recording;

    setUp(() {
      delegate = new MemoryFileSystem();
      fs = new RecordingFileSystem(
        delegate: delegate,
        destination: new MemoryFileSystem().directory('/tmp')..createSync(),
      );
      recording = fs.recording;
    });

    runCommonTests(
      () => fs,
      skip: <String>[
        'File > open', // Not yet implemented in MemoryFileSystem
      ],
    );

    group('recording', () {
      test('supportsMultipleActions', () {
        fs.directory('/foo').createSync();
        fs.file('/foo/bar').writeAsStringSync('BAR');
        List<InvocationEvent<dynamic>> events = recording.events;
        expect(events, hasLength(4));
        expect(events[0], invokesMethod('directory'));
        expect(events[1], invokesMethod('createSync'));
        expect(events[2], invokesMethod('file'));
        expect(events[3], invokesMethod('writeAsStringSync'));
        expect(events[0].result, events[1].object);
        expect(events[2].result, events[3].object);
      });

      group('FileSystem', () {
        test('directory', () {
          fs.directory('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
            events[0],
            invokesMethod('directory').on(fs).withPositionalArguments(
                <String>['/foo']).withResult(isDirectory),
          );
        });

        test('file', () {
          fs.file('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
            events[0],
            invokesMethod('file')
                .on(fs)
                .withPositionalArguments(<String>['/foo']).withResult(isFile),
          );
        });

        test('link', () {
          fs.link('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
            events[0],
            invokesMethod('link')
                .on(fs)
                .withPositionalArguments(<String>['/foo']).withResult(isLink),
          );
        });

        test('path', () {
          fs.path;
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
            events[0],
            getsProperty('path')
                .on(fs)
                .withResult(const isInstanceOf<p.Context>()),
          );
        });

        test('systemTempDirectory', () {
          fs.systemTempDirectory;
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
              events[0],
              getsProperty('systemTempDirectory')
                  .on(fs)
                  .withResult(isDirectory));
        });

        group('currentDirectory', () {
          test('get', () {
            fs.currentDirectory;
            List<InvocationEvent<dynamic>> events = recording.events;
            expect(events, hasLength(1));
            expect(
                events[0],
                getsProperty('currentDirectory')
                    .on(fs)
                    .withResult(isDirectory));
          });

          test('setToString', () {
            delegate.directory('/foo').createSync();
            fs.currentDirectory = '/foo';
            List<InvocationEvent<dynamic>> events = recording.events;
            expect(events, hasLength(1));
            expect(events[0],
                setsProperty('currentDirectory').on(fs).toValue('/foo'));
          });

          test('setToRecordingDirectory', () {
            delegate.directory('/foo').createSync();
            fs.currentDirectory = fs.directory('/foo');
            List<InvocationEvent<dynamic>> events = recording.events;
            expect(events.length, greaterThanOrEqualTo(2));
            expect(events[0], invokesMethod().withResult(isDirectory));
            Directory directory = events[0].result;
            expect(
                events,
                contains(setsProperty('currentDirectory')
                    .on(fs)
                    .toValue(directory)));
          });

          test('setToNonRecordingDirectory', () {
            Directory dir = delegate.directory('/foo');
            dir.createSync();
            fs.currentDirectory = dir;
            List<InvocationEvent<dynamic>> events = recording.events;
            expect(events, hasLength(1));
            expect(events[0],
                setsProperty('currentDirectory').on(fs).toValue(isDirectory));
          });
        });

        test('stat', () async {
          delegate.file('/foo').createSync();
          await fs.stat('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
            events[0],
            invokesMethod('stat').on(fs).withPositionalArguments(
                <String>['/foo']).withResult(isFileStat),
          );
        });

        test('statSync', () {
          delegate.file('/foo').createSync();
          fs.statSync('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
            events[0],
            invokesMethod('statSync').on(fs).withPositionalArguments(
                <String>['/foo']).withResult(isFileStat),
          );
        });

        test('identical', () async {
          delegate.file('/foo').createSync();
          delegate.file('/bar').createSync();
          await fs.identical('/foo', '/bar');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
              events[0],
              invokesMethod('identical').on(fs).withPositionalArguments(
                  <String>['/foo', '/bar']).withResult(isFalse));
        });

        test('identicalSync', () {
          delegate.file('/foo').createSync();
          delegate.file('/bar').createSync();
          fs.identicalSync('/foo', '/bar');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
              events[0],
              invokesMethod('identicalSync').on(fs).withPositionalArguments(
                  <String>['/foo', '/bar']).withResult(isFalse));
        });

        test('isWatchSupported', () {
          fs.isWatchSupported;
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(events[0],
              getsProperty('isWatchSupported').on(fs).withResult(isFalse));
        });

        test('type', () async {
          delegate.file('/foo').createSync();
          await fs.type('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
              events[0],
              invokesMethod('type').on(fs).withPositionalArguments(
                  <String>['/foo']).withResult(FileSystemEntityType.FILE));
        });

        test('typeSync', () {
          delegate.file('/foo').createSync();
          fs.typeSync('/foo');
          List<InvocationEvent<dynamic>> events = recording.events;
          expect(events, hasLength(1));
          expect(
              events[0],
              invokesMethod('typeSync').on(fs).withPositionalArguments(
                  <String>['/foo']).withResult(FileSystemEntityType.FILE));
        });
      });

      group('Directory', () {
        test('create', () async {
          await fs.directory('/foo').create();
          expect(
              recording.events,
              contains(invokesMethod('create')
                  .on(isDirectory)
                  .withNoNamedArguments()
                  .withResult(isDirectory)));
        });

        test('createSync', () {
          fs.directory('/foo').createSync();
          expect(
              recording.events,
              contains(invokesMethod('createSync')
                  .on(isDirectory)
                  .withNoNamedArguments()
                  .withResult(isNull)));
        });

        test('list', () async {
          await delegate.directory('/foo').create();
          await delegate.directory('/bar').create();
          await delegate.file('/baz').create();
          Stream<FileSystemEntity> stream = fs.directory('/').list();
          await stream.drain();
          expect(
            recording.events,
            contains(invokesMethod('list')
                .on(isDirectory)
                .withNoNamedArguments()
                .withResult(hasLength(3))),
          );
        });
      });

      group('File', () {
        // TODO(tvolkert): Fill in these test stubs
        test('create', () {});

        test('createSync', () {});

        test('rename', () {});

        test('renameSync', () {});

        test('copy', () {});

        test('copySync', () {});

        test('length', () {});

        test('lengthSync', () {});

        test('absolute', () {});

        test('lastModified', () {});

        test('lastModifiedSync', () {});

        test('open', () {});

        test('openSync', () {});

        test('openRead', () async {
          String content = 'Hello\nWorld';
          await delegate.file('/foo').writeAsString(content, flush: true);
          Stream<List<int>> stream = fs.file('/foo').openRead();
          await stream.drain();
          expect(
              recording.events,
              contains(invokesMethod('openRead')
                  .on(isFile)
                  .withPositionalArguments(isEmpty)
                  .withNoNamedArguments()
                  .withResult(isList)));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'openRead'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('namedArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.openRead$')),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('openWrite', () {});

        test('readAsBytes', () async {
          String content = 'Hello\nWorld';
          await delegate.file('/foo').writeAsString(content, flush: true);
          await fs.file('/foo').readAsBytes();
          expect(
              recording.events,
              contains(invokesMethod('readAsBytes')
                  .on(isFile)
                  .withNoNamedArguments()
                  .withResult(allOf(isList, hasLength(content.length)))));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'readAsBytes'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('namedArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.readAsBytes$')),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('readAsBytesSync', () async {
          String content = 'Hello\nWorld';
          await delegate.file('/foo').writeAsString(content, flush: true);
          fs.file('/foo').readAsBytesSync();
          expect(
              recording.events,
              contains(invokesMethod('readAsBytesSync')
                  .on(isFile)
                  .withNoNamedArguments()
                  .withResult(allOf(isList, hasLength(content.length)))));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'readAsBytesSync'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('namedArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.readAsBytesSync$')),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('readAsString', () async {
          String content = 'Hello\nWorld';
          await delegate
              .file('/foo')
              .writeAsString(content, encoding: LATIN1, flush: true);
          await fs.file('/foo').readAsString(encoding: LATIN1);
          expect(
              recording.events,
              contains(invokesMethod('readAsString')
                  .on(isFile)
                  .withNamedArgument('encoding', LATIN1)
                  .withResult(content)));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'readAsString'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.readAsString$')),
                containsPair(
                    'namedArguments',
                    allOf(
                      hasLength(1),
                      containsPair('encoding', 'iso-8859-1'),
                    )),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('readAsStringSync', () async {
          String content = 'Hello\nWorld';
          await delegate
              .file('/foo')
              .writeAsString(content, encoding: LATIN1, flush: true);
          fs.file('/foo').readAsStringSync(encoding: LATIN1);
          expect(
              recording.events,
              contains(invokesMethod('readAsStringSync')
                  .on(isFile)
                  .withNamedArgument('encoding', LATIN1)
                  .withResult(content)));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'readAsStringSync'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.readAsStringSync$')),
                containsPair(
                    'namedArguments',
                    allOf(
                      hasLength(1),
                      containsPair('encoding', 'iso-8859-1'),
                    )),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('readAsLines', () async {
          String content = 'Hello\nWorld';
          await delegate.file('/foo').writeAsString(content, flush: true);
          await fs.file('/foo').readAsLines();
          expect(
              recording.events,
              contains(invokesMethod('readAsLines')
                  .on(isFile)
                  .withNoNamedArguments()
                  .withResult(<String>['Hello', 'World'])));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'readAsLines'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.readAsLines$')),
                containsPair('namedArguments', isEmpty),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('readAsLinesSync', () async {
          String content = 'Hello\nWorld';
          await delegate.file('/foo').writeAsString(content, flush: true);
          fs.file('/foo').readAsLinesSync();
          expect(
              recording.events,
              contains(invokesMethod('readAsLinesSync')
                  .on(isFile)
                  .withNoNamedArguments()
                  .withResult(<String>['Hello', 'World'])));
          await recording.flush();
          List<Map<String, dynamic>> manifest = _loadManifest(recording);
          expect(manifest, hasLength(2));
          expect(
              manifest[1],
              allOf(
                containsPair('type', 'invoke'),
                containsPair('method', 'readAsLinesSync'),
                containsPair('object', matches(r'^RecordingFile@[0-9]+$')),
                containsPair('positionalArguments', isEmpty),
                containsPair('result', matches(r'^![0-9]+.readAsLinesSync$')),
                containsPair('namedArguments', isEmpty),
              ));
          File file = _getRecordingFile(recording, manifest[1]['result']);
          expect(file, exists);
          expect(await file.readAsString(), content);
        });

        test('writeAsBytes', () {});

        test('writeAsBytesSync', () {});

        test('writeAsString', () {});

        test('writeAsStringSync', () {});
      });

      group('Link', () {});
    });
  });
}

List<Map<String, dynamic>> _loadManifest(LiveRecording recording) {
  List<FileSystemEntity> files = recording.destination.listSync();
  File manifestFile = files.singleWhere(
      (FileSystemEntity entity) => entity.basename == kManifestName);
  return new JsonDecoder().convert(manifestFile.readAsStringSync());
}

File _getRecordingFile(LiveRecording recording, String manifestReference) {
  expect(manifestReference, startsWith('!'));
  String basename = manifestReference.substring(1);
  String dirname = recording.destination.path;
  String path = recording.destination.fileSystem.path.join(dirname, basename);
  return recording.destination.fileSystem.file(path);
}

class _BasicClass {
  String basicProperty;

  Future<String> get futureProperty async => 'future.$basicProperty';

  String basicMethod(String positionalArg, {String namedArg}) =>
      '$positionalArg.$namedArg';

  Future<String> futureMethod(String positionalArg, {String namedArg}) async {
    await new Future<Null>.delayed(const Duration(milliseconds: 500));
    String basicValue = basicMethod(positionalArg, namedArg: namedArg);
    return 'future.$basicValue';
  }

  Stream<String> streamMethod(String positionalArg, {String namedArg}) async* {
    yield 'stream';
    yield positionalArg;
    yield namedArg;
  }

  Future<String> veryLongFutureMethod() async {
    await new Future<Null>.delayed(const Duration(seconds: 1));
    return 'future';
  }

  Stream<String> infiniteStreamMethod() async* {
    yield 'stream';
    int i = 0;
    while (i >= 0) {
      yield '${i++}';
      await new Future<Null>.delayed(const Duration(seconds: 1));
    }
  }
}

class _RecordingClass extends Object
    with RecordingProxyMixin
    implements _BasicClass {
  final _BasicClass delegate;

  _RecordingClass({
    this.delegate,
    this.stopwatch,
    Directory destination,
  })
      : recording = new MutableRecording(destination) {
    methods.addAll(<Symbol, Function>{
      #basicMethod: delegate.basicMethod,
      #futureMethod: delegate.futureMethod,
      #streamMethod: delegate.streamMethod,
      #veryLongFutureMethod: delegate.veryLongFutureMethod,
      #infiniteStreamMethod: delegate.infiniteStreamMethod,
    });

    properties.addAll(<Symbol, Function>{
      #basicProperty: () => delegate.basicProperty,
      const Symbol('basicProperty='): (String value) {
        delegate.basicProperty = value;
      },
      #futureProperty: () => delegate.futureProperty,
    });
  }

  @override
  final MutableRecording recording;

  @override
  final Stopwatch stopwatch;
}

class _FakeStopwatch implements Stopwatch {
  int _value;

  _FakeStopwatch(this._value);

  @override
  int get elapsedMilliseconds => _value++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
