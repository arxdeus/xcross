Map<String, (String, Set<String>)> declarationFixtures() => {
  'required_factory_invocation': (
    '''import 'dart:io'; class Service { final HttpClient client; Service({required HttpClient Function() createClient}):client=createClient(); }''',
    {},
  ),
  'required_factory_field': (
    '''import 'dart:io'; class Service { final HttpClient Function() createClient; Service(HttpClient Function() supplied):createClient=supplied; }''',
    {},
  ),
  'inherited_target': (
    '''abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class IosTarget<T extends PlatformHostInterface> implements PlatformTargetInterface<T> {} abstract class Renamed<T> implements IosTarget<T> {}''',
    {'target-bound'},
  ),
  'ordinary_target_holder': (
    '''abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class Holder { PlatformTargetInterface<PlatformHostInterface> get target; }''',
    {},
  ),
  'private_class': ('''class _Helper {}''', {'private-type'}),
  'private_mixin': ('''mixin _Helper {}''', {'private-type'}),
  'private_enum': ('''enum _Helper { value }''', {'private-type'}),
  'private_extension_type': (
    '''extension type _Helper(int value) {}''',
    {'private-type'},
  ),
  'private_members': (
    '''class Helper { final int _value = 1; int _read() => _value; }''',
    {},
  ),
  'global_service': (
    '''class Log { Log(); } final logger = Log();''',
    {'global-service'},
  ),
  'di_fallback': (
    '''class Log { Log(); } class Service { final Log log; Service({Log? log}) : log = log ?? Log(); }''',
    {'hidden-di-default'},
  ),
  'di_explicit': (
    '''class Log { Log(); } class Service { final Log log; Service(this.log); }''',
    {},
  ),
  'pure_descriptor_default': (
    '''class IPhoneBuildPlatform { const IPhoneBuildPlatform(); } String sdkPath({IPhoneBuildPlatform input = const IPhoneBuildPlatform()}) => '/sdk';''',
    {},
  ),
  'private_class_alias': (
    '''mixin Helper {} class _Alias = Object with Helper;''',
    {'private-type'},
  ),
  'di_field': (
    '''class Log { Log(); } class Service { final Log log=Log(); }''',
    {'hidden-di-default'},
  ),
  'di_direct_initializer': (
    '''class Log { Log(); } class Service { final Log log; Service():log=Log(); }''',
    {'hidden-di-default'},
  ),
  'di_factory_fallback': (
    '''class Log { Log(); } Log createLog()=>Log(); class Service { final Log log; Service({Log? log}):log=log??createLog(); }''',
    {'hidden-di-default'},
  ),
  'di_factory_default': (
    '''import 'dart:io'; class Service { final HttpClient Function() createClient; Service({this.createClient=HttpClient.new}); }''',
    {'hidden-di-default'},
  ),
  'di_factory_injection': (
    '''import 'dart:io'; class Service { final HttpClient Function() createClient; Service({required this.createClient}); }''',
    {},
  ),
  'global_service_subtype': (
    '''class Log { Log(); } class CustomLog extends Log {} final logger=CustomLog();''',
    {'global-service'},
  ),
  'global_service_slot': (
    '''class Log { Log(); } late Log activeLog;''',
    {'global-service'},
  ),
  'coherent_named_bound': (
    '''abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class Target<H extends PlatformHostInterface> implements PlatformTargetInterface<H> {}''',
    {},
  ),
  'coherent_narrow_bound': (
    '''abstract class PlatformHostInterface {} abstract class WindowsHostInterface implements PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class Target<T extends WindowsHostInterface> implements PlatformTargetInterface<T> {}''',
    {},
  ),
  'incoherent_bound': (
    '''abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class Target<H extends PlatformHostInterface,Y> implements PlatformTargetInterface<Y> {}''',
    {'target-bound'},
  ),
  'bounded_target': (
    '''abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class ValidTarget<T extends PlatformHostInterface> implements PlatformTargetInterface<T> {}''',
    {},
  ),
  'unbounded_target': (
    '''abstract class PlatformHostInterface {} abstract class PlatformTargetInterface<T extends PlatformHostInterface> {} abstract class BadTarget<T> implements PlatformTargetInterface<T> {}''',
    {'target-bound'},
  ),
};
