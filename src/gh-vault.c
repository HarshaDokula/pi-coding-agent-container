#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <dirent.h>

int main(int argc, char **argv) {
    uid_t uid = getuid();
    gid_t gid = getgid();

    if (setuid(0) != 0) return 1;

    DIR *d = opendir("/run/secrets");
    if (d) {
        struct dirent *dir;
        while ((dir = readdir(d)) != NULL) {
            if (strncmp(dir->d_name, "gh_", 3) == 0) {
                char path[512];
                snprintf(path, sizeof(path), "/run/secrets/%s", dir->d_name);
                FILE *f = fopen(path, "r");
                if (f) {
                    char t[256];
                    if (fgets(t, sizeof(t), f)) {
                        t[strcspn(t, "\r\n")] = 0;
                        // Skip empty values and the "unset" placeholder written
                        // by setup when no GITHUB_TOKEN is configured.
                        if (t[0] != '\0' && strcmp(t, "unset") != 0) {
                            setenv("GITHUB_TOKEN", t, 1);
                            setenv("GH_TOKEN", t, 1);
                        }
                    }
                    fclose(f);
                }
                break;
            }
        }
        closedir(d);
    }

    // Fully purge privilege boundaries (Real, Effective, Saved)
    // Failure to clear saved-UID triggers bash restricted modes which strip environment vars.
    if (setresgid(gid, gid, gid) != 0) return 1;
    if (setresuid(uid, uid, uid) != 0) return 1;

    argv[0] = "/usr/local/bin/gh-guard";
    execv("/usr/local/bin/gh-guard", argv);
    
    return 1;
}
