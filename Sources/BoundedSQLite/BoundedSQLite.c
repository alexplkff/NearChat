#include "BoundedSQLite.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* A wrapper, not a replacement filesystem: locking and fsync stay with Apple's VFS.
   Charge regular files, including the live rollback journal, in 4 KiB units.
   Directory entries, OS filesystem journals and APFS snapshots are outside this metric.
   Each archive owns a dedicated directory; child directories are separate archives. */
struct NCQuotaVFS {
    sqlite3_vfs vfs;
    sqlite3_vfs *underlying;
    char *directory;
    char *name;
    int64_t limit;
    int failure;
    NCProtectFile protect;
    pthread_mutex_t mutex;
};
typedef struct {
    sqlite3_file file;
    sqlite3_file *underlying;
    NCQuotaVFS *quota;
    char path[PATH_MAX];
    long double alignment;
} NCFile;

static int64_t rounded(int64_t n) {
    if (n < 0 || n > INT64_MAX - 4095) return -1;
    return ((n + 4095) / 4096) * 4096;
}
static int allowed(NCQuotaVFS *q, const char *path) {
    if (!path) return 0; /* temp_store=MEMORY; anonymous disk files are forbidden */
    size_t n = strlen(q->directory);
    return strncmp(path, q->directory, n) == 0 && path[n] == '/' &&
        path[n+1] && strchr(path+n+1, '/') == NULL;
}
static int64_t usage(NCQuotaVFS *q) {
    DIR *dir = opendir(q->directory);
    if (!dir) return -1;
    int64_t total = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char path[PATH_MAX];
        if (snprintf(path, sizeof(path), "%s/%s", q->directory, entry->d_name) >= (int)sizeof(path)) {
            total = -1; break;
        }
        struct stat st;
        if (lstat(path, &st)) { total = -1; break; }
        if (S_ISDIR(st.st_mode)) continue;
        if (!S_ISREG(st.st_mode)) { total = -1; break; }
        int64_t charged = rounded(st.st_size);
        if (charged < 0 || total > INT64_MAX - charged) { total = -1; break; }
        total += charged;
    }
    closedir(dir);
    return total;
}
/* Caller holds the quota mutex through both preflight and the actual write. */
static int permits(NCFile *f, int64_t newSize) {
    struct stat st;
    if (lstat(f->path, &st) || !S_ISREG(st.st_mode)) return SQLITE_IOERR_WRITE;
    int64_t old = rounded(st.st_size), next = rounded(newSize);
    if (old < 0 || next < 0) return SQLITE_FULL;
    if (next <= old) return SQLITE_OK;
    int64_t current = usage(f->quota);
    if (current < 0) return SQLITE_IOERR_WRITE;
    return next - old > f->quota->limit - current ? SQLITE_FULL : SQLITE_OK;
}
#define F(p) ((NCFile *)(p))
#define U(p) (F(p)->underlying)
#define M(p) (U(p)->pMethods)

static int ioClose(sqlite3_file *p) { return M(p)->xClose(U(p)); }
static int ioRead(sqlite3_file *p, void *b, int n, sqlite3_int64 o) { return M(p)->xRead(U(p),b,n,o); }
static int track(NCQuotaVFS *q,int rc) { if(rc!=SQLITE_OK) q->failure=2; return rc; }
static int ioWrite(sqlite3_file *p, const void *b, int n, sqlite3_int64 o) {
    if (n < 0 || o < 0 || o > INT64_MAX - n) return SQLITE_FULL;
    pthread_mutex_lock(&F(p)->quota->mutex);
    int rc = permits(F(p), o+n);
    if (rc == SQLITE_OK) rc = track(F(p)->quota,M(p)->xWrite(U(p),b,n,o));
    else if (F(p)->quota->failure != 2) F(p)->quota->failure = rc==SQLITE_FULL ? 1 : 2;
    pthread_mutex_unlock(&F(p)->quota->mutex);
    return rc;
}
static int ioTruncate(sqlite3_file *p, sqlite3_int64 n) {
    pthread_mutex_lock(&F(p)->quota->mutex);
    int rc = permits(F(p), n);
    if (rc == SQLITE_OK) rc = track(F(p)->quota,M(p)->xTruncate(U(p),n));
    else if (F(p)->quota->failure != 2) F(p)->quota->failure = rc==SQLITE_FULL ? 1 : 2;
    pthread_mutex_unlock(&F(p)->quota->mutex);
    return rc;
}
static int ioSync(sqlite3_file *p,int flags) { return track(F(p)->quota,M(p)->xSync(U(p),flags)); }
static int ioSize(sqlite3_file *p,sqlite3_int64 *n) { return M(p)->xFileSize(U(p),n); }
static int ioLock(sqlite3_file *p,int flags) { return M(p)->xLock(U(p),flags); }
static int ioUnlock(sqlite3_file *p,int flags) { return M(p)->xUnlock(U(p),flags); }
static int ioReserved(sqlite3_file *p,int *result) { return M(p)->xCheckReservedLock(U(p),result); }
static int ioControl(sqlite3_file *p,int op,void *arg) {
    /* Optional preallocation must not grow files behind the accounting wrapper. */
    if (op == SQLITE_FCNTL_SIZE_HINT || op == SQLITE_FCNTL_CHUNK_SIZE) return SQLITE_OK;
    return M(p)->xFileControl(U(p),op,arg);
}
static int ioSector(sqlite3_file *p) { return M(p)->xSectorSize(U(p)); }
static int ioCharacteristics(sqlite3_file *p) { return M(p)->xDeviceCharacteristics(U(p)); }
/* This archive deliberately uses DELETE, not WAL or mmap. */
static int ioShmMap(sqlite3_file *p,int a,int b,int c,void volatile **out) {
    (void)p;(void)a;(void)b;(void)c;*out=NULL;return SQLITE_IOERR_SHMMAP;
}
static int ioShmLock(sqlite3_file *p,int a,int b,int c) {
    (void)p;(void)a;(void)b;(void)c;return SQLITE_IOERR_SHMLOCK;
}
static void ioShmBarrier(sqlite3_file *p) { (void)p; }
static int ioShmUnmap(sqlite3_file *p,int flag) { (void)p;(void)flag;return SQLITE_OK; }
static int ioFetch(sqlite3_file *p,sqlite3_int64 o,int n,void **out) {
    (void)p;(void)o;(void)n;*out=NULL;return SQLITE_OK;
}
static int ioUnfetch(sqlite3_file *p,sqlite3_int64 o,void *ptr) {
    (void)p;(void)o;(void)ptr;return SQLITE_OK;
}
static const sqlite3_io_methods methods = {
    3,ioClose,ioRead,ioWrite,ioTruncate,ioSync,ioSize,ioLock,ioUnlock,ioReserved,
    ioControl,ioSector,ioCharacteristics,ioShmMap,ioShmLock,ioShmBarrier,ioShmUnmap,ioFetch,ioUnfetch
};
static NCQuotaVFS *Q(sqlite3_vfs *v) { return (NCQuotaVFS *)v->pAppData; }
static int vOpen(sqlite3_vfs *v,const char *path,sqlite3_file *file,int flags,int *out) {
    NCQuotaVFS *q = Q(v);
    file->pMethods = NULL;
    if (!allowed(q,path) || strlen(path) >= PATH_MAX) return SQLITE_CANTOPEN;
    NCFile *f = F(file);
    f->quota=q;
    f->underlying=(sqlite3_file *)((char *)f+sizeof(NCFile));
    strcpy(f->path,path);
    memset(f->underlying,0,q->underlying->szOsFile);
    int rc=q->underlying->xOpen(q->underlying,path,f->underlying,flags,out);
    if (rc != SQLITE_OK) {
        q->failure=2;
        if (f->underlying->pMethods) f->underlying->pMethods->xClose(f->underlying);
        return rc;
    }
    if (q->protect && !q->protect(path)) {
        q->failure=2;
        f->underlying->pMethods->xClose(f->underlying);
        return SQLITE_CANTOPEN;
    }
    file->pMethods=&methods;
    return SQLITE_OK;
}
static int vDelete(sqlite3_vfs *v,const char *p,int sync) {
    NCQuotaVFS *q=Q(v);
    if (!allowed(q,p)) return SQLITE_IOERR_DELETE;
    pthread_mutex_lock(&q->mutex);
    int rc=track(q,q->underlying->xDelete(q->underlying,p,sync));
    pthread_mutex_unlock(&q->mutex);
    return rc;
}
static int vAccess(sqlite3_vfs *v,const char *p,int flag,int *out) {
    NCQuotaVFS *q=Q(v);
    if (!allowed(q,p)) { *out=0; return SQLITE_OK; }
    return q->underlying->xAccess(q->underlying,p,flag,out);
}
static int vPath(sqlite3_vfs *v,const char *p,int n,char *out) { NCQuotaVFS *q=Q(v);return q->underlying->xFullPathname(q->underlying,p,n,out); }
static void *vDlOpen(sqlite3_vfs *v,const char *p) { NCQuotaVFS *q=Q(v);return q->underlying->xDlOpen(q->underlying,p); }
static void vDlError(sqlite3_vfs *v,int n,char *p) { NCQuotaVFS *q=Q(v);q->underlying->xDlError(q->underlying,n,p); }
static void (*vDlSym(sqlite3_vfs *v,void *h,const char *p))(void) { NCQuotaVFS *q=Q(v);return q->underlying->xDlSym(q->underlying,h,p); }
static void vDlClose(sqlite3_vfs *v,void *h) { NCQuotaVFS *q=Q(v);q->underlying->xDlClose(q->underlying,h); }
static int vRandom(sqlite3_vfs *v,int n,char *out) { NCQuotaVFS *q=Q(v);return q->underlying->xRandomness(q->underlying,n,out); }
static int vSleep(sqlite3_vfs *v,int n) { NCQuotaVFS *q=Q(v);return q->underlying->xSleep(q->underlying,n); }
static int vTime(sqlite3_vfs *v,double *out) { NCQuotaVFS *q=Q(v);return q->underlying->xCurrentTime(q->underlying,out); }
static int vError(sqlite3_vfs *v,int n,char *out) { NCQuotaVFS *q=Q(v);return q->underlying->xGetLastError(q->underlying,n,out); }
static int vTime64(sqlite3_vfs *v,sqlite3_int64 *out) {
    NCQuotaVFS *q=Q(v);
    if(q->underlying->iVersion>=2 && q->underlying->xCurrentTimeInt64) return q->underlying->xCurrentTimeInt64(q->underlying,out);
    double t; int rc=vTime(v,&t); *out=(sqlite3_int64)(t*86400000.0);return rc;
}
NCQuotaVFS *nc_quota_create(const char *directory,const char *name,int64_t limit,NCProtectFile protect) {
    if (!directory || !name || limit<65536) return NULL;
    sqlite3_vfs *base=sqlite3_vfs_find(NULL);
    if (!base) return NULL;
    NCQuotaVFS *q=calloc(1,sizeof(*q));
    if (!q) return NULL;
    q->directory=realpath(directory,NULL);q->name=strdup(name);q->underlying=base;q->limit=limit;q->protect=protect;
    if (!q->directory || !q->name) { free(q->directory);free(q->name);free(q);return NULL; }
    pthread_mutex_init(&q->mutex,NULL);
    sqlite3_vfs v={0};
    v.iVersion=2;v.szOsFile=(int)sizeof(NCFile)+base->szOsFile;v.mxPathname=base->mxPathname;
    v.zName=q->name;v.pAppData=q;v.xOpen=vOpen;v.xDelete=vDelete;v.xAccess=vAccess;v.xFullPathname=vPath;
    v.xDlOpen=vDlOpen;v.xDlError=vDlError;v.xDlSym=vDlSym;v.xDlClose=vDlClose;
    v.xRandomness=vRandom;v.xSleep=vSleep;v.xCurrentTime=vTime;v.xGetLastError=vError;v.xCurrentTimeInt64=vTime64;
    q->vfs=v;
    if (sqlite3_vfs_register(&q->vfs,0)!=SQLITE_OK) { nc_quota_destroy(q);return NULL; }
    return q;
}
const char *nc_quota_name(NCQuotaVFS *q) { return q ? q->name : NULL; }
int64_t nc_quota_usage(NCQuotaVFS *q) {
    if(!q) return -1;
    pthread_mutex_lock(&q->mutex);int64_t n=usage(q);pthread_mutex_unlock(&q->mutex);return n;
}
int nc_quota_set_limit(NCQuotaVFS *q,int64_t limit) {
    if(!q || limit<65536)return SQLITE_MISUSE;
    pthread_mutex_lock(&q->mutex);
    int64_t n=usage(q);int rc=n<0?SQLITE_IOERR:(n>limit?SQLITE_FULL:SQLITE_OK);
    if(rc==SQLITE_OK)q->limit=limit;
    pthread_mutex_unlock(&q->mutex);return rc;
}
void nc_quota_destroy(NCQuotaVFS *q) {
    if(!q)return;
    sqlite3_vfs_unregister(&q->vfs);pthread_mutex_destroy(&q->mutex);
    free(q->directory);free(q->name);free(q);
}

int nc_quota_install(NCQuotaVFS *q,const char *from,const char *to,int64_t limit,int *installed) {
    if(!installed) return SQLITE_MISUSE;
    *installed=0;
    if(!q || !from || !to || limit<65536) return SQLITE_MISUSE;
    char *canonicalFrom=realpath(from,NULL), *canonicalTo=realpath(to,NULL);
    if(!canonicalFrom || !canonicalTo) { free(canonicalFrom);free(canonicalTo);return SQLITE_IOERR; }
    from=canonicalFrom;to=canonicalTo;
    if(!allowed(q,from) || !allowed(q,to) || !strcmp(from,to)) {
        free(canonicalFrom);free(canonicalTo);return SQLITE_MISUSE;
    }
    pthread_mutex_lock(&q->mutex);
    struct stat source,target;
    int rc=SQLITE_OK;
    int64_t total=usage(q);
    if(total<0 || lstat(from,&source) || lstat(to,&target) ||
       !S_ISREG(source.st_mode) || !S_ISREG(target.st_mode)) rc=SQLITE_IOERR;
    else if(total-rounded(target.st_size)>limit) rc=SQLITE_FULL;
    else if(rename(from,to)) rc=SQLITE_IOERR;
    else {
        *installed=1;
        q->limit=limit;
        int fd=open(q->directory,O_RDONLY|O_DIRECTORY);
        if(fd<0) rc=SQLITE_IOERR_DIR_FSYNC;
        else { if(fsync(fd)) rc=SQLITE_IOERR_DIR_FSYNC; close(fd); }
    }
    pthread_mutex_unlock(&q->mutex);
    free(canonicalFrom);free(canonicalTo);
    return rc;
}

void nc_quota_reset_failure(NCQuotaVFS *q) { if(q) q->failure=0; }
int nc_quota_failure(NCQuotaVFS *q) { return q?q->failure:2; }
