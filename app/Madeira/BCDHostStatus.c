// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDHostStatus.c
//
//  See BCDHostStatus.h. The file is key=value lines, one per line, ASCII; tests/systests/core.h reads it (host_parse_info):
//
//    format=1  build= version= model= os=  ram_mb= cores=  limit_mb=  increased_memory= extended_va= address_map_gb=
//    pool_cfg_mb= swap_mb=
//
//  limit_mb is the memory limit iOS gives this app, measured the way the engine measures it (virtual_ios.c, ml992): what iOS
//  says is still available plus what it already charges (phys_footprint). Their sum does not change while the app runs.
//  A "no limit" answer larger than the device's RAM is not a measurement and gives limit_mb=0.

#include "BCDHostStatus.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <TargetConditionals.h>
#include <mach/mach.h>

#if TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
/* The same two calls EntitlementChecker.swift reaches with @_silgen_name. */
typedef struct __SecTask *BCDSecTaskRef;
extern BCDSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(BCDSecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
extern size_t os_proc_available_memory(void);
#endif

/* ---------------------------------------------------------------- wanted */

static int is_zero(const char *s) { return s && s[0] == '0' && !s[1]; }

static int base_is_explorer(const char *exe)
{
    const char *base = exe, *p;
    if (!exe) return 0;
    for (p = exe; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
    return strcasecmp(base, "explorer.exe") == 0;
}

int bcd_host_status_wanted(const char *desktop, const char *dock_session, const char *exe, const char *host_status)
{
    if (!desktop || desktop[0] != '1') return 0;
    if (dock_session && dock_session[0] == '1') return 0;
    if (is_zero(host_status)) return 0;
    return base_is_explorer(exe);
}

/* ---------------------------------------------------------------- facts */

static unsigned long long sysctl_u64(const char *name)
{
    unsigned long long v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    if (len == sizeof(unsigned int)) return *(unsigned int *)&v;
    return v;
}

static void sysctl_str(const char *name, char *out, size_t cap)
{
    size_t len = cap;
    out[0] = 0;
    if (sysctlbyname(name, out, &len, NULL, 0) != 0) out[0] = 0;
    out[cap - 1] = 0;
}

/* The text is a plain line: nothing that could start a second key. */
static void clean(char *s)
{
    for (; *s; s++) if (*s == '\n' || *s == '\r' || (unsigned char)*s < 0x20 || (unsigned char)*s >= 0x7f) *s = ' ';
}

#if TARGET_OS_IPHONE
static int entitlement(const char *name)
{
    BCDSecTaskRef task = SecTaskCreateFromSelf(NULL);
    CFStringRef key;
    CFTypeRef v;
    int r = -1;

    if (!task) return -1;
    key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (key) {
        v = SecTaskCopyValueForEntitlement(task, key, NULL);
        if (v) {
            if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
            else r = 0;
            CFRelease(v);
        } else r = 0;
        CFRelease(key);
    }
    CFRelease(task);
    return r;
}
#endif

size_t bcd_host_info_text(const bcd_host_facts *facts, char *out, size_t cap)
{
    char model[64], osver[48], osbuild[48], os[110], build[40], version[40];
    unsigned long long ram = sysctl_u64("hw.memsize"), cores = sysctl_u64("hw.ncpu"), limit = 0, map_gb = 0;
    int inc = -1, ext = -1, n;

    sysctl_str("hw.machine", model, sizeof(model));
    sysctl_str("kern.osproductversion", osver, sizeof(osver));
    sysctl_str("kern.osversion", osbuild, sizeof(osbuild));
    snprintf(os, sizeof(os), "%s%s%s%s%s", osver[0] ? "iOS " : "", osver, osbuild[0] ? " (" : "", osbuild, osbuild[0] ? ")" : "");
    snprintf(build, sizeof(build), "%s", facts && facts->build ? facts->build : "");
    snprintf(version, sizeof(version), "%s", facts && facts->version ? facts->version : "");
    clean(model); clean(os); clean(build); clean(version);

    {
        task_vm_info_data_t vmi;
        mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
        memset(&vmi, 0, sizeof(vmi));
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt) == KERN_SUCCESS) {
            if (vmi.max_address > vmi.min_address) map_gb = (unsigned long long)(vmi.max_address - vmi.min_address) >> 30;
#if TARGET_OS_IPHONE
            {
                unsigned long long avail = (unsigned long long)os_proc_available_memory();
                unsigned long long sum = avail + (unsigned long long)vmi.phys_footprint;
                /* a "no limit" sentinel (the answer is far larger than the device) is not a measurement */
                if (avail && (!ram || sum <= ram)) limit = sum >> 20;
            }
#endif
        }
    }
#if TARGET_OS_IPHONE
    inc = entitlement("com.apple.developer.kernel.increased-memory-limit");
    ext = entitlement("com.apple.developer.kernel.extended-virtual-addressing");
#endif

    n = snprintf(out, cap,
                 "format=1\nbuild=%s\nversion=%s\nmodel=%s\nos=%s\nram_mb=%llu\ncores=%llu\nlimit_mb=%llu\n",
                 build, version, model, os, ram >> 20, cores, limit);
    if (n < 0 || (size_t)n >= cap) return 0;
    {
        int m = snprintf(out + n, cap - (size_t)n, "address_map_gb=%llu\npool_cfg_mb=%llu\nswap_mb=%llu\n", map_gb,
                         facts ? facts->pool_cfg_mb : 0, facts ? facts->swap_mb : 0);
        if (m < 0 || (size_t)m >= cap - (size_t)n) return 0;
        n += m;
    }
    if (inc >= 0) {
        int m = snprintf(out + n, cap - (size_t)n, "increased_memory=%d\n", inc);
        if (m < 0 || (size_t)m >= cap - (size_t)n) return 0;
        n += m;
    }
    if (ext >= 0) {
        int m = snprintf(out + n, cap - (size_t)n, "extended_va=%d\n", ext);
        if (m < 0 || (size_t)m >= cap - (size_t)n) return 0;
        n += m;
    }
    return (size_t)n;
}

/* ---------------------------------------------------------------- the prefix */

static int make_dir(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0) return S_ISDIR(st.st_mode);
    return mkdir(path, 0755) == 0 || errno == EEXIST;
}

int bcd_host_status_prepare(const char *prefix, const bcd_host_facts *facts)
{
    char dir[PATH_MAX], file[PATH_MAX], tmp[PATH_MAX], text[1024];
    size_t len, done = 0;
    int fd;

    if (!prefix || !*prefix) return 0;
    if (snprintf(dir, sizeof(dir), "%s/drive_c/ProgramData", prefix) >= (int)sizeof(dir) || !make_dir(dir)) return 0;
    if (snprintf(dir, sizeof(dir), "%s/drive_c/ProgramData/BCD", prefix) >= (int)sizeof(dir) || !make_dir(dir)) return 0;
    if (snprintf(file, sizeof(file), "%s/host-info.txt", dir) >= (int)sizeof(file) ||
        snprintf(tmp, sizeof(tmp), "%s/host-info.tmp", dir) >= (int)sizeof(tmp)) return 0;
    len = bcd_host_info_text(facts, text, sizeof(text));
    if (!len) return 0;
    fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 0;
    while (done < len) {
        ssize_t n = write(fd, text + done, len - done);
        if (n <= 0) { close(fd); unlink(tmp); return 0; }
        done += (size_t)n;
    }
    close(fd);
    if (rename(tmp, file) != 0) { unlink(tmp); return 0; }
    /* The old live file of an earlier session is not this session's: gone before the engine writes the first new one. */
    {
        char live[PATH_MAX];
        if (snprintf(live, sizeof(live), "%s/host-live.txt", dir) < (int)sizeof(live)) unlink(live);
    }
    setenv("MADEIRA_HOST_STATUS", dir, 1);
    return 1;
}
