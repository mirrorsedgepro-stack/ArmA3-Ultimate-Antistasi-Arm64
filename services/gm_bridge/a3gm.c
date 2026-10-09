/* A3GM: minimal callExtension spool reader for the OpenClaw Game Master.
 *
 *   "a3gm" callExtension "version"  -> version string
 *   "a3gm" callExtension "poll"     -> oldest command in $A3GM_SPOOL/inbox (default
 *                                      /arma3/gm_spool/inbox), deleted after reading; "" if none
 *
 * Commands are SQF arrays for parseSimpleArray, written by the Game Master as <name>.cmd
 * (atomically, via a temp name the poller ignores). Names sort in the order to run them.
 * The extension never interprets commands; the SQF side only runs whitelisted actions.
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))
#define VERSION "a3gm 1"

static const char *inbox(void)
{
    static char path[512];
    if (!path[0]) {
        const char *root = getenv("A3GM_SPOOL");
        snprintf(path, sizeof path, "%s/inbox", root && *root ? root : "/arma3/gm_spool");
    }
    return path;
}

static int is_cmd(const char *name)
{
    size_t n = strlen(name);
    return name[0] != '.' && n > 4 && strcmp(name + n - 4, ".cmd") == 0;
}

static void poll_inbox(char *output, unsigned int size)
{
    DIR *d = opendir(inbox());
    if (!d)
        return;
    char best[256] = "";
    struct dirent *e;
    while ((e = readdir(d))) {
        if (is_cmd(e->d_name) && strlen(e->d_name) < sizeof best &&
            (!best[0] || strcmp(e->d_name, best) < 0))
            strcpy(best, e->d_name);
    }
    closedir(d);
    if (!best[0])
        return;

    char file[800];
    snprintf(file, sizeof file, "%s/%s", inbox(), best);
    FILE *f = fopen(file, "rb");
    if (f) {
        size_t n = fread(output, 1, size - 1, f);
        output[n] = '\0';
        fclose(f);
    }
    unlink(file);
}

EXPORT void RVExtensionVersion(char *output, unsigned int size)
{
    snprintf(output, size, "%s", VERSION);
}

EXPORT void RVExtension(char *output, unsigned int size, const char *function)
{
    output[0] = '\0';
    if (strcmp(function, "poll") == 0)
        poll_inbox(output, size);
    else if (strcmp(function, "version") == 0)
        snprintf(output, size, "%s", VERSION);
}
