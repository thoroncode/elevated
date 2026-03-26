CC = clang
OUTDIR = build

CFLAGS = -Oz
LDFLAGS = -Wl,-dead_strip

C_HELLO = $(OUTDIR)/hello_c
START_HELLO = $(OUTDIR)/hello_start

C_STRIPPED = $(OUTDIR)/hello_c.stripped
START_STRIPPED = $(OUTDIR)/hello_start.stripped

.PHONY: all report clean

all: $(C_STRIPPED) $(START_STRIPPED)

$(OUTDIR):
	@mkdir -p $(OUTDIR)

$(C_HELLO): hello.c | $(OUTDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

$(START_HELLO): hello_start.s | $(OUTDIR)
	$(CC) $(CFLAGS) -nostartfiles -Wl,-e,_start $< -o $@

$(C_STRIPPED): $(C_HELLO)
	@cp $< $@
	@strip -u $@
	@codesign --remove-signature $@ >/dev/null 2>&1 || true

$(START_STRIPPED): $(START_HELLO)
	@cp $< $@
	@strip -u $@
	@codesign --remove-signature $@ >/dev/null 2>&1 || true

report: all
	@python3 report.py $(C_STRIPPED) $(START_STRIPPED)

clean:
	@rm -rf $(OUTDIR)
