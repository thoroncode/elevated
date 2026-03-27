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
- `hello_x86_syscall`: `x86_64` syscall hello that runs through Rosetta

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
- smallest standard arm64 dyld-linked file that still follows the 16 KB world:
  about `16.1 KB` (`hello_syscall_16k`)
- smallest runnable Rosetta cheat: about `4.2 KB` (`hello_x86_syscall`)
- smallest launchable hello in this environment after ad-hoc signing: about
  `34.0 KB` (`hello_syscall_16k`)

That gap is the key lesson: the container can be made tiny, but the local
execution rules still drag launchable binaries back up, unless you are willing
to cheat with a supported legacy architecture.

## What We Learned

- For normal arm64 macOS executables, code size is not the first bottleneck.
  Mach-O segment layout, dyld requirements, and signing dominate much earlier.
- Hand-written assembly by itself does not solve the problem. A tiny `_start`
  still lives inside the same loader and alignment world as a tiny `main()`.
- The practical arm64 boundary on this machine is the 16 KB page world. Smaller
  4 KB and 8 KB aligned files can exist on disk, but they stop being a reliable
  "double-click and run" answer here.
- Rosetta `x86_64` is a real cheat path. It gives a much smaller runnable
  hello, but it is still a supported-legacy-architecture trick, not a general
  solution for the native arm64 intro.
- The real distinction is:
  - smallest file on disk
  - smallest file the local loader will launch
  - smallest file we can realistically use as the shell for the actual intro

## Implications For Elevated

For the real intro, this experiment shifts the next optimization target away
from "generate slightly better machine code" and toward executable-structure
work:

1. Keep shrinking the normal runnable arm64 intro until the next page-boundary
   drop becomes unrealistic.
2. Treat a tiny Mach-O stub as the likely native launch envelope, not the final
   packed content format.
3. If the project wants true demoscene-sized results, the next serious step is
   a stub-plus-packed-payload path or deeper post-link Mach-O surgery.
4. Keep the Rosetta/x86 result as a useful lower-bound reference, but not as
   the primary shipping direction.
