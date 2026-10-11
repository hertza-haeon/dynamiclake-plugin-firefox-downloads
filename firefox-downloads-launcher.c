/* Copyright (c) 2026 Hertza Haeon
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/*
 * firefox-downloads-launcher
 *
 * What DynamicLake starts for the Firefox Downloads plugin. It does one
 * thing: it runs firefox_downloads.py, the plugin itself, which lies beside
 * it, with the Mac's python3, and steps aside. The Python process takes this
 * one's place: same process, same environment, same arguments.
 *
 * python3 is looked for the way "/usr/bin/env python3" does it, along PATH;
 * failing that, Apple's own, /usr/bin/python3, is tried.
 *
 * It reads nothing but its own location, writes nothing, and starts nothing
 * else.
 *
 * Build (both kinds of Mac in one file):
 *
 *   cc -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -Wall -Wextra \
 *      -o firefox-downloads-launcher firefox-downloads-launcher.c
 */

#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NAME "firefox-downloads-launcher"
#define SCRIPT "firefox_downloads.py"

int main(int argc, char *argv[]) {
    char given[PATH_MAX];
    char folder[PATH_MAX];
    char script[PATH_MAX];
    uint32_t size = sizeof(given);

    /* The folder this program is in (links followed): the plugin's. */
    if (_NSGetExecutablePath(given, &size) != 0 || realpath(given, folder) == NULL) {
        fprintf(stderr, NAME ": can't tell where it is\n");
        return 1;
    }
    char *slash = strrchr(folder, '/');
    if (slash == NULL) {
        fprintf(stderr, NAME ": can't tell which folder it is in\n");
        return 1;
    }
    *slash = '\0';

    /* The plugin, beside it. */
    int length = snprintf(script, sizeof(script), "%s/%s", folder, SCRIPT);
    if (length < 0 || (size_t)length >= sizeof(script)) {
        fprintf(stderr, NAME ": the path to " SCRIPT " is too long\n");
        return 1;
    }
    if (access(script, R_OK) != 0) {
        fprintf(stderr, NAME ": " SCRIPT " isn't beside it, or can't be read\n");
        return 1;
    }

    /* python3 <the plugin> <whatever arguments this program was given> */
    int given_count = argc > 1 ? argc - 1 : 0;
    char **args = calloc((size_t)given_count + 3, sizeof(char *));
    if (args == NULL) {
        fprintf(stderr, NAME ": out of memory\n");
        return 1;
    }
    args[0] = "python3";
    args[1] = script;
    for (int i = 0; i < given_count; i++) {
        args[i + 2] = argv[i + 1];
    }
    args[given_count + 2] = NULL;

    execvp("python3", args);           /* along PATH, as "env python3" does */
    execv("/usr/bin/python3", args);   /* Apple's own */

    fprintf(stderr, NAME ": python3 was not found (%s)\n", strerror(errno));
    return 127;
}
