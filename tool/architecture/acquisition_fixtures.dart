import 'package:meta/meta.dart';

@internal
Map<String, (String, Set<String>)> acquisitionFixtures() => {
  'native_file_alias': (
    "import 'dart:io' as renamed; Object acquire(String path) => renamed.File(path);",
    {'native-acquisition'},
  ),
  'native_directory_from_uri': (
    "import 'dart:io' as renamed; Object acquire(Uri uri) => renamed.Directory.fromUri(uri);",
    {'native-acquisition'},
  ),
  'native_link': (
    "import 'dart:io' as renamed; Object acquire(String path) => renamed.Link(path);",
    {'native-acquisition'},
  ),
  'native_file_type_alias': (
    "import 'dart:io' as renamed; typedef Selected = renamed.File; Object acquire(String path) => Selected(path);",
    {'native-acquisition'},
  ),
  'native_constructor_tearoff': (
    "import 'dart:io' as renamed; final acquire = renamed.File.new;",
    {'native-acquisition'},
  ),
  'native_named_constructor_tearoff': (
    "import 'dart:io' as renamed; final acquire = renamed.File.fromUri;",
    {'native-acquisition'},
  ),
  'native_process_run': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Process.run('tool', []);",
    {'native-acquisition'},
  ),
  'native_process_run_sync': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Process.runSync('tool', []);",
    {'native-acquisition'},
  ),
  'native_process_start': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Process.start('tool', []);",
    {'native-acquisition'},
  ),
  'native_socket_connect': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Socket.connect('localhost', 80);",
    {'native-acquisition'},
  ),
  'native_socket_start_connect': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Socket.startConnect('localhost', 80);",
    {'native-acquisition'},
  ),
  'native_server_bind': (
    "import 'dart:io' as renamed; Object acquire() => renamed.ServerSocket.bind('localhost', 0);",
    {'native-acquisition'},
  ),
  'native_http_client': (
    "import 'dart:io' as renamed; Object acquire() => renamed.HttpClient();",
    {'native-acquisition'},
  ),
  'native_http_constructor_tearoff': (
    "import 'dart:io' as renamed; final acquire = renamed.HttpClient.new;",
    {'native-acquisition'},
  ),
  'native_descriptor_path': (
    "import 'dart:io'; abstract class IosBuildPlatformInterface {} class Repository { String iosSdk(String sdk, {required IosBuildPlatformInterface target}) => '/sdk'; } void verify(Repository repository, IosBuildPlatformInterface target) { final root = repository.iosSdk('sdk', target: target); if (!Directory(root).existsSync()) throw StateError(root); }",
    {'native-acquisition'},
  ),
  'native_filesystem_query': (
    "import 'dart:io' as renamed; Object query(String path) => renamed.FileSystemEntity.typeSync(path);",
    {'native-acquisition'},
  ),
  'native_filesystem_async_query': (
    "import 'dart:io' as renamed; Object query(String path) => renamed.FileSystemEntity.isDirectory(path);",
    {'native-acquisition'},
  ),
  'native_file_stat': (
    "import 'dart:io' as renamed; Object query(String path) => renamed.FileStat.statSync(path);",
    {'native-acquisition'},
  ),
  'native_static_query_tearoff': (
    "import 'dart:io' as renamed; final query = renamed.FileSystemEntity.typeSync;",
    {'native-acquisition'},
  ),
  'native_process_tearoff': (
    "import 'dart:io' as renamed; final acquire = renamed.Process.start;",
    {'native-acquisition'},
  ),
  'native_server_tearoff': (
    "import 'dart:io' as renamed; final acquire = renamed.ServerSocket.bind;",
    {'native-acquisition'},
  ),
  'native_reconstruction_from_entity': (
    "import 'dart:io' as renamed; Object acquire(renamed.File supplied) => renamed.File(supplied.path);",
    {'native-acquisition'},
  ),
  'native_current_directory': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Directory.current;",
    {'ambient-detection'},
  ),
  'native_system_temp_directory': (
    "import 'dart:io' as renamed; Object acquire() => renamed.Directory.systemTemp;",
    {'ambient-detection'},
  ),
  'supplied_native_entities': (
    "import 'dart:io' as renamed; void operate(renamed.File file, renamed.Directory directory, renamed.Link link) { file.readAsBytesSync(); file.statSync(); directory.listSync(); link.targetSync(); file.parent.path; }",
    {},
  ),
  'injected_filesystem_port': (
    "import 'dart:io' as renamed; abstract interface class Files { renamed.File file(String path); renamed.Directory directory(String path); renamed.Link link(String path); } class Reader { final Files files; Reader(this.files); void read(String path) { files.file(path).readAsBytesSync(); files.directory(path).listSync(); files.link(path).targetSync(); } }",
    {},
  ),
  'injected_endpoint_ports': (
    "import 'dart:io' as renamed; abstract interface class Endpoints { Future<renamed.Socket> connect(); Future<renamed.Process> start(); Future<renamed.ServerSocket> bind(); } void acquire(Endpoints endpoints) { endpoints.connect(); endpoints.start(); endpoints.bind(); }",
    {},
  ),
  'supplied_native_clients': (
    "import 'dart:io' as renamed; void operate(renamed.Socket socket, renamed.Process process, renamed.HttpClient client, Uri uri) { socket.write('data'); process.kill(); client.getUrl(uri); }",
    {},
  ),
  'unrelated_native_spellings': (
    "class File { File(String path); } class Directory { Directory(String path); static String get current=>'descriptor'; } class Socket { static String connect(String path,int port)=>'descriptor'; } class FileSystemEntity { static String typeSync(String path)=>'descriptor'; } void work(String path) { File(path); Directory(path); Directory.current; Socket.connect(path,0); FileSystemEntity.typeSync(path); }",
    {},
  ),
};
