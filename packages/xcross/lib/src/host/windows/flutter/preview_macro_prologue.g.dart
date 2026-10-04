// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'preview_macro_prologue.dart';

// **************************************************************************
// StrEmbeddingGenerator
// **************************************************************************

const _$windowsPreviewMacroPrologue = r'''
#include <stdio.h>
#include <fcntl.h>
#include <io.h>
#define READFD _read
#define WRITEFD _write

static void initialize_fds(int *in_fd, int *out_fd) {
  int stdin_fd = _fileno(stdin);
  int stdout_fd = _fileno(stdout);
  *in_fd = _dup(stdin_fd);
  _close(stdin_fd);
  *out_fd = _dup(stdout_fd);
  _dup2(_fileno(stderr), stdout_fd);
  _setmode(*in_fd, _O_BINARY);
  _setmode(*out_fd, _O_BINARY);
}

''';
