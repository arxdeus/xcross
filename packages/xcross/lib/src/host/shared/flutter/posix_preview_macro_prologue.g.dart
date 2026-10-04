// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'posix_preview_macro_prologue.dart';

// **************************************************************************
// StrEmbeddingGenerator
// **************************************************************************

const _$posixPreviewMacroPrologue = r'''
#include <stdio.h>
#include <unistd.h>
#define READFD read
#define WRITEFD write

static void initialize_fds(int *in_fd, int *out_fd) {
  *in_fd = dup(fileno(stdin));
  close(fileno(stdin));
  *out_fd = dup(fileno(stdout));
  dup2(fileno(stderr), fileno(stdout));
}

''';
