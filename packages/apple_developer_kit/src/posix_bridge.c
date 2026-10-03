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

static _Thread_local int adi_guest_errno;

static int adi_linux_errno(int value) {
#if defined(__APPLE__)
  if (value >= 1 && value <= 34) return value == EDEADLK ? 35 : value;
  switch (value) {
    case EAGAIN: return 11;
    case EINPROGRESS: return 115;
    case EALREADY: return 114;
    case ENOTSOCK: return 88;
    case EDESTADDRREQ: return 89;
    case EMSGSIZE: return 90;
    case EPROTOTYPE: return 91;
    case ENOPROTOOPT: return 92;
    case EPROTONOSUPPORT: return 93;
    case ESOCKTNOSUPPORT: return 94;
    case ENOTSUP: return 95;
    case EOPNOTSUPP: return 95;
    case EPFNOSUPPORT: return 96;
    case EAFNOSUPPORT: return 97;
    case EADDRINUSE: return 98;
    case EADDRNOTAVAIL: return 99;
    case ENETDOWN: return 100;
    case ENETUNREACH: return 101;
    case ENETRESET: return 102;
    case ECONNABORTED: return 103;
    case ECONNRESET: return 104;
    case ENOBUFS: return 105;
    case EISCONN: return 106;
    case ENOTCONN: return 107;
    case ESHUTDOWN: return 108;
    case ETOOMANYREFS: return 109;
    case ETIMEDOUT: return 110;
    case ECONNREFUSED: return 111;
    case ELOOP: return 40;
    case ENAMETOOLONG: return 36;
    case EHOSTDOWN: return 112;
    case EHOSTUNREACH: return 113;
    case ENOTEMPTY: return 39;
    case EPROCLIM: return 11;
    case EUSERS: return 87;
    case EDQUOT: return 122;
    case ESTALE: return 116;
    case EREMOTE: return 66;
    case ENOLCK: return 37;
    case ENOSYS: return 38;
    case EFTYPE: return 22;
    case EAUTH: return 13;
    case ENEEDAUTH: return 13;
    case EOVERFLOW: return 75;
    case ECANCELED: return 125;
    case EIDRM: return 43;
    case ENOMSG: return 42;
    case EILSEQ: return 84;
    case ENOATTR: return 61;
    case EBADMSG: return 74;
    case EMULTIHOP: return 72;
    case ENODATA: return 61;
    case ENOLINK: return 67;
    case ENOSR: return 63;
    case ENOSTR: return 60;
    case EPROTO: return 71;
    case ETIME: return 62;
    case ENOTRECOVERABLE: return 131;
    case EOWNERDEAD: return 130;
    default: return 5;
  }
#else
  return value;
#endif
}

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
    return adi_result(-1);
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
  if (flags & direct) { errno = EINVAL; return adi_result(-1); }
  if (flags & directory) native_flags |= O_DIRECTORY;
  if (flags & nofollow) native_flags |= O_NOFOLLOW;
  if (flags & 02000000) native_flags |= O_CLOEXEC;
  flags = native_flags;
#endif
  return adi_result(open(path, flags, mode));
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
