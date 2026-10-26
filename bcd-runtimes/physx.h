// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// physx.h: NVIDIA PhysX System Software 9.21.0713, put in place the way its own installer does, without running that installer.
//
// The download is NVIDIA's PhysX_9.21.0713_SystemSoftware.exe, a 7-Zip self-extractor around NVIDIA's "NVI2" installer (a 5 MB engine
// with its own interface, a system service and two kernel driver files; the extractor passes no command-line switches on, so it cannot
// be run silently). What that installer does for this package is written down in the package itself, in PhysX\PhysX.nvi: copy
// these files below "NVIDIA Corporation\PhysX" in the 32-bit Program Files, write these registry values (the 32-bit view, and the
// 64-bit view too on a 64-bit Windows), put the Common folder on the system PATH, and confirm that Common\PhysXLoader.dll is there.
// The tables below are that list, nothing added and nothing left out (generated from the manifest of the pinned file, whose SHA-256
// is in core.h). BCD unpacks the package with its own 7z.exe (tools/build-7zip.py) into a folder of its own and applies the list.
// Nothing here starts NVIDIA's setup program, its service or its drivers, which have no place in a Wine desktop.
//
// px_install does the work through a small table of functions (px_host), so the host check runs it against a fake disk and a fake registry.

#ifndef BCD_RUNTIMES_PHYSX_H
#define BCD_RUNTIMES_PHYSX_H

#include "core.h"

#define PX_LOC "C:\\Program Files (x86)\\NVIDIA Corporation\\PhysX"
#define PX_VERSION_DWORD 9210713u
#define PX_PATH_ENTRY PX_LOC "\\Common"

typedef struct {
    const char *src;      /* below PhysX\files in the package */
    const char *dst;      /* below PX_LOC */
    int amd64;            /* only on a 64-bit Windows */
} px_copy;

typedef enum { PX_NONE = 0, PX_SZ, PX_DWORD, PX_MULTI } px_type;

typedef struct {
    int view;             /* 32 or 64: the registry view the installer writes it in */
    const char *key;      /* below HKEY_LOCAL_MACHINE */
    const char *name;     /* NULL: only the key is made; "": the key's default value */
    px_type type;
    const char *sz;       /* for PX_SZ and PX_MULTI (one string) */
    unsigned dword;       /* for PX_DWORD */
} px_reg;

static const px_copy px_copies[] = {
    { "Common\\cudart64_65.dll", "Common\\cudart64_65.dll", 1 },
    { "Common\\PhysXDevice64.dll", "Common\\PhysXDevice64.dll", 1 },
    { "Common\\PhysXLoader64.dll", "Common\\PhysXLoader64.dll", 1 },
    { "Common\\PhysXUpdateLoader64.dll", "Common\\PhysXUpdateLoader64.dll", 1 },
    { "Engine\\v2.8.3\\PhysXCooking64.dll", "Engine\\v2.8.3\\PhysXCooking64.dll", 1 },
    { "Engine\\v2.8.3\\PhysXCore64.dll", "Engine\\v2.8.3\\PhysXCore64.dll", 1 },
    { "Common\\cudart32_65.dll", "Common\\cudart32_65.dll", 0 },
    { "Common\\PhysXDevice.dll", "Common\\PhysXDevice.dll", 0 },
    { "Common\\PhysXLoader.dll", "Common\\PhysXLoader.dll", 0 },
    { "Common\\PhysXUpdateLoader.dll", "Common\\PhysXUpdateLoader.dll", 0 },
    { "Engine\\A_Ball_Trans.ico", "Engine\\A_Ball_Trans.ico", 0 },
    { "Engine\\07022E82A068\\GRB_1_x86.dll", "Engine\\07022E82A068\\GRB_1_x86.dll", 0 },
    { "Engine\\4F8D3BB436C7\\APEX_ParticlesCHECKED_x86.dll", "Engine\\4F8D3BB436C7\\APEX_ParticlesCHECKED_x86.dll", 0 },
    { "Engine\\4F8D3BB436C7\\APEX_TurbulenceFSCHECKED_x86.dll", "Engine\\4F8D3BB436C7\\APEX_TurbulenceFSCHECKED_x86.dll", 0 },
    { "Engine\\4F8D3BB436C7\\PhysXCore.dll", "Engine\\4F8D3BB436C7\\PhysXCore.dll", 0 },
    { "Engine\\4F8D3BB436C7\\ImplicitLibs\\PhysX3GpuCHECKED_x86.dll", "Engine\\4F8D3BB436C7\\ImplicitLibs\\PhysX3GpuCHECKED_x86.dll", 0 },
    { "Engine\\73BE2921551D\\APEX_BasicFSCHECKED_x86.dll", "Engine\\73BE2921551D\\APEX_BasicFSCHECKED_x86.dll", 0 },
    { "Engine\\73BE2921551D\\APEX_BasicIOSCHECKED_x86.dll", "Engine\\73BE2921551D\\APEX_BasicIOSCHECKED_x86.dll", 0 },
    { "Engine\\73BE2921551D\\APEX_FieldSamplerCHECKED_x86.dll", "Engine\\73BE2921551D\\APEX_FieldSamplerCHECKED_x86.dll", 0 },
    { "Engine\\73BE2921551D\\APEX_IOFXCHECKED_x86.dll", "Engine\\73BE2921551D\\APEX_IOFXCHECKED_x86.dll", 0 },
    { "Engine\\73BE2921551D\\APEX_TurbulenceFSCHECKED_x86.dll", "Engine\\73BE2921551D\\APEX_TurbulenceFSCHECKED_x86.dll", 0 },
    { "Engine\\73BE2921551D\\PhysXCore.dll", "Engine\\73BE2921551D\\PhysXCore.dll", 0 },
    { "Engine\\73BE2921551D\\ImplicitLibs\\cudart32_65.dll", "Engine\\73BE2921551D\\ImplicitLibs\\cudart32_65.dll", 0 },
    { "Engine\\73BE2921551D\\ImplicitLibs\\PhysX3GpuCHECKED_x86.dll", "Engine\\73BE2921551D\\ImplicitLibs\\PhysX3GpuCHECKED_x86.dll", 0 },
    { "Engine\\A0A1369354E1\\APEX_Particles_x86.dll", "Engine\\A0A1369354E1\\APEX_Particles_x86.dll", 0 },
    { "Engine\\A0A1369354E1\\APEX_TurbulenceFS_x86.dll", "Engine\\A0A1369354E1\\APEX_TurbulenceFS_x86.dll", 0 },
    { "Engine\\A0A1369354E1\\PhysX3Gpu_x86.dll", "Engine\\A0A1369354E1\\PhysX3Gpu_x86.dll", 0 },
    { "Engine\\86C5F4F22ECD\\APEX_Particles_x64.dll", "Engine\\86C5F4F22ECD\\APEX_Particles_x64.dll", 0 },
    { "Engine\\86C5F4F22ECD\\APEX_TurbulenceFS_x64.dll", "Engine\\86C5F4F22ECD\\APEX_TurbulenceFS_x64.dll", 0 },
    { "Engine\\86C5F4F22ECD\\ImplicitLibs\\PhysX3Gpu_x64.dll", "Engine\\86C5F4F22ECD\\ImplicitLibs\\PhysX3Gpu_x64.dll", 0 },
    { "Engine\\5182B3C9EFEC\\PhysXCore.dll", "Engine\\5182B3C9EFEC\\PhysXCore.dll", 0 },
    { "Engine\\549B931E903E\\PhysXCore.dll", "Engine\\549B931E903E\\PhysXCore.dll", 0 },
    { "Engine\\6FE164B5308A\\PhysXCore.dll", "Engine\\6FE164B5308A\\PhysXCore.dll", 0 },
    { "Engine\\82D8704BAB07\\PhysXCore.dll", "Engine\\82D8704BAB07\\PhysXCore.dll", 0 },
    { "Engine\\B1E4CC1EB042\\PhysXCore.dll", "Engine\\B1E4CC1EB042\\PhysXCore.dll", 0 },
    { "Engine\\C22346819C37\\PhysXCore.dll", "Engine\\C22346819C37\\PhysXCore.dll", 0 },
    { "Engine\\F232A762B0C8\\PhysXCore.dll", "Engine\\F232A762B0C8\\PhysXCore.dll", 0 },
    { "Engine\\v2.7.1\\NxCooking.dll", "Engine\\v2.7.1\\PhysXCooking.dll", 0 },
    { "Engine\\v2.7.1\\PhysXCore.dll", "Engine\\v2.7.1\\PhysXCore.dll", 0 },
    { "Engine\\v2.7.3\\NxCooking.dll", "Engine\\v2.7.3\\PhysXCooking.dll", 0 },
    { "Engine\\v2.7.3\\PhysXCore.dll", "Engine\\v2.7.3\\PhysXCore.dll", 0 },
    { "Engine\\v2.7.4\\NxCooking.dll", "Engine\\v2.7.4\\PhysXCooking.dll", 0 },
    { "Engine\\v2.7.4\\PhysXCore.dll", "Engine\\v2.7.4\\PhysXCore.dll", 0 },
    { "Engine\\v2.7.5\\NxCooking.dll", "Engine\\v2.7.5\\PhysXCooking.dll", 0 },
    { "Engine\\v2.7.5\\PhysXCore.dll", "Engine\\v2.7.5\\PhysXCore.dll", 0 },
    { "Engine\\v2.7.6\\NxCooking.dll", "Engine\\v2.7.6\\PhysXCooking.dll", 0 },
    { "Engine\\v2.7.6\\PhysXCore.dll", "Engine\\v2.7.6\\PhysXCore.dll", 0 },
    { "Engine\\v2.8.0\\NxCooking.dll", "Engine\\v2.8.0\\PhysXCooking.dll", 0 },
    { "Engine\\v2.8.0\\PhysXCore.dll", "Engine\\v2.8.0\\PhysXCore.dll", 0 },
    { "Engine\\v2.8.1\\NxCooking.dll", "Engine\\v2.8.1\\PhysXCooking.dll", 0 },
    { "Engine\\v2.8.1\\PhysXCore.dll", "Engine\\v2.8.1\\PhysXCore.dll", 0 },
    { "Engine\\v2.8.3\\PhysXCooking.dll", "Engine\\v2.8.3\\PhysXCooking.dll", 0 },
    { "Engine\\v2.8.3\\PhysXCore.dll", "Engine\\v2.8.3\\PhysXCore.dll", 0 },
};

static const px_reg px_regs[] = {
    { 32, "SOFTWARE\\AGEIA Technologies", NULL, PX_NONE, "", 0 },
    { 32, "SOFTWARE\\AGEIA Technologies", "HwSelection", PX_SZ, "GPU", 0 },
    { 32, "SOFTWARE\\AGEIA Technologies", "PhysXCore Path", PX_SZ, PX_LOC "\\Engine", 0 },
    { 32, "SOFTWARE\\AGEIA Technologies", "PhysX Version", PX_DWORD, "", 9210713u },
    { 32, "SOFTWARE\\AGEIA Technologies", "PhysX (GPU) Version", PX_DWORD, "", 9210713u },
    { 32, "SOFTWARE\\AGEIA Technologies", "PhysX BuildCL", PX_DWORD, "", 0u },
    { 32, "SOFTWARE\\AGEIA Technologies\\EnableQuietMode", "", PX_SZ, "", 0 },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.7.1", PX_DWORD, "", 43u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.7.3", PX_DWORD, "", 53u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.7.4", PX_DWORD, "", 33u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.7.5", PX_DWORD, "", 40u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.7.6", PX_DWORD, "", 33u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.8.0", PX_DWORD, "", 42u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.8.1", PX_DWORD, "", 54u },
    { 32, "SOFTWARE\\AGEIA Technologies\\PhysX_A32_Engines", "2.8.3", PX_DWORD, "", 43u },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysX_SystemSoftware", "PhysX (GPU) Version", PX_SZ, "9.21.0713", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysX_SystemSoftware", "PhysXCore Path", PX_SZ, PX_LOC "\\Engine", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader", NULL, PX_NONE, "", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable", NULL, PX_NONE, "", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\1F0D3CC8-ADDF-49b3-87B3-F232A762B0C8", "dll_path", PX_SZ, PX_LOC "\\Engine\\F232A762B0C8\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\26097F37-C68B-4fc0-AA37-6FE164B5308A", "dll_path", PX_SZ, PX_LOC "\\Engine\\6FE164B5308A\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\3F527913-C421-4c9b-BDBA-C22346819C37", "dll_path", PX_SZ, PX_LOC "\\Engine\\C22346819C37\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\56C8B958-C577-4BC6-AEB7-4F8D3BB436C7", "dll_base_directory", PX_SZ, PX_LOC "\\Engine\\4F8D3BB436C7\\", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\56C8B958-C577-4BC6-AEB7-4F8D3BB436C7", "ImplicitLibs", PX_MULTI, PX_LOC "\\Engine\\4F8D3BB436C7\\ImplicitLibs\\PhysX3GpuCHECKED_x86.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\5A9F1682-9FE0-4c7f-A50E-5182B3C9EFEC", "dll_path", PX_SZ, PX_LOC "\\Engine\\5182B3C9EFEC\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\62849F71-B304-487f-BA78-82D8704BAB07", "dll_path", PX_SZ, PX_LOC "\\Engine\\82D8704BAB07\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\974EB307-2545-477A-90DA-07022E82A068", "dll_path", PX_SZ, PX_LOC "\\Engine\\07022E82A068\\GRB_1_x86.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\B1BD90FB-BC49-428a-8FF1-549B931E903E", "dll_path", PX_SZ, PX_LOC "\\Engine\\549B931E903E\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\B7525822-D374-43c2-8843-B1E4CC1EB042", "dll_path", PX_SZ, PX_LOC "\\Engine\\B1E4CC1EB042\\PhysXCore.dll", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\7E3AE57C-FA76-4bd3-9CC6-A0A1369354E1", "dll_base_directory", PX_SZ, PX_LOC "\\Engine\\A0A1369354E1\\", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\844243E3-18C6-4CF2-86FB-73BE2921551D", "dll_base_directory", PX_SZ, PX_LOC "\\Engine\\73BE2921551D\\", 0 },
    { 32, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\844243E3-18C6-4CF2-86FB-73BE2921551D", "ImplicitLibs", PX_MULTI, PX_LOC "\\Engine\\73BE2921551D\\ImplicitLibs\\PhysX3GpuCHECKED_x86.dll", 0 },
    { 64, "SOFTWARE\\AGEIA Technologies", "HwSelection", PX_SZ, "GPU", 0 },
    { 64, "SOFTWARE\\AGEIA Technologies", "PhysX Version", PX_DWORD, "", 9210713u },
    { 64, "SOFTWARE\\AGEIA Technologies", "PhysXCore Path", PX_SZ, PX_LOC "\\Engine", 0 },
    { 64, "SOFTWARE\\AGEIA Technologies", "PhysX BuildCL", PX_DWORD, "", 1u },
    { 64, "SOFTWARE\\AGEIA Technologies\\PhysX_A64_Engines", NULL, PX_NONE, "", 0 },
    { 64, "SOFTWARE\\AGEIA Technologies\\PhysX_A64_Engines", "2.8.3", PX_DWORD, "", 44u },
    { 64, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\351C9090-206D-4915-AF80-86C5F4F22ECD", "dll_base_directory", PX_SZ, PX_LOC "\\Engine\\86C5F4F22ECD\\", 0 },
    { 64, "SOFTWARE\\NVIDIA Corporation\\PhysXUpdateLoader\\DllTable\\351C9090-206D-4915-AF80-86C5F4F22ECD", "ImplicitLibs", PX_MULTI, PX_LOC "\\Engine\\86C5F4F22ECD\\ImplicitLibs\\PhysX3Gpu_x64.dll", 0 },
};

#define PX_COPY_COUNT (sizeof px_copies / sizeof px_copies[0])
#define PX_REG_COUNT (sizeof px_regs / sizeof px_regs[0])

/* What px_install needs from the system. Every function returns 0 for success unless said otherwise. */
typedef struct {
    int (*exists)(void *ctx, const char *path);                               /* 1 when the file exists */
    int (*mkdirs)(void *ctx, const char *dir);                                /* the folder and its parents */
    int (*move_replace)(void *ctx, const char *src, const char *dst);         /* rename over an existing file */
    int (*reg_set)(void *ctx, const px_reg *r);                               /* make the key / set the value */
    int (*reg_get_dword)(void *ctx, int view, const char *key, const char *name, unsigned *value);   /* 0 when it is there */
    int (*path_add)(void *ctx, const char *dir);                              /* system PATH: append if missing; 0 done, 1 was there */
    void (*say)(void *ctx, const char *line);
    void *ctx;
} px_host;

typedef struct {
    int copied;           /* files put in place */
    int missing;          /* files the manifest lists that the unpacked package does not have */
    int failed;           /* operations that went wrong, the missing files included */
    int newer;            /* 1: a newer PhysX is installed, nothing was changed */
    int registry;         /* values written */
} px_result;

static void px_parent(const char *path, char *out, size_t cap)
{
    const char *slash = strrchr(path, '\\');
    size_t n = slash ? (size_t)(slash - path) : 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, path, n);
    out[n] = 0;
}

/* Installs from `files_dir` (the unpacked package's PhysX\files folder). `is64` is a 64-bit Windows: the 64-bit files and registry view
 * too. A PhysX of the same or a newer version already installed (the registry value NVIDIA's installer checks) is left alone unless
 * `force` is set, which the "install again" button sets for the same version; a newer one is never replaced. */
static px_result px_install(const px_host *h, const char *files_dir, int is64, int force)
{
    px_result r;
    size_t i;
    char src[800], dst[800], dir[800], line[900];
    unsigned have = 0;

    memset(&r, 0, sizeof r);
    if (h->reg_get_dword(h->ctx, 32, "SOFTWARE\\AGEIA Technologies", "PhysX Version", &have) == 0 && have > PX_VERSION_DWORD) {
        snprintf(line, sizeof line, "a newer PhysX is installed already (version value %u, this package is %u): nothing was changed", have, PX_VERSION_DWORD);
        h->say(h->ctx, line);
        r.newer = 1;
        return r;
    }
    if (have == PX_VERSION_DWORD && !force) {
        h->say(h->ctx, "this PhysX version is installed already: nothing was changed");
        r.newer = 1;
        return r;
    }
    if (h->mkdirs(h->ctx, PX_LOC)) {
        snprintf(line, sizeof line, "could not make %s", PX_LOC);
        h->say(h->ctx, line);
        r.failed++;
        return r;
    }
    for (i = 0; i < PX_COPY_COUNT; i++) {
        const px_copy *c = &px_copies[i];
        if (c->amd64 && !is64) continue;
        if (snprintf(src, sizeof src, "%s\\%s", files_dir, c->src) >= (int)sizeof src ||
            snprintf(dst, sizeof dst, "%s\\%s", PX_LOC, c->dst) >= (int)sizeof dst) { r.failed++; continue; }
        if (!rt_path_below(dst, PX_LOC) || strstr(c->src, "..") || strstr(c->dst, "..")) { r.failed++; continue; }
        if (!h->exists(h->ctx, src)) {
            snprintf(line, sizeof line, "the package has no %s", c->src);
            h->say(h->ctx, line);
            r.missing++;
            r.failed++;
            continue;
        }
        px_parent(dst, dir, sizeof dir);
        if (h->mkdirs(h->ctx, dir) || h->move_replace(h->ctx, src, dst)) {
            snprintf(line, sizeof line, "could not put %s in place", c->dst);
            h->say(h->ctx, line);
            r.failed++;
            continue;
        }
        r.copied++;
    }
    for (i = 0; i < PX_REG_COUNT; i++) {
        const px_reg *g = &px_regs[i];
        if (g->view == 64 && !is64) continue;
        if (h->reg_set(h->ctx, g)) {
            snprintf(line, sizeof line, "could not write the registry value %s\\%s (%d-bit view)", g->key, g->name ? g->name : "", g->view);
            h->say(h->ctx, line);
            r.failed++;
        } else if (g->name) {
            r.registry++;
        }
    }
    if (h->path_add(h->ctx, PX_PATH_ENTRY) < 0) {
        h->say(h->ctx, "could not add the PhysX Common folder to PATH");
        r.failed++;
    }
    snprintf(dst, sizeof dst, "%s\\Common\\PhysXLoader.dll", PX_LOC);
    if (!h->exists(h->ctx, dst)) {
        h->say(h->ctx, "Common\\PhysXLoader.dll is not there after the copy (NVIDIA's installer checks for it)");
        r.failed++;
    }
    return r;
}

#endif /* BCD_RUNTIMES_PHYSX_H */
