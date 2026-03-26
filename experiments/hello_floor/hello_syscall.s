.globl _main
.p2align 2

_main:
    mov x0, #1
    adrp x1, L_.str@PAGE
    add x1, x1, L_.str@PAGEOFF
    mov x2, #6
    mov x16, #4
    svc #0x80
    mov x0, #0
    ret

.section __TEXT,__cstring,cstring_literals
L_.str:
    .asciz "hello\n"
