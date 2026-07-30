import 'dart:convert';

import 'package:test/test.dart';
import 'package:xcross/src/cli/ide/dap_command.dart';
import 'package:xcross/src/constants.dart';

void main() {
  group('DapFraming', () {
    test('round-trips a payload whose byte length != char length', () {
      final framing = DapFraming();
      const message = {'type': 'event', 'event': 'output', 'body': 'héllo ✓ 日'};
      final frame = DapFraming.encode(message);
      // The header must count UTF-8 bytes; anything else desynchronises.
      expect(
        utf8.decode(frame).startsWith(
            'Content-Length: ${utf8.encode(jsonEncode(message)).length}\r\n'),
        isTrue,
      );
      expect(framing.feed(frame), [message]);
    });

    test('decodes two frames arriving in one chunk', () {
      final framing = DapFraming();
      final chunk = [
        ...DapFraming.encode({'seq': 1}),
        ...DapFraming.encode({'seq': 2}),
      ];
      expect(framing.feed(chunk), [
        {'seq': 1},
        {'seq': 2},
      ]);
    });

    test('a malformed payload does not drop its sibling frames', () {
      final framing = DapFraming();
      final chunk = [
        ...DapFraming.encode({'seq': 1}),
        ...utf8.encode('Content-Length: 3\r\n\r\nnot'),
        ...DapFraming.encode({'seq': 2}),
      ];
      expect(framing.feed(chunk), [
        {'seq': 1},
        {'seq': 2},
      ]);
    });

    test('decodes a frame split across two chunks', () {
      final framing = DapFraming();
      final frame = DapFraming.encode({'command': 'hotReload', 'x': 'ü'});
      expect(framing.feed(frame.sublist(0, 12)), isEmpty);
      expect(framing.feed(frame.sublist(12)), [
        {'command': 'hotReload', 'x': 'ü'},
      ]);
    });
  });

  group('LineScanner', () {
    const marker = DeviceConstants.vmServiceMarker;
    const uri = 'ws://[fd8a:1122:3344::1]:12345/ws';
    const logLine = '$marker$uri\n';

    /// Mirrors what the DAP does with the child's stdout: reassemble lines,
    /// then pull the VM Service URI off the marker line.
    String? scan(List<String> chunks) {
      final scanner = LineScanner();
      for (final chunk in chunks) {
        for (final line in scanner.feed(chunk)) {
          final start = line.indexOf(marker);
          if (start >= 0) return line.substring(start + marker.length).trim();
        }
      }
      return null;
    }

    test('recovers the URI wherever the chunk boundary falls', () {
      const stream = 'Building...\nInstalling...\n$logLine';
      // Every split point, including mid-marker and mid-URI.
      for (var cut = 0; cut <= stream.length; cut++) {
        expect(scan([stream.substring(0, cut), stream.substring(cut)]), uri,
            reason: 'cut at $cut');
      }
    });

    test('recovers the URI one character at a time', () {
      expect(scan(logLine.split('')), uri);
    });

    test('reports nothing until the line is terminated', () {
      // Without the newline the URI may still be truncated.
      expect(scan([marker, uri]), isNull);
      expect(scan([marker, uri, '\n']), uri);
    });

    test('ignores unrelated output and tolerates CRLF', () {
      expect(scan(['no marker here\nstill none\n']), isNull);
      expect(scan(['$marker$uri\r\n']), uri);
    });
  });
}
