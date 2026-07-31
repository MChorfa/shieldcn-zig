#!/usr/bin/env python3
"""
Python binding demo via cffi — proves the C ABI opens the door to every
language with an FFI.

Install:
    pip install cffi

Run:
    zig build c-lib
    LD_LIBRARY_PATH=zig-out/lib python3 examples/c-client/hello.py
"""
import cffi

ffi = cffi.FFI()
ffi.cdef("""
    typedef struct DaggerClient     DaggerClient;
    typedef struct DaggerQuery      DaggerQuery;
    typedef struct DaggerContainer  DaggerContainer;

    DaggerClient    *dagger_connect(void);
    void             dagger_client_close(DaggerClient *);
    DaggerQuery     *dagger_client_dag(DaggerClient *);
    DaggerContainer *dagger_query_container(DaggerQuery *);
    DaggerContainer *dagger_container_from(DaggerContainer *, const char *);
    DaggerContainer *dagger_container_with_exec(DaggerContainer *,
                                                const char *const *, size_t);
    int              dagger_container_stdout(DaggerContainer *, char **);
    const char      *dagger_last_error(void);
    void             dagger_string_free(char *);
""")

lib = ffi.dlopen("dagger")  # expects libdagger.so / libdagger.dylib on load path

def check(rc):
    if rc < 0:
        raise RuntimeError(ffi.string(lib.dagger_last_error()).decode())

def main():
    client = lib.dagger_connect()
    if client == ffi.NULL:
        raise RuntimeError(ffi.string(lib.dagger_last_error()).decode())
    try:
        ctr = lib.dagger_query_container(lib.dagger_client_dag(client))
        ctr = lib.dagger_container_from(ctr, b"alpine:latest")
        argv = [ffi.new("char[]", s) for s in (b"echo", b"hello from Python via Zig")]
        argv_arr = ffi.new("const char*[]", argv)
        ctr = lib.dagger_container_with_exec(ctr, argv_arr, len(argv))

        out_pp = ffi.new("char **")
        check(lib.dagger_container_stdout(ctr, out_pp))
        out = ffi.string(out_pp[0]).decode()
        lib.dagger_string_free(out_pp[0])
        print(out, end="")
    finally:
        lib.dagger_client_close(client)

if __name__ == "__main__":
    main()
