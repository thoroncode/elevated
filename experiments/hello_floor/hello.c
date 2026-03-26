extern long write(int fd, const void *buf, unsigned long count);

int main(void) {
    write(1, "hello\n", 6);
    return 0;
}
