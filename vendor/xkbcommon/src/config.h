/* Novella static libxkbcommon configuration. */
#ifndef NOVELLA_XKBCOMMON_CONFIG_H
#define NOVELLA_XKBCOMMON_CONFIG_H

#define EXIT_INVALID_USAGE 2
#define LIBXKBCOMMON_VERSION "1.13.2"
#define LIBXKBCOMMON_TOOL_PATH ""

#if defined(__APPLE__)
#define DFLT_XKB_LEGACY_ROOT "/opt/X11/share/X11/xkb"
#define DFLT_XKB_CONFIG_ROOT "/opt/X11/share/X11/xkb"
#define XLOCALEDIR "/opt/X11/share/X11/locale"
#else
#define DFLT_XKB_LEGACY_ROOT "/usr/share/X11/xkb"
#define DFLT_XKB_CONFIG_ROOT "/usr/share/X11/xkb"
#define XLOCALEDIR "/usr/share/X11/locale"
#endif

#define DFLT_XKB_CONFIG_EXTRA_PATH "/etc/xkb"
#define DEFAULT_XKB_RULES "evdev"
#define DEFAULT_XKB_MODEL "pc105"
#define DEFAULT_XKB_LAYOUT "us"
#define DEFAULT_XKB_VARIANT NULL
#define DEFAULT_XKB_OPTIONS NULL

#define HAVE_UNISTD_H 1
#define HAVE_DIRENT_H 1
#define HAVE_XKB_EXTENSIONS_DIRECTORIES 1
#define HAVE___BUILTIN_EXPECT 1
#define HAVE_MMAP 1
#define HAVE_STRNDUP 1
#define HAVE_ASPRINTF 1
#define HAVE_VASPRINTF 1
#define HAVE_REAL_PATH 1
#define HAVE_NEWLOCALE 1

#if defined(__linux__)
#define HAVE_EACCESS 1
#define HAVE_MKOSTEMP 1
#define HAVE_POSIX_FALLOCATE 1
#define HAVE_SECURE_GETENV 1
#endif

#endif
