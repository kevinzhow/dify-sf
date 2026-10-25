// Test-only child launcher: Swift's async runner may block signals before spawning a subprocess.
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 64;
    sigset_t mask;
    sigemptyset(&mask);
    if (sigprocmask(SIG_SETMASK, &mask, NULL)) return 70;
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    execv(argv[1], argv + 1);
    perror("test child exec");
    return 71;
}
