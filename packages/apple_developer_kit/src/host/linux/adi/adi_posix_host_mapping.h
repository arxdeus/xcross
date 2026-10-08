#ifndef XCROSS_ADI_LINUX_POSIX_HOST_MAPPING_H
#define XCROSS_ADI_LINUX_POSIX_HOST_MAPPING_H

#include <sys/stat.h>
#include <time.h>

static inline int adi_host_linux_errno(int value) { return value; }

static inline int adi_host_open_flags(int flags, int *out) {
  *out = flags;
  return 0;
}

static inline struct timespec adi_host_atime(const struct stat *value) {
  return value->st_atim;
}

static inline struct timespec adi_host_mtime(const struct stat *value) {
  return value->st_mtim;
}

static inline struct timespec adi_host_ctime(const struct stat *value) {
  return value->st_ctim;
}

#endif
