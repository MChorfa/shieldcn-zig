/*
 * examples/c-client/hello.c — the C equivalent of first-pipeline.
 *
 * Build:
 *   zig build c-lib
 *   cc -I include -L zig-out/lib -ldagger examples/c-client/hello.c -o hello
 *
 * Run (requires dagger CLI on PATH or an active session):
 *   ./hello
 */

#include <dagger.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(rc) \
    do { \
        if ((rc) < 0) { \
            fprintf(stderr, "dagger: %s\n", dagger_last_error()); \
            return 1; \
        } \
    } while (0)

int main(void) {
    /* Compile-time ABI check. */
    if (dagger_abi_version() != DAGGER_ABI_VERSION) {
        fprintf(stderr, "ABI mismatch: header=%d, lib=%d\n",
                DAGGER_ABI_VERSION, dagger_abi_version());
        return 1;
    }

    DaggerClient *client = dagger_connect();
    if (!client) {
        fprintf(stderr, "connect failed: %s\n", dagger_last_error());
        return 1;
    }

    DaggerContainer *ctr = dagger_query_container(dagger_client_dag(client));
    ctr = dagger_container_from(ctr, "alpine:latest");
    const char *argv[] = {"echo", "hello from C via dagger-zig"};
    ctr = dagger_container_with_exec(ctr, argv, 2);

    char *out = NULL;
    int rc = dagger_container_stdout(ctr, &out);
    CHECK(rc);

    printf("%s", out);
    dagger_string_free(out);
    dagger_client_close(client);
    return 0;
}
