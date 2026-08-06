import 'package:apple_developer_kit/src/adi/elf/elf_reader.dart';
import 'package:meta/meta.dart';

/// The symbol-lookup state collected while scanning section headers.
@immutable
final class ElfSymbolTables {
  const ElfSymbolTables({this.symtab, this.gnuHash, this.elfHash});

  final ElfDynamicSymbolTable? symtab;
  final GnuHashTable? gnuHash;
  final ElfHashTable? elfHash;
}
