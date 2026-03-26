.globl _start
.p2align 2

_start:
    mov x0, #1
    adrp x1, L_.str@PAGE
    add x1, x1, L_.str@PAGEOFF
    mov x2, #6
    mov x16, #4
    svc #0x80
    mov x0, #0
    mov x16, #1
    svc #0x80

.section __TEXT,__cstring,cstring_literals
L_.str:
    .asciz "hello\n"
