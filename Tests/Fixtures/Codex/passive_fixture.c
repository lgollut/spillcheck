#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* Controlled test server: records only its PID; no source/event payload is persisted. */
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        char versionmode[32] = "normal";
        FILE *versionfile = fopen("mode", "r");
        if (versionfile) { fscanf(versionfile, "%31s", versionmode); fclose(versionfile); }
        puts(strcmp(versionmode, "invalid-version") == 0 ? "another-program 4.0.0" :
             strcmp(versionmode, "new-version") == 0 ? "codex-cli 4.0.0" : "codex-cli 0.161.0");
        return 0;
    }
    FILE *pidfile = fopen("server.pid", "w");
    if (pidfile) { fprintf(pidfile, "%d\n", getpid()); fclose(pidfile); }
    char mode[32] = "normal";
    FILE *modefile = fopen("mode", "r");
    if (modefile) { fscanf(modefile, "%31s", mode); fclose(modefile); }
    char *line = NULL; size_t capacity = 0;
    while (getline(&line, &capacity, stdin) > 0) {
        /* JSONEncoder may escape slashes in controlled method strings. */
        for (char *p = line; *p; p++) if (p[0] == '\\' && p[1] == '/') memmove(p, p + 1, strlen(p));
        char *id = strstr(line, "\"id\":");
        if (!id) continue;
        int serial = atoi(id + 5);
        if (strstr(line, "\"initialize\"")) {
            printf("{\"id\":%d,\"result\":{}}\n", serial); fflush(stdout); continue;
        }
        modefile = fopen("mode", "r");
        if (modefile) { fscanf(modefile, "%31s", mode); fclose(modefile); }
        if (!strstr(line, "\"thread/read\"") && !strstr(line, "\"thread/list\"") &&
            !strstr(line, "\"thread/turns/list\"") && !strstr(line, "\"thread/items/list\"")) return 4;
        if (strcmp(mode, "timeout") == 0) { printf("{\"id\":%d,", serial); fflush(stdout); for (;;) pause(); }
        if (strcmp(mode, "unsafe") == 0) {
            puts("{\"id\":77,\"method\":\"item/commandExecution/requestApproval\",\"params\":{}}"); fflush(stdout); continue;
        }
        if (strcmp(mode, "malformed") == 0) { puts("not-json"); fflush(stdout); continue; }
        if (strcmp(mode, "remote") == 0) {
            printf("{\"id\":%d,\"error\":{\"code\":-32001,\"message\":\"ignored synthetic diagnostic\"}}\n", serial); fflush(stdout); continue;
        }
        if (strcmp(mode, "missing-method") == 0 || strcmp(mode, "rejected-parameters") == 0) {
            printf("{\"id\":%d,\"error\":{\"code\":%d,\"message\":\"ignored controlled diagnostic\"}}\n", serial,
                strcmp(mode, "missing-method") == 0 ? -32601 : -32602);
            fflush(stdout); continue;
        }
        if (strcmp(mode, "flood") == 0) {
            printf("{\"id\":%d,\"result\":{\"padding\":\"", serial);
            for (int i = 0; i < 16384; i++) putchar('x');
            puts("\"}}"); fflush(stdout); continue;
        }
        if (!strstr(line, "\"thread/read\"")) {
            printf("{\"id\":%d,\"result\":{\"data\":[],\"nextCursor\":null,\"backwardsCursor\":null,\"extraEnvelope\":true}}\n", serial);
            fflush(stdout); continue;
        }
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(9), .sin_addr.s_addr = htonl(0x7f000001) };
        int networkDenied = fd < 0 && errno == EPERM;
        if (fd >= 0) { networkDenied = connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0 && errno == EPERM; close(fd); }
        pid_t child = fork();
        int forkDenied = child < 0 && errno == EPERM;
        if (child == 0) _exit(5);
        int sanitized = getenv("PATH") && strcmp(getenv("PATH"), "/usr/bin:/bin") == 0 &&
            !getenv("SSH_AUTH_SOCK") && !getenv("OPENAI_API_KEY") && !getenv("DYLD_INSERT_LIBRARIES");
        printf("{\"id\":%d,\"result\":{\"thread\":{\"id\":\"synthetic\",\"cliVersion\":\"0.161.0\",\"networkDenied\":%s,\"forkDenied\":%s,\"environmentSanitized\":%s}}}\n",
            serial, networkDenied ? "true" : "false", forkDenied ? "true" : "false", sanitized ? "true" : "false");
        fflush(stdout);
        if (strcmp(mode, "closed-streams") == 0) {
            signal(SIGTERM, SIG_IGN);
            close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
            for (;;) pause();
        }
    }
    free(line); return 0;
}
