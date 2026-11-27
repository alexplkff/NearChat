#ifndef NEARCHAT_BOUNDED_SQLITE_H
#define NEARCHAT_BOUNDED_SQLITE_H
#include <sqlite3.h>
#include <stdint.h>

typedef struct NCQuotaVFS NCQuotaVFS;
/* Called after the underlying file is opened, before SQLite can write it. */
typedef int (*NCProtectFile)(const char *);
NCQuotaVFS *nc_quota_create(const char *directory, const char *name, int64_t limit, NCProtectFile protect);
const char *nc_quota_name(NCQuotaVFS *);
int64_t nc_quota_usage(NCQuotaVFS *);
void nc_quota_reset_failure(NCQuotaVFS *);
int nc_quota_failure(NCQuotaVFS *); /* 0 pager limit/no IO error, 1 quota, 2 underlying IO */
int nc_quota_set_limit(NCQuotaVFS *, int64_t);
/* Connections must be closed. installed remains true even if directory fsync fails. */
int nc_quota_install(NCQuotaVFS *, const char *from, const char *to, int64_t limit, int *installed);
void nc_quota_destroy(NCQuotaVFS *);
#endif
