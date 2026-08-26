/// Swift driver arguments needed when linking Objective-C plugin packages.
///
/// `-ObjC` loads archive members that define Objective-C categories. The lld
/// compatibility flags retain those category and stub symbols when linking on
/// cross hosts.
const List<String> objectiveCLinkerSwiftDriverArguments = [
  '-Xswiftc',
  '-Xlinker',
  '-Xswiftc',
  '-ObjC',
  '-Xswiftc',
  '-Xlinker',
  '-Xswiftc',
  '-no_objc_category_merging',
];
