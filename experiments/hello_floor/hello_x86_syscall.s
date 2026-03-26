.globl _main
.p2align 4, 0x90

_main:
    mov $0x2000004, %rax
    mov $1, %rdi
    lea L_.str(%rip), %rsi
    mov $6, %rdx
    syscall
    xor %eax, %eax
    ret

.section __TEXT,__cstring,cstring_literals
L_.str:
    .asciz "hello\n"
