CC = clang
LD = ld
OUTDIR = build

CFLAGS = -Oz
LDFLAGS = -Wl,-dead_strip

C_HELLO = $(OUTDIR)/hello_c
START_HELLO = $(OUTDIR)/hello_start
SYSCALL_16K = $(OUTDIR)/hello_syscall_16k
SYSCALL_8K = $(OUTDIR)/hello_syscall_8k
SYSCALL_4K = $(OUTDIR)/hello_syscall_4k
RAWSTART_OBJ = $(OUTDIR)/hello_raw_start.o
STATIC_4K = $(OUTDIR)/hello_static_4k
PRELOAD_4K = $(OUTDIR)/hello_preload_4k
X86_SYSCALL = $(OUTDIR)/hello_x86_syscall

C_STRIPPED = $(OUTDIR)/hello_c.stripped
START_STRIPPED = $(OUTDIR)/hello_start.stripped
SYSCALL_16K_STRIPPED = $(OUTDIR)/hello_syscall_16k.stripped
SYSCALL_8K_STRIPPED = $(OUTDIR)/hello_syscall_8k.stripped
SYSCALL_4K_STRIPPED = $(OUTDIR)/hello_syscall_4k.stripped
STATIC_4K_STRIPPED = $(OUTDIR)/hello_static_4k.stripped
PRELOAD_4K_STRIPPED = $(OUTDIR)/hello_preload_4k.stripped
X86_SYSCALL_STRIPPED = $(OUTDIR)/hello_x86_syscall.stripped

.PHONY: all report clean

all: \
	$(C_STRIPPED) \
	$(START_STRIPPED) \
	$(SYSCALL_16K_STRIPPED) \
	$(SYSCALL_8K_STRIPPED) \
	$(SYSCALL_4K_STRIPPED) \
	$(STATIC_4K_STRIPPED) \
	$(PRELOAD_4K_STRIPPED) \
	$(X86_SYSCALL_STRIPPED)

$(OUTDIR):
	@mkdir -p $(OUTDIR)

$(C_HELLO): hello.c | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

$(START_HELLO): hello_start.s | $(OUTDIR)
	$(CC) $(CFLAGS) -nostartfiles -Wl,-e,_start $< -o $@

$(SYSCALL_16K): hello_syscall.s | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -nostartfiles -Wl,-segalign,0x4000 $< -o $@

$(SYSCALL_8K): hello_syscall.s | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -nostartfiles -Wl,-no_uuid -Wl,-no_function_starts -Wl,-segalign,0x2000 $< -o $@

$(SYSCALL_4K): hello_syscall.s | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -nostartfiles -Wl,-no_uuid -Wl,-no_function_starts -Wl,-segalign,0x1000 $< -o $@

$(RAWSTART_OBJ): hello_raw_start.s | $(OUTDIR)
	$(CC) -c $< -o $@

$(STATIC_4K): $(RAWSTART_OBJ)
	$(LD) -static -arch arm64 -e _start -segalign 0x1000 -no_uuid $< -o $@

$(PRELOAD_4K): $(RAWSTART_OBJ)
	$(LD) -preload -arch arm64 -e _start -segalign 0x1000 -no_uuid $< -o $@

$(X86_SYSCALL): hello_x86_syscall.s | $(OUTDIR)
	$(CC) -arch x86_64 $(CFLAGS) -nostartfiles -Wl,-dead_strip -Wl,-no_function_starts $< -o $@

%.stripped: %
	@cp $< $@
	@strip -u $@
	@codesign --remove-signature $@ >/dev/null 2>&1 || true

report: all
	@python3 report.py \
		$(C_STRIPPED) \
		$(START_STRIPPED) \
		$(SYSCALL_16K_STRIPPED) \
		$(SYSCALL_8K_STRIPPED) \
		$(SYSCALL_4K_STRIPPED) \
		$(STATIC_4K_STRIPPED) \
		$(PRELOAD_4K_STRIPPED) \
		$(X86_SYSCALL_STRIPPED)

clean:
	@rm -rf $(OUTDIR)
