/* Minimal libpq declarations for Zig 0.17 translate-c.
 *
 * Zig 0.17 removed @cImport, so C bindings are generated from a header in the
 * repository instead of relying on a system libpq-fe.h being on the include
 * path. Only the symbols used by the postgres and pgvector backends are
 * declared here; the real implementation comes from the system `pq` library.
 */
#ifndef NULLCLAW_LIBPQ_FE_H
#define NULLCLAW_LIBPQ_FE_H

typedef struct pg_conn PGconn;
typedef struct pg_result PGresult;

typedef enum {
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1
} ConnStatusType;

typedef enum {
    PGRES_EMPTY_QUERY = 0,
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    PGRES_COPY_OUT = 3,
    PGRES_COPY_IN = 4,
    PGRES_BAD_RESPONSE = 5,
    PGRES_NONFATAL_ERROR = 6,
    PGRES_FATAL_ERROR = 7,
    PGRES_COPY_BOTH = 8,
    PGRES_SINGLE_TUPLE = 9,
    PGRES_PIPELINE_SYNC = 10,
    PGRES_PIPELINE_ABORTED = 11
} ExecStatusType;

extern PGconn *PQconnectdb(const char *conninfo);
extern void PQfinish(PGconn *conn);
extern ConnStatusType PQstatus(const PGconn *conn);
extern PGresult *PQexec(PGconn *conn, const char *query);
extern PGresult *PQexecParams(PGconn *conn,
                              const char *command,
                              int nParams,
                              const int *paramTypes,
                              const char *const *paramValues,
                              const int *paramLengths,
                              const int *paramFormats,
                              int resultFormat);
extern void PQclear(PGresult *res);
extern ExecStatusType PQresultStatus(const PGresult *res);
extern int PQntuples(const PGresult *res);
extern int PQgetisnull(const PGresult *res, int row, int column);
extern int PQgetlength(const PGresult *res, int row, int column);
extern char *PQgetvalue(const PGresult *res, int row, int column);
extern char *PQcmdTuples(PGresult *res);

#endif
