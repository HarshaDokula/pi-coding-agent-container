#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <dirent.h>

/*
 * gh-vault: read the GitHub token from the Docker secret and hand it to
 * gh-guard, then exec the guard.
 *
 * This binary used to be installed setuid root (mode 4755) so it could read a
 * mode-0400 secret. Docker Compose mounts secrets 0444, i.e. already readable
 * by the container user, so the elevation granted no additional access while
 * adding a local root-escalation primitive to the image. It now runs as the
 * invoking user; the container is started with cap_drop: ALL and
 * no-new-privileges (SECURITY.md, C1).
 */
int main(int argc, char **argv) {
    (void)argc;

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

    argv[0] = "/usr/local/bin/gh-guard";
    execv("/usr/local/bin/gh-guard", argv);

    return 1;
}
