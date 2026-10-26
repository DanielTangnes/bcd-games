// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDGraphicsRoutes.c: see BCDGraphicsRoutes.h.

#include "BCDGraphicsRoutes.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

const BCDWowRoute bcd_wow_routes[] = {
    { "MADEIRA_D3D8", "d3d9", "d3d8.dll", "d3d8to9.dll", "Direct3D 8 on Direct3D 9, DXMT's" },
    { "MADEIRA_DDRAW", "cnc", "ddraw.dll", "cnc-ddraw.dll", "cnc-ddraw, DirectDraw drawn through Direct3D 9" },
};
const int bcd_wow_route_count = (int)(sizeof(bcd_wow_routes) / sizeof(bcd_wow_routes[0]));

int bcd_wow_route_apply(const BCDWowRoute *route, const char *envValue, const char *syswow64Dir, const char *i386Dir, char *line, size_t lineSize)
{
    char source[PATH_MAX], link[PATH_MAX], temp[PATH_MAX + 16];

    if (line && lineSize) line[0] = 0;
    if (!route || !envValue || strcmp(envValue, route->value) != 0) return 0;
    if (snprintf(source, sizeof(source), "%s/%s", i386Dir, route->source) >= (int)sizeof(source) ||
        snprintf(link, sizeof(link), "%s/%s", syswow64Dir, route->target) >= (int)sizeof(link))
        return -1;
    if (access(source, R_OK) != 0)
    {
        if (line) snprintf(line, lineSize, "[WineProc] %s=%s but this build has no %s -- Wine's %s stays\n",
                           route->env, route->value, route->source, route->target);
        return -1;
    }
    /* Made under a name of its own and renamed over the farm's link (atomic): if anything fails, Wine's DLL is still there. */
    if (snprintf(temp, sizeof(temp), "%s.bcd-new", link) >= (int)sizeof(temp)) return -1;
    unlink(temp);
    if (symlink(source, temp) != 0 || rename(temp, link) != 0)
    {
        unlink(temp);
        if (line) snprintf(line, lineSize, "[WineProc] %s=%s: linking %s failed -- Wine's %s stays\n",
                           route->env, route->value, route->source, route->target);
        return -1;
    }
    if (line) snprintf(line, lineSize, "[WineProc] %s=%s: %s -> %s (%s; syswow64)\n", route->env, route->value, route->target, route->source, route->what);
    return 1;
}

int bcd_wow_routes_apply(const char *syswow64Dir, const char *i386Dir, int fd)
{
    int linked = 0;
    char line[512];

    for (int i = 0; i < bcd_wow_route_count; i++)
    {
        const BCDWowRoute *route = &bcd_wow_routes[i];
        int result = bcd_wow_route_apply(route, getenv(route->env), syswow64Dir, i386Dir, line, sizeof(line));
        if (result == 1) linked++;
        if (result != 0 && line[0]) { ssize_t ignored = write(fd, line, strlen(line)); (void)ignored; }
    }
    return linked;
}
