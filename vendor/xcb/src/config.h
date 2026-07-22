#ifndef NOVELLA_VENDOR_XCB_CONFIG_H
#define NOVELLA_VENDOR_XCB_CONFIG_H

#define GCC_HAS_VISIBILITY 1
#define HAVE_GETADDRINFO 1
#define HAVE_SENDMSG 1
#define USE_POLL 1
#define XCB_QUEUE_BUFFER_SIZE 16384

#if defined(__APPLE__)
#define HAVE_SOCKADDR_SUN_LEN 1
#ifndef IOV_MAX
#define IOV_MAX 16
#endif
#elif defined(__linux__)
#define HAVE_ABSTRACT_SOCKETS 1
#ifndef IOV_MAX
#define IOV_MAX 1024
#endif
#else
#ifndef IOV_MAX
#define IOV_MAX 16
#endif
#endif

#endif
