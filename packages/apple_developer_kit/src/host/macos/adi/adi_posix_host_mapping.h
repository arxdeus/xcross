#ifndef XCROSS_ADI_MACOS_POSIX_HOST_MAPPING_H
#define XCROSS_ADI_MACOS_POSIX_HOST_MAPPING_H

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>

static inline int adi_host_linux_errno(int value) {
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
}

static inline int adi_host_open_flags(int flags, int *out) {
#if defined(__aarch64__) || defined(__arm64__)
  const int directory = 1 << 14, nofollow = 1 << 15;
  const int direct = 1 << 16, largefile = 1 << 17;
#else
  const int direct = 1 << 14, largefile = 1 << 15;
  const int directory = 1 << 16, nofollow = 1 << 17;
#endif
  const int known = 3 | 0100 | 0200 | 0400 | 01000 | 02000 | 04000 |
      04010000 | 040000 | 0100000 | 0200000 | 0400000 | 02000000;
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
  if (flags & 04010000) native_flags |= O_SYNC;
  (void)largefile;
  if (flags & direct) { errno = EINVAL; return -1; }
  if (flags & directory) native_flags |= O_DIRECTORY;
  if (flags & nofollow) native_flags |= O_NOFOLLOW;
  if (flags & 02000000) native_flags |= O_CLOEXEC;
  *out = native_flags;
  return 0;
}

static inline struct timespec adi_host_atime(const struct stat *value) {
  return value->st_atimespec;
}

static inline struct timespec adi_host_mtime(const struct stat *value) {
  return value->st_mtimespec;
}

static inline struct timespec adi_host_ctime(const struct stat *value) {
  return value->st_ctimespec;
}

#endif
