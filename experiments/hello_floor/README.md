# macOS Hello Floor

This experiment exists to show how much Mach-O, dyld, alignment, and code
signing overhead macOS keeps even for a tiny executable.

It builds a ladder of increasingly rule-breaking variants:

- `hello_c`: plain C `main()` calling `write(1, "hello\n", 6)`
- `hello_start`: hand-written ARM64 assembly with a custom `_start`
- `hello_syscall_16k`: dyld-linked assembly using direct Darwin syscalls
- `hello_syscall_8k`: same, but forced down to 8 KB segment alignment
- `hello_syscall_4k`: same, but forced down to 4 KB segment alignment
- `hello_static_4k`: static `MH_EXECUTE` with raw syscalls and 4 KB alignment
- `hello_preload_4k`: `MH_PRELOAD` with raw syscalls and 4 KB alignment

Usage:

```bash
make -C experiments/hello_floor report
```

The report does more than print file sizes:

- it shows the file kind and relevant load commands
- it reports on-disk segment/section overhead
- it probes launchability unsigned
- it signs a temporary copy and probes launchability again

The important observation is not just "what is the smallest file", but "what is
the smallest file the local loader will actually launch". On Apple Silicon, the
interesting boundary is that 4 KB and 8 KB aligned executables can be much
smaller on disk, while the runnable dyld path still wants the 16 KB world.

Current floor from this experiment:

- smallest file-backed `MH_EXECUTE`: about `4.0 KB` (`hello_static_4k`)
- smallest dyld-linked file: about `4.1 KB` (`hello_syscall_4k`)
- smallest launchable hello in this environment after ad-hoc signing: about
  `34.8 KB` (`hello_syscall_16k`)

That gap is the key lesson: the container can be made tiny, but the local
execution rules still drag launchable binaries back up.
