#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

SEXP civetweb_start_server(SEXP portS, SEXP hostS, SEXP threadsS, SEXP max_bodyS,
                           SEXP timeoutS, SEXP ws_pathS, SEXP static_prefixesS,
                           SEXP static_dirsS, SEXP keep_aliveS);
SEXP civetweb_stop_server(SEXP server_xptr);
SEXP civetweb_server_port(SEXP server_xptr);
SEXP civetweb_server_running(SEXP server_xptr);

/* driver-loop API */
SEXP civetweb_next_request_timeout(SEXP server_xptr, SEXP timeout_ms);
SEXP civetweb_send_response(SEXP server_xptr, SEXP id, SEXP res);
SEXP civetweb_ws_send(SEXP server_xptr, SEXP idS, SEXP dataS);
SEXP civetweb_ws_close(SEXP server_xptr, SEXP idS, SEXP codeS);

static const R_CallMethodDef CallEntries[] = {
    {"civetweb_start_server",        (DL_FUNC) &civetweb_start_server,        9},
    {"civetweb_stop_server",         (DL_FUNC) &civetweb_stop_server,         1},
    {"civetweb_server_port",         (DL_FUNC) &civetweb_server_port,         1},
    {"civetweb_server_running",      (DL_FUNC) &civetweb_server_running,      1},
    {"civetweb_next_request_timeout",(DL_FUNC) &civetweb_next_request_timeout,2},
    {"civetweb_send_response",       (DL_FUNC) &civetweb_send_response,       3},
    {"civetweb_ws_send",             (DL_FUNC) &civetweb_ws_send,             3},
    {"civetweb_ws_close",            (DL_FUNC) &civetweb_ws_close,            3},
    {NULL, NULL, 0}
};

void R_init_civetwebR(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
