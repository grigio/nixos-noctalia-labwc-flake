#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

struct pw_core;
struct pw_context;
struct pw_properties;

static struct pw_core* (*real_connect_fd)(struct pw_context *, int,
                                           struct pw_properties *, size_t) = NULL;
static struct pw_core* (*real_connect)(struct pw_context *,
                                        struct pw_properties *, size_t) = NULL;

struct pw_core *pw_context_connect_fd(struct pw_context *context, int fd,
                                      struct pw_properties *properties,
                                      size_t user_data_size)
{
    struct pw_core *core = NULL;

    if (!real_connect) {
        void *handle = dlopen("libpipewire-0.3.so.0", RTLD_LAZY);
        if (handle) {
            real_connect = dlsym(handle, "pw_context_connect");
            dlclose(handle);
        }
        if (!real_connect) {
            real_connect = dlsym(RTLD_DEFAULT, "pw_context_connect");
        }
    }

    if (real_connect) {
        close(fd);
        core = real_connect(context, properties, user_data_size);
        return core;
    }

    if (!real_connect_fd) {
        void *handle = dlopen("libpipewire-0.3.so.0", RTLD_LAZY);
        if (handle) {
            real_connect_fd = dlsym(handle, "pw_context_connect_fd");
            dlclose(handle);
        }
    }
    if (real_connect_fd) {
        core = real_connect_fd(context, fd, properties, user_data_size);
        return core;
    }

    return NULL;
}
