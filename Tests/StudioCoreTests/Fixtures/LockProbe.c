#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sqlite3.h>
int main(int argc, char **argv) {
    if (argc < 3) return 64;
    int fd = open(argv[1], O_CREAT | O_RDWR, 0600);
    if (fd < 0) return 74;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) return 73;
    if (strcmp(argv[2], "crash-writer") == 0) {
        if (argc != 4) return 64;
        sqlite3 *database = 0;
        if (sqlite3_open(argv[3], &database) != SQLITE_OK) return 75;
        if (sqlite3_exec(database,
            "PRAGMA synchronous=FULL; BEGIN IMMEDIATE; UPDATE jobs SET state='requesting'; COMMIT;"
            "BEGIN IMMEDIATE; INSERT INTO projects(id,revision,fields) VALUES('uncommitted-project',1,x'7b7d');",
            0, 0, 0) != SQLITE_OK) return 76;
        write(STDOUT_FILENO, "R", 1);
        for (;;) pause();
    }
    if (strcmp(argv[2], "hold") == 0) {
        write(STDOUT_FILENO, "R", 1);
        for (;;) pause();
    }
    close(fd);
    return 0;
}
