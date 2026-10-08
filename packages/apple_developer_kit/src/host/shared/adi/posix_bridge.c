#if !defined(_WIN32)
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

#include "adi_posix_host_mapping.h"

static _Thread_local int adi_guest_errno;

static int adi_linux_errno(int value) { return adi_host_linux_errno(value); }

static int adi_result(int result) {
  if (result == -1) adi_guest_errno = adi_linux_errno(errno);
  return result;
}

static int adi_close(int fd) { return adi_result(close(fd)); }
static int adi_mkdir(const char *path, unsigned mode) {
  return adi_result(mkdir(path, mode));
}
static int adi_chmod(const char *path, unsigned mode) {
  return adi_result(chmod(path, mode));
}
static int adi_ftruncate(int fd, int64_t size) {
  return adi_result(ftruncate(fd, size));
}
static intptr_t adi_read(int fd, void *buffer, size_t size) {
  ssize_t result = read(fd, buffer, size);
  if (result == -1) adi_guest_errno = adi_linux_errno(errno);
  return result;
}
static intptr_t adi_write(int fd, const void *buffer, size_t size) {
  ssize_t result = write(fd, buffer, size);
  if (result == -1) adi_guest_errno = adi_linux_errno(errno);
  return result;
}
static void *adi_malloc(size_t size) {
  void *result = malloc(size);
  if (!result && size) adi_guest_errno = adi_linux_errno(errno);
  return result;
}

void provision_clear_cache(void *address, intptr_t size) {
  __builtin___clear_cache((char *)address, (char *)address + size);
}

static int adi_open(const char *path, int flags, unsigned mode) {
  int native_flags = 0;
  if (adi_host_open_flags(flags, &native_flags) != 0) return adi_result(-1);
  return adi_result(open(path, native_flags, mode));
}

#if defined(__aarch64__) || defined(__arm64__)
typedef struct {
  uint64_t dev, ino;
  uint32_t mode, nlink, uid, gid;
  uint64_t rdev, pad1;
  int64_t size;
  int32_t blksize, pad2;
  int64_t blocks, atime_sec;
  uint64_t atime_nsec;
  int64_t mtime_sec;
  uint64_t mtime_nsec;
  int64_t ctime_sec;
  uint64_t ctime_nsec;
  uint32_t unused[2];
} AdiStat;
_Static_assert(sizeof(AdiStat) == 128, "AArch64 stat size");
#else
typedef struct {
  uint64_t dev, ino, nlink;
  uint32_t mode, uid, gid, pad;
  uint64_t rdev;
  int64_t size, blksize, blocks, atime_sec;
  uint64_t atime_nsec;
  int64_t mtime_sec;
  uint64_t mtime_nsec;
  int64_t ctime_sec;
  uint64_t ctime_nsec;
  int64_t unused[3];
} AdiStat;
_Static_assert(sizeof(AdiStat) == 144, "x86_64 stat size");
#endif

static void adi_copy_stat(AdiStat *out, const struct stat *in) {
  memset(out, 0, sizeof(*out));
  out->dev = in->st_dev;
  out->ino = in->st_ino;
  out->nlink = in->st_nlink;
  out->mode = in->st_mode;
  out->uid = in->st_uid;
  out->gid = in->st_gid;
  out->rdev = in->st_rdev;
  out->size = in->st_size;
  out->blksize = in->st_blksize;
  out->blocks = in->st_blocks;
  const struct timespec accessed = adi_host_atime(in);
  const struct timespec modified = adi_host_mtime(in);
  const struct timespec changed = adi_host_ctime(in);
  out->atime_sec = accessed.tv_sec;
  out->atime_nsec = accessed.tv_nsec;
  out->mtime_sec = modified.tv_sec;
  out->mtime_nsec = modified.tv_nsec;
  out->ctime_sec = changed.tv_sec;
  out->ctime_nsec = changed.tv_nsec;
}

static int adi_lstat(const char *path, AdiStat *out) {
  struct stat value;
  int result = lstat(path, &value);
  if (result == 0) adi_copy_stat(out, &value);
  return adi_result(result);
}

static int adi_fstat(int fd, AdiStat *out) {
  struct stat value;
  int result = fstat(fd, &value);
  if (result == 0) adi_copy_stat(out, &value);
  return adi_result(result);
}

static int *adi_errno(void) { return &adi_guest_errno; }

static int adi_gettimeofday(int64_t *out, void *zone) {
  (void)zone;
  struct timeval value;
  int result = gettimeofday(&value, NULL);
  if (result == 0 && out) {
    out[0] = value.tv_sec;
    out[1] = value.tv_usec;
  }
  return adi_result(result);
}

void *provision_posix_symbol(const char *name) {
  if (!strcmp(name, "close")) return (void *)&adi_close;
  if (!strcmp(name, "mkdir")) return (void *)&adi_mkdir;
  if (!strcmp(name, "chmod")) return (void *)&adi_chmod;
  if (!strcmp(name, "ftruncate")) return (void *)&adi_ftruncate;
  if (!strcmp(name, "read")) return (void *)&adi_read;
  if (!strcmp(name, "write")) return (void *)&adi_write;
  if (!strcmp(name, "malloc")) return (void *)&adi_malloc;
  if (!strcmp(name, "open")) return (void *)&adi_open;
  if (!strcmp(name, "lstat")) return (void *)&adi_lstat;
  if (!strcmp(name, "fstat")) return (void *)&adi_fstat;
  if (!strcmp(name, "__errno_location")) return (void *)&adi_errno;
  if (!strcmp(name, "gettimeofday")) return (void *)&adi_gettimeofday;
  return NULL;
}
#endif
