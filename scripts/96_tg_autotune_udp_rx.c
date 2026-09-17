#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define TG_DIAG_PORT 39353
#define BUF_SIZE 1024

static int64_t
now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return -1;
    return (int64_t) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int
main(int argc, char **argv)
{
    int seconds = 20;
    if (argc > 1) {
        char *end = NULL;
        long v = strtol(argv[1], &end, 10);
        if (!end || *end || v < 1 || v > 300) {
            fprintf(stderr, "usage: %s [seconds:1..300]\n", argv[0]);
            return 2;
        }
        seconds = (int) v;
    }

    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("socket");
        return 3;
    }

    int one = 1;
    (void) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TG_DIAG_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (const struct sockaddr *) &addr, sizeof(addr)) != 0) {
        perror("bind");
        close(fd);
        return 4;
    }

    const int64_t start = now_ms();
    if (start < 0) {
        perror("clock_gettime");
        close(fd);
        return 5;
    }
    const int64_t deadline = start + (int64_t) seconds * 1000;

    printf("TGAT_RX_READY port=%d seconds=%d\n", TG_DIAG_PORT, seconds);
    fflush(stdout);

    unsigned long count = 0;
    for (;;) {
        int64_t now = now_ms();
        if (now < 0)
            break;
        int64_t remain = deadline - now;
        if (remain <= 0)
            break;
        if (remain > 1000)
            remain = 1000;

        struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
        int pr = poll(&pfd, 1, (int) remain);
        if (pr < 0) {
            if (errno == EINTR)
                continue;
            perror("poll");
            close(fd);
            return 6;
        }
        if (pr == 0)
            continue;
        if (!(pfd.revents & POLLIN))
            continue;

        char buf[BUF_SIZE];
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            perror("recv");
            close(fd);
            return 7;
        }
        buf[n] = '\0';
        printf("%s\n", buf);
        fflush(stdout);
        count++;
    }

    printf("TGAT_RX_COUNT=%lu\n", count);
    close(fd);
    return 0;
}
