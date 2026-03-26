.globl _start
.p2align 2

_start:
    mov x0, #1
    adrp x1, L_.str@PAGE
    add x1, x1, L_.str@PAGEOFF
    mov x2, #6
    bl _write
    mov x0, #0
    bl _exit

.section __TEXT,__cstring,cstring_literals
L_.str:
    .asciz "hello\n"
