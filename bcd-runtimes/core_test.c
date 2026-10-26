// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// core_test.c: a command-line driver for core.h, physx.h and cabs.h, built for the host by tests/host/check-bcd-runtimes.py (clang with
// ASan and UBSan). The check feeds it files it made with Python (hashlib, zlib, zipfile as the oracles) and compares what it prints.
// Each command prints one result and exits 0, or prints "BAD ..." and exits 1 when the function refused the input.
// The file system the PhysX and DirectX parts see is a folder on the host: a Windows path "C:\windows\system32\x.dll" is
// <root>/windows/system32/x.dll.

#define BCD_HOST_TEST 1
#include "core.h"
#include "physx.h"
#include "cabs.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned char *slurp(const char *path, size_t *n)
{
    FILE *f = fopen(path, "rb");
    unsigned char *b;
    long sz;
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    if (sz < 0) { fprintf(stderr, "cannot size %s\n", path); exit(2); }
    fseek(f, 0, SEEK_SET);
    b = (unsigned char *)malloc((size_t)sz + 1);
    if (fread(b, 1, (size_t)sz, f) != (size_t)sz) { fprintf(stderr, "short read\n"); exit(2); }
    fclose(f);
    *n = (size_t)sz;
    return b;
}

/* ---------------------------------------------------------------- a Windows path on the host */

static const char *g_root = ".";

static void hostpath(const char *win, char *out, size_t cap)
{
    size_t i, k = 0;
    if (win[0] && win[1] == ':' && win[2] == '\\') win += 3;
    k += (size_t)snprintf(out, cap, "%s/", g_root);
    for (i = 0; win[i] && k + 1 < cap; i++) out[k++] = win[i] == '\\' ? '/' : win[i];
    out[k] = 0;
}

static int mkdirs_host(const char *path)
{
    char buf[1024];
    size_t i;
    snprintf(buf, sizeof buf, "%s", path);
    for (i = 1; buf[i]; i++) {
        if (buf[i] == '/') {
            buf[i] = 0;
            if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
            buf[i] = '/';
        }
    }
    return mkdir(buf, 0755) != 0 && errno != EEXIST ? -1 : 0;
}

static int h_exists(void *ctx, const char *win)
{
    char p[1024];
    struct stat st;
    (void)ctx;
    hostpath(win, p, sizeof p);
    return lstat(p, &st) == 0;
}

static int h_list(void *ctx, const char *win_dir, int index, char *name, size_t cap)
{
    char p[1024];
    DIR *d;
    struct dirent *e;
    int i = 0, found = 0;
    (void)ctx;
    hostpath(win_dir, p, sizeof p);
    d = opendir(p);
    if (!d) return 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (i++ == index) { snprintf(name, cap, "%s", e->d_name); found = 1; break; }
    }
    closedir(d);
    return found;
}

/* ---------------------------------------------------------------- the cabinet source and the destination */

typedef struct { FILE *f; } src_ctx;

static int s_read(void *ctx, u64 off, void *buf, size_t n)
{
    src_ctx *c = (src_ctx *)ctx;
    if (fseek(c->f, (long)off, SEEK_SET) != 0) return -1;
    return (int)fread(buf, 1, n, c->f);
}

typedef struct { int fd; char part[1100]; } part_file;

static void *d_begin(void *ctx, const char *final_win)
{
    char fin[1024];
    part_file *p = (part_file *)calloc(1, sizeof *p);
    (void)ctx;
    hostpath(final_win, fin, sizeof fin);
    snprintf(p->part, sizeof p->part, "%s.bcd-part", fin);
    unlink(p->part);
    p->fd = open(p->part, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (p->fd < 0) { free(p); return NULL; }
    return p;
}

static int d_write(void *ctx, void *file, const void *data, size_t n)
{
    part_file *p = (part_file *)file;
    (void)ctx;
    return write(p->fd, data, n) == (ssize_t)n ? 0 : -1;
}

static int d_commit(void *ctx, void *file, const char *final_win)
{
    part_file *p = (part_file *)file;
    char fin[1024];
    int r;
    (void)ctx;
    hostpath(final_win, fin, sizeof fin);
    close(p->fd);
    r = link(p->part, fin);
    if (r != 0 && errno != EEXIST) { unlink(p->part); free(p); return -1; }
    unlink(p->part);
    free(p);
    return r == 0 ? 0 : 1;
}

static void d_abort(void *ctx, void *file, const char *final_win)
{
    part_file *p = (part_file *)file;
    (void)ctx; (void)final_win;
    close(p->fd);
    unlink(p->part);
    free(p);
}

static void say_stdout(void *ctx, const char *line)
{
    (void)ctx;
    printf("say: %s\n", line);
}

/* ---------------------------------------------------------------- PhysX: a fake registry and the host's folders */

typedef struct { int view; char key[300]; char name[100]; int type; char sz[300]; unsigned dword; } fake_reg;
static fake_reg g_regs[200];
static int g_nregs;
static int g_path_added;
static unsigned g_have_version;
static int g_have_set;

static int px_exists(void *ctx, const char *p) { return h_exists(ctx, p); }
static int px_mkdirs(void *ctx, const char *dir)
{
    char p[1024];
    (void)ctx;
    hostpath(dir, p, sizeof p);
    return mkdirs_host(p);
}
static int px_move(void *ctx, const char *src, const char *dst)
{
    char a[1024], b[1024];
    (void)ctx;
    hostpath(src, a, sizeof a);
    hostpath(dst, b, sizeof b);
    return rename(a, b);
}
static int px_reg_set(void *ctx, const px_reg *r)
{
    fake_reg *g;
    (void)ctx;
    if (g_nregs >= (int)(sizeof g_regs / sizeof g_regs[0])) return -1;
    g = &g_regs[g_nregs++];
    g->view = r->view;
    snprintf(g->key, sizeof g->key, "%s", r->key);
    snprintf(g->name, sizeof g->name, "%s", r->name ? r->name : "(key only)");
    g->type = r->type;
    snprintf(g->sz, sizeof g->sz, "%s", r->sz ? r->sz : "");
    g->dword = r->dword;
    return 0;
}
static int px_reg_get(void *ctx, int view, const char *key, const char *name, unsigned *value)
{
    (void)ctx;
    if (g_have_set && view == 32 && !strcmp(key, "SOFTWARE\\AGEIA Technologies") && !strcmp(name, "PhysX Version")) {
        *value = g_have_version;
        return 0;
    }
    return 1;
}
static int px_path_add(void *ctx, const char *dir) { (void)ctx; g_path_added++; return strcmp(dir, PX_PATH_ENTRY) == 0 ? 0 : -1; }

/* ---------------------------------------------------------------- commands */

static int dispatch(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "";

    if (!strcmp(cmd, "sha256") && argc >= 3) {          /* sha256 <file> [chunk]: the digest, fed in pieces of `chunk` bytes */
        size_t n, chunk = argc > 3 ? (size_t)atoi(argv[3]) : 4096, i;
        unsigned char *b = slurp(argv[2], &n), d[32];
        char hex[65];
        rt_sha256 s;
        rt_sha256_init(&s);
        for (i = 0; i < n; i += chunk) rt_sha256_update(&s, b + i, n - i < chunk ? n - i : chunk);
        rt_sha256_final(&s, d);
        rt_hex(d, 32, hex);
        printf("%s\n", hex);
        return 0;
    }
    if (!strcmp(cmd, "sha256is") && argc >= 4) {        /* sha256is <file> <hex> */
        size_t n;
        unsigned char *b = slurp(argv[2], &n), d[32];
        rt_sha256 s;
        rt_sha256_init(&s);
        rt_sha256_update(&s, b, n);
        rt_sha256_final(&s, d);
        printf("%d\n", rt_sha256_is(d, argv[3]));
        return 0;
    }
    if (!strcmp(cmd, "crc32") && argc >= 3) {
        size_t n;
        unsigned char *b = slurp(argv[2], &n);
        printf("%08x\n", rt_crc32(0, b, n));
        return 0;
    }
    if (!strcmp(cmd, "inflate") && argc >= 5) {         /* inflate <raw deflate file> <out length> <out file> */
        size_t n, outlen = (size_t)strtoull(argv[3], NULL, 10), used = 0;
        unsigned char *b = slurp(argv[2], &n), *out = (unsigned char *)malloc(outlen + 1);
        int r = rt_inflate(b, n, out, outlen, &used);
        if (r) { printf("BAD %d\n", r); return 1; }
        {
            FILE *f = fopen(argv[4], "wb");
            fwrite(out, 1, outlen, f);
            fclose(f);
        }
        printf("OK %zu\n", used);
        return 0;
    }
    if (!strcmp(cmd, "zipfind") && argc >= 4) {
        size_t n;
        unsigned char *b = slurp(argv[2], &n);
        rt_zip_entry e;
        int r = rt_zip_find(b, n, argv[3], &e);
        if (r) { printf("BAD %d\n", r); return 1; }
        printf("%u %08x %llu %llu\n", e.method, e.crc, (unsigned long long)e.csize, (unsigned long long)e.usize);
        return 0;
    }
    if (!strcmp(cmd, "zipextract") && argc >= 5) {      /* zipextract <zip> <name> <out file> */
        size_t n;
        unsigned char *b = slurp(argv[2], &n), *out;
        rt_zip_entry e;
        int r = rt_zip_find(b, n, argv[3], &e);
        if (r) { printf("BAD find %d\n", r); return 1; }
        if (e.usize > ((u64)256 << 20)) { printf("BAD too large\n"); return 1; }
        out = (unsigned char *)malloc((size_t)e.usize + 1);
        r = rt_zip_extract(b, n, &e, out);
        if (r) { printf("BAD extract %d\n", r); return 1; }
        {
            FILE *f = fopen(argv[4], "wb");
            fwrite(out, 1, (size_t)e.usize, f);
            fclose(f);
        }
        printf("OK %llu\n", (unsigned long long)e.usize);
        return 0;
    }
    if (!strcmp(cmd, "url") && argc >= 3) {
        rt_url u;
        if (!rt_url_parse(argv[2], &u)) { printf("BAD\n"); return 1; }
        printf("%s %s\n", u.host, u.path);
        return 0;
    }
    if (!strcmp(cmd, "redirect") && argc >= 5) {        /* redirect <base url> <location> <host,host> */
        rt_url base, out;
        const char *hosts[8] = { 0 };
        const char *why = "";
        char list[300];
        char *tok;
        int k = 0;
        if (!rt_url_parse(argv[2], &base)) { printf("BAD base\n"); return 2; }
        snprintf(list, sizeof list, "%s", argv[4]);
        for (tok = strtok(list, ","); tok && k < 7; tok = strtok(NULL, ",")) hosts[k++] = tok;
        if (!rt_redirect(&base, argv[3], hosts, &out, &why)) { printf("BAD %s\n", why); return 1; }
        printf("%s %s\n", out.host, out.path);
        return 0;
    }
    if (!strcmp(cmd, "dllname") && argc >= 3) { printf("%d\n", rt_dll_name_ok(argv[2])); return 0; }
    if (!strcmp(cmd, "cabkind") && argc >= 3) { printf("%d\n", rt_dx_cab_kind(argv[2])); return 0; }
    if (!strcmp(cmd, "below") && argc >= 4) { printf("%d\n", rt_path_below(argv[2], argv[3])); return 0; }
    if (!strcmp(cmd, "tenth") && argc >= 4) { printf("%d\n", rt_tenth(strtoull(argv[2], NULL, 10), strtoull(argv[3], NULL, 10))); return 0; }
    if (!strcmp(cmd, "msiok") && argc >= 3) { printf("%d\n", rt_msi_exit_ok(strtoul(argv[2], NULL, 10))); return 0; }
    if (!strcmp(cmd, "size") && argc >= 3) { char b[40]; rt_size_text(strtoull(argv[2], NULL, 10), b, sizeof b); printf("%s\n", b); return 0; }
    if (!strcmp(cmd, "result") && argc >= 6) {
        char b[400];
        rt_result_line(b, sizeof b, argv[2], atoi(argv[3]), atoi(argv[4]), argv[5]);
        printf("%s\n", b);
        return 0;
    }
    if (!strcmp(cmd, "table")) {                        /* the runtimes, one per line, for the check to compare with the files it reads */
        size_t i;
        const char *const *c;
        for (i = 0; i < RT_COUNT; i++) {
            const rt_runtime *r = &rt_table[i];
            rt_url u;
            int ok = rt_url_parse(r->url, &u);
            printf("%s|%s|%s|%s|%llu|%u|%d|%s|%d|", r->id, r->file, r->url, r->sha256, (unsigned long long)r->size, r->need_mb, (int)r->kind,
                   ok ? u.host : "BADURL", ok && rt_host_allowed(u.host, r->hosts));
            for (c = r->check; c && *c; c++) printf("%s%s", c == r->check ? "" : ";;", *c);
            printf("\n");
        }
        return 0;
    }
    if (!strcmp(cmd, "match") && argc >= 4) {           /* match <root> <pattern>: the number of check patterns of a runtime / one pattern */
        const rt_fs fs = { h_exists, h_list, NULL };
        g_root = argv[2];
        if (!strncmp(argv[3], "id:", 3)) {
            const rt_runtime *r = rt_find(argv[3] + 3);
            int total = 0, have;
            if (!r) { printf("BAD\n"); return 1; }
            have = rt_check_count(&fs, r, &total);
            printf("%d/%d\n", have, total);
            return 0;
        }
        printf("%d\n", rt_path_match(&fs, argv[3]));
        return 0;
    }
    if (!strcmp(cmd, "physx-list")) {
        size_t i;
        for (i = 0; i < PX_COPY_COUNT; i++) printf("C|%s|%s|%d\n", px_copies[i].src, px_copies[i].dst, px_copies[i].amd64);
        for (i = 0; i < PX_REG_COUNT; i++)
            printf("R|%d|%s|%s|%d|%s|%u\n", px_regs[i].view, px_regs[i].key, px_regs[i].name ? px_regs[i].name : "(key only)", (int)px_regs[i].type,
                   px_regs[i].sz, px_regs[i].dword);
        return 0;
    }
    if (!strcmp(cmd, "physx") && argc >= 5) {           /* physx <root> <is64> <force> [have version]: files_dir is C:\payload\PhysX\files */
        px_host h;
        px_result r;
        int i;
        g_root = argv[2];
        if (argc > 5) { g_have_set = 1; g_have_version = (unsigned)strtoul(argv[5], NULL, 10); }
        h.exists = px_exists; h.mkdirs = px_mkdirs; h.move_replace = px_move; h.reg_set = px_reg_set; h.reg_get_dword = px_reg_get;
        h.path_add = px_path_add; h.say = say_stdout; h.ctx = NULL;
        r = px_install(&h, "C:\\payload\\PhysX\\files", atoi(argv[3]), atoi(argv[4]));
        printf("result copied=%d missing=%d failed=%d newer=%d registry=%d path=%d\n", r.copied, r.missing, r.failed, r.newer, r.registry, g_path_added);
        for (i = 0; i < g_nregs; i++)
            printf("reg|%d|%s|%s|%d|%s|%u\n", g_regs[i].view, g_regs[i].key, g_regs[i].name, g_regs[i].type, g_regs[i].sz, g_regs[i].dword);
        return 0;
    }
    if (!strcmp(cmd, "findcab") && argc >= 3) {
        size_t n;
        unsigned char *b = slurp(argv[2], &n);
        u64 size = 0;
        long long at = rt_find_cab(b, n < (1u << 20) ? n : (1u << 20), n, &size);
        printf("%lld %llu\n", at, (unsigned long long)size);
        return 0;
    }
    if (!strcmp(cmd, "dx") && argc >= 5) {              /* dx <root> <exe> <fail after bytes or -1>: reads the mock container inside <exe> */
        static rt_fdi_api api = { fdi_host_create, fdi_host_copy, fdi_host_destroy };
        src_ctx sc;
        rt_src src;
        rt_dx dx;
        u64 cab_size = 0;
        size_t n, head;
        unsigned char *b;
        long long at;
        int rc, i;

        g_root = argv[2];
        b = slurp(argv[3], &n);
        head = n < (1u << 20) ? n : (1u << 20);
        at = rt_find_cab(b, head, n, &cab_size);
        if (at < 0) { printf("BAD no cabinet\n"); return 1; }
        sc.f = fopen(argv[3], "rb");
        src.read = s_read; src.ctx = &sc; src.base = (u64)at; src.length = cab_size;
        memset(&dx, 0, sizeof dx);
        dx.api = &api;
        dx.src = &src;
        dx.dest.exists = h_exists; dx.dest.begin = d_begin; dx.dest.write = d_write; dx.dest.commit = d_commit; dx.dest.abort = d_abort;
        dx.dir_x86 = "C:\\windows\\syswow64";
        dx.dir_x64 = "C:\\windows\\system32";
        dx.say = say_stdout;
        fdi_host_fail_after_bytes = atol(argv[4]);
        rc = rt_dx_extract(&dx);
        printf("rc=%d outer_ok=%d added=%d kept=%d failed=%d skipped_files=%d cabs_read=%d cabs_skipped=%d opens=%d closes=%d\n", rc, dx.st.outer_ok,
               dx.st.added, dx.st.kept, dx.st.failed, dx.st.skipped_files, dx.st.cabs_read, dx.st.cabs_skipped, fdi_host_opens, fdi_host_closes);
        for (i = 0; i < dx.st.list_n; i++) printf("added|%s|%d\n", dx.st.list[i].name, dx.st.list[i].is64);
        fclose(sc.f);
        return 0;
    }
    fprintf(stderr, "core_test: unknown command %s\n", cmd);
    return 2;
}

/* batch <file>: one command per line, its arguments separated by tabs; every command's output is followed by a line "@@ <exit code>".
 * The check uses it to run hundreds of small cases in one process (the sanitizers see all of them). */
int main(int argc, char **argv)
{
    if (argc >= 3 && !strcmp(argv[1], "batch")) {
        FILE *f = fopen(argv[2], "r");
        char line[8192];
        if (!f) { fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }
        while (fgets(line, sizeof line, f)) {
            char *args[40], *p = line, *tab;
            int n = 1;
            size_t len = strlen(line);
            int rc;
            if (len && line[len - 1] == '\n') line[len - 1] = 0;
            args[0] = (char *)"core_test";
            for (;;) {
                tab = strchr(p, '\t');
                if (n < 39) args[n++] = p;
                if (!tab) break;
                *tab = 0;
                p = tab + 1;
            }
            args[n] = NULL;
            rc = dispatch(n, args);
            fflush(stdout);
            printf("@@ %d\n", rc);
        }
        fclose(f);
        return 0;
    }
    return dispatch(argc, argv);
}
