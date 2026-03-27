/* finsmod.c — force insmod via finit_module() syscall
 * arm64: syscall 273 = finit_module(fd, params, flags)
 * flags: 1=ignore_modversions, 2=ignore_vermagic
 */
#include <sys/syscall.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

#ifndef __NR_finit_module
#define __NR_finit_module 273
#endif

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: finsmod <module.ko> [params]\n"
                        "  Loads module ignoring vermagic and modversions\n");
        return 1;
    }
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", argv[1], strerror(errno));
        return 1;
    }
    const char *params = (argc > 2) ? argv[2] : "";
    /* flags=2: MODULE_INIT_IGNORE_VERMAGIC only
     * With empty __versions section: modversions check passes via "no symbol version" path
     * flags=3 would zero versindex → try_to_force_load → ENOEXEC (no CONFIG_MODULE_FORCE_LOAD) */
    long ret = syscall(__NR_finit_module, fd, params, 2);
    close(fd);
    if (ret < 0) {
        fprintf(stderr, "finit_module: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
    printf("OK: module loaded\n");
    return 0;
}
