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

void provision_clear_cache(void *address, intptr_t size) {
  __builtin___clear_cache((char *)address, (char *)address + size);
}

static int adi_open(const char *path, int flags, unsigned mode) {
#if defined(__APPLE__)
#if defined(__aarch64__) || defined(__arm64__)
  const int directory = 1 << 14, nofollow = 1 << 15;
  const int direct = 1 << 16, largefile = 1 << 17;
#else
  const int direct = 1 << 14, largefile = 1 << 15;
  const int directory = 1 << 16, nofollow = 1 << 17;
#endif
  const int known = 3 | 0100 | 0200 | 0400 | 01000 | 02000 | 04000 |
      010000 | 040000 | 0100000 | 0200000 | 0400000 | 02000000;
  if ((flags & ~known) || (flags & 3) == 3) {
    errno = EINVAL;
    return -1;
  }
  int native_flags = flags & 3;
  if (flags & 0100) native_flags |= O_CREAT;
  if (flags & 0200) native_flags |= O_EXCL;
  if (flags & 0400) native_flags |= O_NOCTTY;
  if (flags & 01000) native_flags |= O_TRUNC;
  if (flags & 02000) native_flags |= O_APPEND;
  if (flags & 04000) native_flags |= O_NONBLOCK;
  if (flags & 010000) native_flags |= O_SYNC;
  (void)largefile;
  if (flags & direct) { errno = EINVAL; return -1; }
  if (flags & directory) native_flags |= O_DIRECTORY;
  if (flags & nofollow) native_flags |= O_NOFOLLOW;
  if (flags & 02000000) native_flags |= O_CLOEXEC;
  flags = native_flags;
#endif
  return open(path, flags, mode);
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
#if defined(__APPLE__)
  out->atime_sec = in->st_atimespec.tv_sec;
  out->atime_nsec = in->st_atimespec.tv_nsec;
  out->mtime_sec = in->st_mtimespec.tv_sec;
  out->mtime_nsec = in->st_mtimespec.tv_nsec;
  out->ctime_sec = in->st_ctimespec.tv_sec;
  out->ctime_nsec = in->st_ctimespec.tv_nsec;
#else
  out->atime_sec = in->st_atim.tv_sec;
  out->atime_nsec = in->st_atim.tv_nsec;
  out->mtime_sec = in->st_mtim.tv_sec;
  out->mtime_nsec = in->st_mtim.tv_nsec;
  out->ctime_sec = in->st_ctim.tv_sec;
  out->ctime_nsec = in->st_ctim.tv_nsec;
#endif
}

static int adi_lstat(const char *path, AdiStat *out) {
  struct stat value;
  int result = lstat(path, &value);
  if (result == 0) adi_copy_stat(out, &value);
  return result;
}

static int adi_fstat(int fd, AdiStat *out) {
  struct stat value;
  int result = fstat(fd, &value);
  if (result == 0) adi_copy_stat(out, &value);
  return result;
}

static int *adi_errno(void) { return &errno; }

static int adi_gettimeofday(int64_t *out, void *zone) {
  (void)zone;
  struct timeval value;
  int result = gettimeofday(&value, NULL);
  if (result == 0 && out) {
    out[0] = value.tv_sec;
    out[1] = value.tv_usec;
  }
  return result;
}

void *provision_posix_symbol(const char *name) {
  if (!strcmp(name, "open")) return (void *)&adi_open;
  if (!strcmp(name, "lstat")) return (void *)&adi_lstat;
  if (!strcmp(name, "fstat")) return (void *)&adi_fstat;
  if (!strcmp(name, "__errno_location")) return (void *)&adi_errno;
  if (!strcmp(name, "gettimeofday")) return (void *)&adi_gettimeofday;
  return NULL;
}
#endif
