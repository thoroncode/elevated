# macOS Hello Floor

This experiment exists to show how much Mach-O and dyld overhead macOS keeps
even for a tiny executable.

It builds two variants:

- `hello_c`: plain C `main()` calling `write(1, "hello\n", 6)`
- `hello_start`: hand-written ARM64 assembly with a custom `_start`

Usage:

```bash
make -C experiments/hello_floor report
```

The important observation is whether the custom entry-point assembly version is
actually smaller than the plain C version. If both land at roughly the same
size, the file format and loader metadata are dominating the floor.
