// Minimal Swift compiler plugin stub: answers HostToPluginMessage over
// stdin/stdout per swift-syntax's StandardIOMessageConnection wire format
// (8-byte little-endian length prefix + UTF-8 JSON). No swift-syntax
// dependency: this speaks the raw wire protocol directly.
//
// Purpose: respond to any macro-expansion request by expanding to nothing,
// so `-load-plugin-executable <this>#PreviewsMacros` makes `#Preview { ... }`
// compile on hosts where Apple's real PreviewsMacros plugin is unavailable
// (any non-Xcode host), without touching source text.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#define DUP _dup
#define DUP2 _dup2
#define CLOSE _close
#define READFD _read
#define WRITEFD _write
#define FILENO _fileno
#else
#include <unistd.h>
#define DUP dup
#define DUP2 dup2
#define CLOSE close
#define READFD read
#define WRITEFD write
#define FILENO fileno
#endif

static int in_fd, out_fd;

static int read_full(int fd, void *buf, size_t n) {
  char *p = (char *)buf;
  size_t left = n;
  while (left > 0) {
    int r = READFD(fd, p, (unsigned int)left);
    if (r <= 0) return -1;
    p += r;
    left -= (size_t)r;
  }
  return 0;
}

static int write_full(int fd, const void *buf, size_t n) {
  const char *p = (const char *)buf;
  size_t left = n;
  while (left > 0) {
    int w = WRITEFD(fd, p, (unsigned int)left);
    if (w <= 0) return -1;
    p += w;
    left -= (size_t)w;
  }
  return 0;
}

// Reads one framed message; returns malloc'd buffer (caller frees) and sets
// *len, or NULL on EOF/error.
static char *read_message(size_t *len) {
  uint64_t header = 0;
  if (read_full(in_fd, &header, 8) != 0) return NULL;
  if (header == 0) return NULL;
  char *buf = (char *)malloc((size_t)header + 1);
  if (!buf) return NULL;
  if (read_full(in_fd, buf, (size_t)header) != 0) {
    free(buf);
    return NULL;
  }
  buf[header] = '\0';
  *len = (size_t)header;
  return buf;
}

static void write_message(const char *json, size_t len) {
  uint64_t header = (uint64_t)len;
  write_full(out_fd, &header, 8);
  write_full(out_fd, json, len);
}

// Extracts the first case-tag key of a single-key JSON object, e.g.
// {"getCapability":{...}} -> "getCapability". Returns a static buffer.
static char tag_buf[128];
static const char *extract_case_tag(const char *json) {
  const char *p = strchr(json, '{');
  if (!p) return NULL;
  p++;
  while (*p == ' ' || *p == '\n' || *p == '\t') p++;
  if (*p != '"') return NULL;
  p++;
  size_t i = 0;
  while (*p && *p != '"' && i < sizeof(tag_buf) - 1) tag_buf[i++] = *p++;
  tag_buf[i] = '\0';
  return tag_buf;
}

int main(void) {
#ifdef _WIN32
  int stdin_fd = FILENO(stdin);
  int stdout_fd = FILENO(stdout);
  in_fd = DUP(stdin_fd);
  CLOSE(stdin_fd);
  out_fd = DUP(stdout_fd);
  DUP2(FILENO(stderr), stdout_fd);
  _setmode(in_fd, _O_BINARY);
  _setmode(out_fd, _O_BINARY);
#else
  in_fd = DUP(FILENO(stdin));
  CLOSE(FILENO(stdin));
  out_fd = DUP(FILENO(stdout));
  DUP2(FILENO(stderr), FILENO(stdout));
#endif

  for (;;) {
    size_t len = 0;
    char *msg = read_message(&len);
    if (!msg) break;
    const char *tag = extract_case_tag(msg);
    if (tag && strcmp(tag, "getCapability") == 0) {
      static const char resp[] =
          "{\"getCapabilityResult\":{\"capability\":{\"protocolVersion\":8}}}";
      write_message(resp, sizeof(resp) - 1);
    } else if (tag &&
               (strcmp(tag, "expandFreestandingMacro") == 0 ||
                strcmp(tag, "expandAttachedMacro") == 0)) {
      // Expand to nothing: an empty declaration/expression is valid Swift
      // wherever a macro that produced no code would be.
      static const char resp[] =
          "{\"expandMacroResult\":{\"expandedSource\":\"\",\"diagnostics\":[]}}";
      write_message(resp, sizeof(resp) - 1);
    } else {
      static const char resp[] =
          "{\"loadPluginLibraryResult\":{\"loaded\":false,\"diagnostics\":[]}}";
      write_message(resp, sizeof(resp) - 1);
    }
    free(msg);
  }
  return 0;
}
