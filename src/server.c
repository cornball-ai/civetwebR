/* civetwebR: the bridge between civetweb's worker threads and R's main
 * thread.
 *
 * Model: civetweb threads never call into R. Each request or WebSocket
 * event is copied into a cw_request_t, queued on its server, and the R
 * main thread drains the queue with civetweb_next_request_timeout().
 * HTTP requests and WebSocket connects block their worker thread until R
 * answers through civetweb_send_response(); WebSocket ready/data/close
 * events are fire-and-forget.
 *
 * Every piece of state belongs to one cw_server_t, reachable from the
 * civetweb context's user data and from an R external pointer whose
 * finalizer stops the server. Nothing here is a process global, so one R
 * process can run several servers.
 *
 * Rules kept throughout:
 *  - no R API call on a worker thread (no Rf_error, no allocation);
 *    an allocation failure answers 500 or drops the event instead;
 *  - a WebSocket anchor (the connect request that became a connection)
 *    is written to and closed under its own lock, so a write never races
 *    the close callback;
 *  - the R thread is the only thread that frees anchors, and it does so
 *    only when it dequeues the matching close event.
 */

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Error.h>
#include <R_ext/Utils.h>   /* R_CheckUserInterrupt, R_ToplevelExec */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#ifndef _WIN32
  #include <sched.h>
  #include <unistd.h>
#endif

#include "civetweb.h"

#ifdef _WIN32
  #include <windows.h>
  typedef CRITICAL_SECTION   cw_mutex_t;
  typedef CONDITION_VARIABLE cw_cond_t;

  #define cw_mutex_init     InitializeCriticalSection
  #define cw_mutex_lock     EnterCriticalSection
  #define cw_mutex_unlock   LeaveCriticalSection
  #define cw_mutex_destroy  DeleteCriticalSection

  #define cw_cond_init      InitializeConditionVariable
  #define cw_cond_signal    WakeConditionVariable
  #define cw_cond_broadcast WakeAllConditionVariable
  #define cw_cond_wait(c,m) SleepConditionVariableCS((c),(m),INFINITE)
  #define cw_cond_destroy(c) ((void)0)
#else
  #include <pthread.h>

  typedef pthread_mutex_t cw_mutex_t;
  typedef pthread_cond_t  cw_cond_t;

  #define cw_mutex_init(m)    pthread_mutex_init((m), NULL)
  #define cw_mutex_lock       pthread_mutex_lock
  #define cw_mutex_unlock     pthread_mutex_unlock
  #define cw_mutex_destroy    pthread_mutex_destroy

  #define cw_cond_init(c)     pthread_cond_init((c), NULL)
  #define cw_cond_signal      pthread_cond_signal
  #define cw_cond_broadcast   pthread_cond_broadcast
  #define cw_cond_wait(c,m)   pthread_cond_wait((c),(m))
  #define cw_cond_destroy     pthread_cond_destroy
#endif

/* ------------------------------------------------------------------ */
/* Types                                                               */
/* ------------------------------------------------------------------ */

typedef enum {
  CW_EVENT_HTTP = 0,
  CW_EVENT_WS_CONNECT = 1,
  CW_EVENT_WS_READY = 2,
  CW_EVENT_WS_DATA = 3,
  CW_EVENT_WS_CLOSE = 4
} cw_event_t;

typedef struct cw_hdr {
  char *name;
  char *value;
} cw_hdr_t;

typedef struct cw_request {
  cw_event_t event_type;
  int id;

  /* request side */
  char *method;
  char *path;
  char *query;
  char remote_addr[48];
  int remote_port;
  cw_hdr_t *headers;
  int num_headers;
  unsigned char *req_body;
  size_t req_body_len;
  int req_body_too_large;
  int ws_fin;                /* WS_DATA: final frame of a message */
  int ws_binary;             /* WS_DATA: binary (1) or text (0) frame */
  int alloc_failed;          /* a copy failed on the worker thread */

  struct mg_connection *conn;

  /* response side (HTTP), decision side (WS_CONNECT) */
  int status;
  char *status_text;
  char *content_type;
  cw_hdr_t *res_headers;
  int num_res_headers;
  unsigned char *body;
  size_t body_len;
  int accept;                /* WS_CONNECT: R said yes */
  int close_requested;       /* anchor: server sent a close frame */

  /* handoff */
  int responded;
  cw_mutex_t lock;
  cw_cond_t  cv;
  struct cw_request *next;   /* queue link, then active link */
} cw_request_t;

typedef struct cw_server {
  struct mg_context *ctx;

  cw_request_t *q_head, *q_tail;   /* events R has not seen yet */
  cw_request_t *active_head;       /* HTTP/CONNECT awaiting R, WS anchors */

  cw_mutex_t lock;
  cw_cond_t  q_cv;

  int next_id;
  int running;                     /* accepting new work */
  int stopped;                     /* mg_stop() has run */
  int in_flight;                   /* workers blocked on R or writing */
  cw_cond_t  drain_cv;             /* signalled when in_flight drops */

  size_t max_body;
  char *ws_path;

  char **static_prefixes;          /* URIs civetweb serves itself */
  size_t *static_prefix_len;
  int n_static;
} cw_server_t;

/* ------------------------------------------------------------------ */
/* Small helpers (worker-thread safe: no R API)                        */
/* ------------------------------------------------------------------ */

static char *dup_str(const char *s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char *o = (char *)malloc(n + 1);
  if (!o) return NULL;
  memcpy(o, s, n + 1);
  return o;
}

static void free_headers(cw_hdr_t *h, int n) {
  if (!h) return;
  for (int i = 0; i < n; i++) {
    free(h[i].name);
    free(h[i].value);
  }
  free(h);
}

static void free_req(cw_request_t *r) {
  if (!r) return;
  free(r->method);
  free(r->path);
  free(r->query);
  free_headers(r->headers, r->num_headers);
  free_headers(r->res_headers, r->num_res_headers);
  free(r->req_body);
  free(r->status_text);
  free(r->content_type);
  free(r->body);
  cw_mutex_destroy(&r->lock);
  cw_cond_destroy(&r->cv);
  free(r);
}

/* A new request with an id; NULL on allocation failure. */
static cw_request_t *req_new(cw_server_t *s, cw_event_t type) {
  cw_request_t *r = (cw_request_t *)calloc(1, sizeof(*r));
  if (!r) return NULL;
  cw_mutex_init(&r->lock);
  cw_cond_init(&r->cv);
  r->event_type = type;
  r->status = 500;
  cw_mutex_lock(&s->lock);
  r->id = s->next_id++;
  cw_mutex_unlock(&s->lock);
  return r;
}

/* timed wait on a condition variable; 1 if signalled, 0 on timeout */
static int cond_wait_ms(cw_cond_t *cv, cw_mutex_t *mtx, int ms) {
#ifdef _WIN32
  return SleepConditionVariableCS(cv, mtx, (DWORD)ms);
#else
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  long ns = ts.tv_nsec + (long)ms * 1000000L;
  ts.tv_sec  += ns / 1000000000L;
  ts.tv_nsec  = ns % 1000000000L;
  return pthread_cond_timedwait(cv, mtx, &ts) == 0;
#endif
}

/* Interrupt check that does not longjmp out of C: 1 if pending. */
static void check_interrupt_cb(void *dummy) {
  (void)dummy;
  R_CheckUserInterrupt();
}

static int interrupt_pending(void) {
  return (R_ToplevelExec(check_interrupt_cb, NULL) == FALSE);
}

/* ------------------------------------------------------------------ */
/* Queue and active list (callers hold s->lock unless noted)           */
/* ------------------------------------------------------------------ */

/* takes the lock itself */
static void enqueue(cw_server_t *s, cw_request_t *r) {
  cw_mutex_lock(&s->lock);
  r->next = NULL;
  if (s->q_tail) s->q_tail->next = r;
  else s->q_head = r;
  s->q_tail = r;
  cw_cond_signal(&s->q_cv);
  cw_mutex_unlock(&s->lock);
}

static cw_request_t *find_active(cw_server_t *s, int id) {
  for (cw_request_t *c = s->active_head; c; c = c->next) {
    if (c->id == id) return c;
  }
  return NULL;
}

static void push_active(cw_server_t *s, cw_request_t *r) {
  r->next = s->active_head;
  s->active_head = r;
}

static void remove_active(cw_server_t *s, cw_request_t *r) {
  cw_request_t **pp = &s->active_head;
  while (*pp) {
    if (*pp == r) {
      *pp = r->next;
      r->next = NULL;
      return;
    }
    pp = &((*pp)->next);
  }
}

/* Dequeue with timeout, called on the R thread.
 *   1  => got an event (*out set)
 *   0  => timeout or server stopped (*out = NULL)
 *  -1  => user interrupt pending
 * HTTP requests and WebSocket connects move to the active list so that
 * send_response() can find them; the other events are transient. */
static int dequeue_timeout(cw_server_t *s, cw_request_t **out, int timeout_ms) {
  if (timeout_ms < 0) timeout_ms = 0;
  *out = NULL;

  cw_mutex_lock(&s->lock);
  int remaining = timeout_ms;

  while (s->q_head == NULL && s->running) {
    cw_mutex_unlock(&s->lock);
#ifndef _WIN32
    sched_yield();
#endif
    if (interrupt_pending()) {
      return -1;
    }
    cw_mutex_lock(&s->lock);
    if (s->q_head != NULL || !s->running) break;
    if (remaining <= 0) break;
    int slice = remaining > 50 ? 50 : remaining;
    (void)cond_wait_ms(&s->q_cv, &s->lock, slice);
    remaining -= slice;
  }

  if (s->q_head == NULL) {
    cw_mutex_unlock(&s->lock);
    return 0;
  }

  cw_request_t *r = s->q_head;
  s->q_head = r->next;
  if (!s->q_head) s->q_tail = NULL;

  if (r->event_type == CW_EVENT_HTTP || r->event_type == CW_EVENT_WS_CONNECT) {
    push_active(s, r);
  } else {
    r->next = NULL;
  }
  cw_mutex_unlock(&s->lock);

  *out = r;
  return 1;
}

/* ------------------------------------------------------------------ */
/* Copying request information (worker thread)                         */
/* ------------------------------------------------------------------ */

static void copy_headers(cw_request_t *r, const struct mg_request_info *req) {
  r->headers = NULL;
  r->num_headers = 0;
  if (!req || req->num_headers <= 0) return;

  int n = req->num_headers;
  if (n > 64) n = 64; /* civetweb's own array size */

  r->headers = (cw_hdr_t *)calloc((size_t)n, sizeof(cw_hdr_t));
  if (!r->headers) { r->alloc_failed = 1; return; }
  r->num_headers = n;
  for (int i = 0; i < n; i++) {
    r->headers[i].name  = dup_str(req->http_headers[i].name);
    r->headers[i].value = dup_str(req->http_headers[i].value);
    if (!r->headers[i].name || !r->headers[i].value) r->alloc_failed = 1;
  }
}

static void copy_request_info(cw_request_t *r, const struct mg_connection *conn) {
  const struct mg_request_info *req = mg_get_request_info(conn);
  const char *m = (req && req->request_method) ? req->request_method : "GET";
  const char *p = (req && req->request_uri)    ? req->request_uri    : "/";
  const char *q = (req && req->query_string)   ? req->query_string   : "";

  r->method = dup_str(m);
  r->path   = dup_str(p);
  r->query  = dup_str(q);
  if (!r->method || !r->path || !r->query) r->alloc_failed = 1;

  if (req) {
    strncpy(r->remote_addr, req->remote_addr, sizeof(r->remote_addr) - 1);
    r->remote_addr[sizeof(r->remote_addr) - 1] = '\0';
    r->remote_port = req->remote_port;
  }
  copy_headers(r, req);
}

static void read_body(cw_server_t *s, cw_request_t *r, struct mg_connection *conn,
                      const struct mg_request_info *req) {
  r->req_body = NULL;
  r->req_body_len = 0;
  r->req_body_too_large = 0;
  if (!conn || !req || req->content_length == 0) return;

  long long clen = req->content_length;
  size_t limit = s->max_body;
  if (clen > 0 && (size_t)clen > limit) r->req_body_too_large = 1;

  size_t cap = (clen > 0 && (size_t)clen <= limit) ? (size_t)clen : limit;
  r->req_body = (unsigned char *)malloc(cap ? cap : 1);
  if (!r->req_body) { r->alloc_failed = 1; return; }

  size_t total_read = 0;
  unsigned char chunk[8192];
  int n;
  while ((n = mg_read(conn, chunk, sizeof(chunk))) > 0) {
    size_t space = (total_read < cap) ? (cap - total_read) : 0;
    size_t to_copy = ((size_t)n < space) ? (size_t)n : space;
    if (to_copy > 0) {
      memcpy(r->req_body + total_read, chunk, to_copy);
      total_read += to_copy;
    }
    if ((size_t)n > to_copy) r->req_body_too_large = 1;
  }
  r->req_body_len = total_read;
  if (total_read == 0) { free(r->req_body); r->req_body = NULL; }
}

/* ------------------------------------------------------------------ */
/* Applying R's answer (R thread) and writing it (worker thread)       */
/* ------------------------------------------------------------------ */

static void apply_response_from_R(cw_request_t *r, SEXP res) {
  r->status = 200;
  free(r->status_text);   r->status_text = NULL;
  free(r->content_type);  r->content_type = dup_str("text/plain");
  free(r->body);          r->body = NULL; r->body_len = 0;
  free_headers(r->res_headers, r->num_res_headers);
  r->res_headers = NULL;  r->num_res_headers = 0;

  if (TYPEOF(res) == STRSXP && LENGTH(res) >= 1) {
    SEXP s0 = STRING_ELT(res, 0);
    const char *str = (s0 == NA_STRING) ? "" : CHAR(s0);
    r->body = (unsigned char *)dup_str(str);
    r->body_len = r->body ? strlen(str) : 0;
    return;
  }
  if (TYPEOF(res) != VECSXP) return;

  SEXP names = Rf_getAttrib(res, R_NamesSymbol);
  if (TYPEOF(names) != STRSXP || LENGTH(names) != LENGTH(res)) return;

  for (int i = 0; i < LENGTH(res); i++) {
    const char *n = CHAR(STRING_ELT(names, i));
    SEXP v = VECTOR_ELT(res, i);

    if (strcmp(n, "status") == 0) {
      int sc = Rf_asInteger(v);
      r->status = (sc == NA_INTEGER) ? 500 : sc;
    } else if (strcmp(n, "status_text") == 0) {
      if (TYPEOF(v) == STRSXP && LENGTH(v) >= 1 && STRING_ELT(v, 0) != NA_STRING)
        r->status_text = dup_str(CHAR(STRING_ELT(v, 0)));
    } else if (strcmp(n, "body") == 0) {
      free(r->body); r->body = NULL; r->body_len = 0;
      if (TYPEOF(v) == STRSXP && LENGTH(v) >= 1) {
        SEXP b0 = STRING_ELT(v, 0);
        const char *str = (b0 == NA_STRING) ? "" : CHAR(b0);
        r->body = (unsigned char *)dup_str(str);
        r->body_len = r->body ? strlen(str) : 0;
      } else if (TYPEOF(v) == RAWSXP) {
        size_t blen = (size_t)XLENGTH(v);
        if (blen > 0) {
          r->body = (unsigned char *)malloc(blen);
          if (r->body) {
            memcpy(r->body, RAW(v), blen);
            r->body_len = blen;
          } else {
            r->status = 500;
          }
        }
      }
    } else if (strcmp(n, "headers") == 0) {
      if (TYPEOF(v) != VECSXP) continue;
      SEXP hn = Rf_getAttrib(v, R_NamesSymbol);
      if (hn == R_NilValue || TYPEOF(hn) != STRSXP || LENGTH(hn) != LENGTH(v)) continue;
      int nh = LENGTH(v);
      free_headers(r->res_headers, r->num_res_headers);
      r->res_headers = (cw_hdr_t *)calloc((size_t)nh, sizeof(cw_hdr_t));
      if (!r->res_headers) { r->num_res_headers = 0; r->status = 500; continue; }
      r->num_res_headers = nh;
      for (int j = 0; j < nh; j++) {
        const char *hk = CHAR(STRING_ELT(hn, j));
        SEXP hv_sexp = VECTOR_ELT(v, j);
        const char *hv = (TYPEOF(hv_sexp) == STRSXP && LENGTH(hv_sexp) > 0)
                         ? CHAR(STRING_ELT(hv_sexp, 0)) : "";
        r->res_headers[j].name  = dup_str(hk);
        r->res_headers[j].value = dup_str(hv);
        if (strcmp(hk, "Content-Type") == 0) {
          free(r->content_type);
          r->content_type = dup_str(hv);
        }
      }
    }
  }
}

/* R's decision on a WebSocket connect: TRUE/FALSE, or a list whose
 * status (if any) other than 101/200 means refuse with that status. */
static void apply_connect_decision(cw_request_t *r, SEXP res) {
  r->accept = 0;
  r->status = 403;
  if (TYPEOF(res) == LGLSXP && LENGTH(res) >= 1) {
    r->accept = (LOGICAL(res)[0] == TRUE);
    return;
  }
  if (TYPEOF(res) == VECSXP) {
    SEXP names = Rf_getAttrib(res, R_NamesSymbol);
    int status = 0;
    if (TYPEOF(names) == STRSXP) {
      for (int i = 0; i < LENGTH(res); i++) {
        if (strcmp(CHAR(STRING_ELT(names, i)), "status") == 0) {
          status = Rf_asInteger(VECTOR_ELT(res, i));
        }
      }
    }
    if (status == 0 || status == 101 || status == 200) {
      r->accept = 1;
    } else {
      r->status = (status == NA_INTEGER) ? 403 : status;
    }
  }
}

static void send_header_line(struct mg_connection *conn, int manual, const char *k, const char *v) {
  if (manual) mg_printf(conn, "%s: %s\r\n", k, v);
  else mg_response_header_add(conn, k, v, -1);
}

static void write_http_response(struct mg_connection *conn, cw_request_t *r) {
  int manual = (r->status_text != NULL);
  if (manual) {
    mg_printf(conn, "HTTP/1.1 %d %s\r\n", r->status, r->status_text);
    mg_disable_connection_keep_alive(conn);
  } else {
    mg_response_header_start(conn, r->status);
  }

  int ct_sent = 0;
  for (int i = 0; i < r->num_res_headers; i++) {
    if (!r->res_headers[i].name) continue;
    send_header_line(conn, manual, r->res_headers[i].name,
                     r->res_headers[i].value ? r->res_headers[i].value : "");
    if (!mg_strcasecmp(r->res_headers[i].name, "Content-Type")) ct_sent = 1;
  }
  if (!ct_sent) send_header_line(conn, manual, "Content-Type",
                                 r->content_type ? r->content_type : "text/plain");

  char clen[64];
  snprintf(clen, sizeof(clen), "%zu", r->body_len);
  send_header_line(conn, manual, "Content-Length", clen);
  if (manual) mg_printf(conn, "\r\n");
  else mg_response_header_send(conn);

  if (r->body_len && r->body) mg_write(conn, r->body, r->body_len);
}

/* Block a worker until R has answered (or the server stopped). */
static void wait_for_R(cw_request_t *r) {
  cw_mutex_lock(&r->lock);
  while (!r->responded) {
    cw_cond_wait(&r->cv, &r->lock);
  }
  cw_mutex_unlock(&r->lock);
}

/* ------------------------------------------------------------------ */
/* civetweb callbacks (worker threads)                                 */
/* ------------------------------------------------------------------ */

static int is_static_uri(cw_server_t *s, const char *uri) {
  if (!uri) return 0;
  for (int i = 0; i < s->n_static; i++) {
    if (strncmp(uri, s->static_prefixes[i], s->static_prefix_len[i]) == 0) return 1;
  }
  return 0;
}

static int http_handler(struct mg_connection *conn, void *cbdata) {
  cw_server_t *s = (cw_server_t *)cbdata;
  const struct mg_request_info *req = mg_get_request_info(conn);

  /* civetweb serves these itself from document_root / the rewrites */
  if (req && is_static_uri(s, req->local_uri)) return 0;

  /* Port probes get an immediate answer so they never occupy R. */
  if (!req || !req->request_method || req->request_method[0] == '\0' ||
      (!strcmp(req->request_method, "HEAD") && req->request_uri &&
       !strcmp(req->request_uri, "/"))) {
    mg_printf(conn, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    return 1;
  }

  cw_mutex_lock(&s->lock);
  int running = s->running;
  cw_mutex_unlock(&s->lock);
  if (!running) {
    mg_printf(conn, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    return 1;
  }

  cw_request_t *r = req_new(s, CW_EVENT_HTTP);
  if (!r) {
    mg_printf(conn, "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    return 1;
  }
  r->conn = conn;
  copy_request_info(r, conn);
  read_body(s, r, conn, req);
  if (r->alloc_failed) {
    mg_printf(conn, "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    free_req(r);
    return 1;
  }

  r->content_type = dup_str("text/plain");
  cw_mutex_lock(&s->lock);
  s->in_flight++;
  cw_mutex_unlock(&s->lock);
  enqueue(s, r);
  wait_for_R(r);
  write_http_response(conn, r);

  cw_mutex_lock(&s->lock);
  remove_active(s, r);
  s->in_flight--;
  cw_cond_broadcast(&s->drain_cv);
  cw_mutex_unlock(&s->lock);
  free_req(r);
  return 1;
}

/* Before the handshake: ask R. The request becomes the connection's
 * anchor when R accepts. */
static int ws_connect_handler(const struct mg_connection *conn, void *cbdata) {
  cw_server_t *s = (cw_server_t *)cbdata;

  cw_mutex_lock(&s->lock);
  int running = s->running;
  cw_mutex_unlock(&s->lock);
  if (!running) return 1;

  cw_request_t *r = req_new(s, CW_EVENT_WS_CONNECT);
  if (!r) return 1;
  r->conn = (struct mg_connection *)conn;
  copy_request_info(r, conn);
  if (r->alloc_failed) {
    free_req(r);
    return 1;
  }

  cw_mutex_lock(&s->lock);
  s->in_flight++;
  cw_mutex_unlock(&s->lock);
  enqueue(s, r);
  wait_for_R(r);

  if (!r->accept) {
    mg_send_http_error((struct mg_connection *)conn, r->status, "%s", "");
    cw_mutex_lock(&s->lock);
    remove_active(s, r);
    s->in_flight--;
    cw_cond_broadcast(&s->drain_cv);
    cw_mutex_unlock(&s->lock);
    free_req(r);
    return 1;
  }

  /* Accepted: the request lives on as the anchor until the close event
   * is dequeued on the R thread. */
  cw_mutex_lock(&s->lock);
  r->event_type = CW_EVENT_WS_READY;
  s->in_flight--;
  cw_cond_broadcast(&s->drain_cv);
  cw_mutex_unlock(&s->lock);
  mg_set_user_connection_data(conn, r);
  return 0;
}

static void ws_ready_handler(struct mg_connection *conn, void *cbdata) {
  cw_server_t *s = (cw_server_t *)cbdata;
  cw_request_t *anchor = (cw_request_t *)mg_get_user_connection_data(conn);
  if (!anchor) return;

  cw_request_t *r = req_new(s, CW_EVENT_WS_READY);
  if (!r) return;
  r->id = anchor->id;
  r->path = dup_str(anchor->path);
  if (!r->path) { free_req(r); return; }
  memcpy(r->remote_addr, anchor->remote_addr, sizeof(r->remote_addr));
  r->remote_port = anchor->remote_port;
  enqueue(s, r);
}

static int ws_data_handler(struct mg_connection *conn, int bits, char *data,
                           size_t len, void *cbdata) {
  cw_server_t *s = (cw_server_t *)cbdata;
  int opcode = bits & 0xf;
  cw_request_t *anchor = (cw_request_t *)mg_get_user_connection_data(conn);
  if (!anchor) return 0;

  if (anchor->close_requested) return 0;

  /* Text, binary and continuation frames go to R; civetweb answers
   * ping, pong and close itself. */
  if (opcode != MG_WEBSOCKET_OPCODE_TEXT && opcode != MG_WEBSOCKET_OPCODE_BINARY &&
      opcode != MG_WEBSOCKET_OPCODE_CONTINUATION) {
    return 1;
  }

  cw_request_t *r = req_new(s, CW_EVENT_WS_DATA);
  if (!r) return 1;
  r->id = anchor->id;
  r->ws_fin = (bits & 0x80) ? 1 : 0;
  r->ws_binary = (opcode == MG_WEBSOCKET_OPCODE_BINARY) ? 1 : 0;
  if (len > 0) {
    r->req_body = (unsigned char *)malloc(len);
    if (!r->req_body) { free_req(r); return 1; }
    memcpy(r->req_body, data, len);
    r->req_body_len = len;
  }
  memcpy(r->remote_addr, anchor->remote_addr, sizeof(r->remote_addr));
  r->remote_port = anchor->remote_port;
  enqueue(s, r);
  return 1;
}

static void ws_close_handler(const struct mg_connection *conn, void *cbdata) {
  cw_server_t *s = (cw_server_t *)cbdata;
  cw_request_t *anchor = (cw_request_t *)mg_get_user_connection_data(conn);
  if (!anchor) return;

  /* Under the anchor's lock, so a write in progress finishes first and
   * no later write sees a live pointer. */
  cw_mutex_lock(&anchor->lock);
  anchor->conn = NULL;
  cw_mutex_unlock(&anchor->lock);
  mg_set_user_connection_data(conn, NULL);

  cw_request_t *r = req_new(s, CW_EVENT_WS_CLOSE);
  if (!r) return;   /* the anchor is reclaimed at stop instead */
  r->id = anchor->id;
  memcpy(r->remote_addr, anchor->remote_addr, sizeof(r->remote_addr));
  r->remote_port = anchor->remote_port;
  enqueue(s, r);
}

/* ------------------------------------------------------------------ */
/* Server lifecycle                                                    */
/* ------------------------------------------------------------------ */

/* Answer every blocked worker, stop civetweb, free what is left. Safe to
 * call twice. Runs on the R thread (stop_server or the finalizer). */
static void server_stop(cw_server_t *s) {
  if (!s || s->stopped) return;

  cw_mutex_lock(&s->lock);
  s->running = 0;
  cw_cond_broadcast(&s->q_cv);

  /* Queued events: HTTP and CONNECT are owned by blocked workers, which
   * write the refusal and free them, so they move to the active list to
   * be counted; the rest are ours to free. */
  cw_request_t *q = s->q_head;
  s->q_head = s->q_tail = NULL;
  while (q) {
    cw_request_t *next = q->next;
    q->next = NULL;
    if (q->event_type == CW_EVENT_HTTP || q->event_type == CW_EVENT_WS_CONNECT) {
      push_active(s, q);
    } else {
      free_req(q);
    }
    q = next;
  }

  /* Every HTTP and CONNECT request not yet answered gets a 503 / refusal. */
  for (cw_request_t *r = s->active_head; r; r = r->next) {
    if (r->event_type == CW_EVENT_HTTP || r->event_type == CW_EVENT_WS_CONNECT) {
      cw_mutex_lock(&r->lock);
      if (!r->responded) {
        r->status = 503;
        r->accept = 0;
        free(r->body); r->body = NULL; r->body_len = 0;
        r->responded = 1;
        cw_cond_signal(&r->cv);
      }
      cw_mutex_unlock(&r->lock);
    }
  }

  /* Let the workers write those answers before civetweb's stop flag
   * silences every write. Bounded: a stuck client cannot hold stop. */
  int waited = 0;
  while (s->in_flight > 0 && waited < 2000) {
    (void)cond_wait_ms(&s->drain_cv, &s->lock, 50);
    waited += 50;
  }
  cw_mutex_unlock(&s->lock);

  /* Joins the workers. HTTP workers remove and free their requests;
   * WebSocket close callbacks queue close events for anchors. */
  if (s->ctx) {
    mg_stop(s->ctx);
    s->ctx = NULL;
  }

  cw_mutex_lock(&s->lock);
  q = s->q_head;
  s->q_head = s->q_tail = NULL;
  while (q) {
    cw_request_t *next = q->next;
    free_req(q);
    q = next;
  }
  cw_request_t *a = s->active_head;
  s->active_head = NULL;
  while (a) {
    cw_request_t *next = a->next;
    free_req(a);
    a = next;
  }
  s->stopped = 1;
  cw_mutex_unlock(&s->lock);
}

static void server_free(cw_server_t *s) {
  if (!s) return;
  free(s->ws_path);
  for (int i = 0; i < s->n_static; i++) free(s->static_prefixes[i]);
  free(s->static_prefixes);
  free(s->static_prefix_len);
  cw_mutex_destroy(&s->lock);
  cw_cond_destroy(&s->q_cv);
  cw_cond_destroy(&s->drain_cv);
  free(s);
}

static void server_finalizer(SEXP xptr) {
  cw_server_t *s = (cw_server_t *)R_ExternalPtrAddr(xptr);
  if (!s) return;
  R_ClearExternalPtr(xptr);
  server_stop(s);
  server_free(s);
}

static cw_server_t *server_from_xptr(SEXP xptr, int must_run) {
  if (TYPEOF(xptr) != EXTPTRSXP) Rf_error("not a server handle");
  cw_server_t *s = (cw_server_t *)R_ExternalPtrAddr(xptr);
  if (!s) Rf_error("server has been released");
  if (must_run && s->stopped) Rf_error("server is stopped");
  return s;
}

/* ------------------------------------------------------------------ */
/* R entry points (R thread)                                           */
/* ------------------------------------------------------------------ */

static const char *scalar_string(SEXP x, const char *what) {
  if (!Rf_isString(x) || LENGTH(x) < 1 || STRING_ELT(x, 0) == NA_STRING)
    Rf_error("%s must be character(1)", what);
  return CHAR(STRING_ELT(x, 0));
}

SEXP civetweb_start_server(SEXP portS, SEXP hostS, SEXP threadsS, SEXP max_bodyS,
                           SEXP timeoutS, SEXP ws_pathS, SEXP static_prefixesS,
                           SEXP static_dirsS, SEXP keep_aliveS, SEXP tls_certS) {
  if (!Rf_isInteger(portS) || LENGTH(portS) < 1)       Rf_error("port must be an integer");
  if (!Rf_isInteger(threadsS) || LENGTH(threadsS) < 1) Rf_error("num_threads must be an integer");
  if (!Rf_isReal(max_bodyS) || LENGTH(max_bodyS) < 1)  Rf_error("max_body_size must be a number");
  if (!Rf_isInteger(timeoutS) || LENGTH(timeoutS) < 1) Rf_error("request_timeout_ms must be an integer");
  if (!Rf_isLogical(keep_aliveS) || LENGTH(keep_aliveS) < 1) Rf_error("keep_alive must be logical(1)");
  const char *host = scalar_string(hostS, "host");
  const char *ws_path = scalar_string(ws_pathS, "ws_path");
  /* NULL for plain HTTP; otherwise one PEM file with certificate and key,
   * which makes the port a TLS port ("s" suffix in listening_ports). */
  const char *tls_cert = Rf_isNull(tls_certS) ? NULL : scalar_string(tls_certS, "tls_cert");
  if (!Rf_isString(static_prefixesS) || !Rf_isString(static_dirsS) ||
      LENGTH(static_prefixesS) != LENGTH(static_dirsS))
    Rf_error("static prefixes and dirs must be character vectors of one length");

  int port = INTEGER(portS)[0];
  int threads = INTEGER(threadsS)[0];
  int timeout = INTEGER(timeoutS)[0];
  int keep_alive = (LOGICAL(keep_aliveS)[0] == TRUE);
  int n_static = LENGTH(static_prefixesS);

  cw_server_t *s = (cw_server_t *)calloc(1, sizeof(*s));
  if (!s) Rf_error("out of memory");
  cw_mutex_init(&s->lock);
  cw_cond_init(&s->q_cv);
  cw_cond_init(&s->drain_cv);
  s->next_id = 1;
  s->max_body = (size_t)REAL(max_bodyS)[0];
  s->ws_path = dup_str(ws_path);
  if (!s->ws_path) { server_free(s); Rf_error("out of memory"); }

  if (n_static > 0) {
    s->static_prefixes = (char **)calloc((size_t)n_static, sizeof(char *));
    s->static_prefix_len = (size_t *)calloc((size_t)n_static, sizeof(size_t));
    if (!s->static_prefixes || !s->static_prefix_len) { server_free(s); Rf_error("out of memory"); }
    for (int i = 0; i < n_static; i++) {
      const char *p = CHAR(STRING_ELT(static_prefixesS, i));
      s->static_prefixes[i] = dup_str(p);
      if (!s->static_prefixes[i]) { s->n_static = i; server_free(s); Rf_error("out of memory"); }
      s->static_prefix_len[i] = strlen(p);
    }
    s->n_static = n_static;
  }

  /* civetweb options. Rewrites map each static prefix to its directory;
   * document_root has to exist for file serving to be enabled at all, so
   * the first directory doubles as it. */
  char addr[160];
  snprintf(addr, sizeof(addr), "%s:%d%s", host, port, tls_cert ? "s" : "");
  char threads_buf[16], timeout_buf[16];
  snprintf(threads_buf, sizeof(threads_buf), "%d", threads);
  snprintf(timeout_buf, sizeof(timeout_buf), "%d", timeout);

  char *rewrites = NULL;
  const char *doc_root = NULL;
  if (n_static > 0) {
    size_t total = 1;
    for (int i = 0; i < n_static; i++) {
      total += strlen(CHAR(STRING_ELT(static_prefixesS, i))) +
               strlen(CHAR(STRING_ELT(static_dirsS, i))) + 2;
    }
    rewrites = (char *)R_alloc(total, 1);
    rewrites[0] = '\0';
    for (int i = 0; i < n_static; i++) {
      if (i) strcat(rewrites, ",");
      strcat(rewrites, CHAR(STRING_ELT(static_prefixesS, i)));
      strcat(rewrites, "=");
      strcat(rewrites, CHAR(STRING_ELT(static_dirsS, i)));
    }
    doc_root = CHAR(STRING_ELT(static_dirsS, 0));
  }

  const char *opts[24];
  int k = 0;
  opts[k++] = "listening_ports";       opts[k++] = addr;
  opts[k++] = "num_threads";           opts[k++] = threads_buf;
  opts[k++] = "request_timeout_ms";    opts[k++] = timeout_buf;
  opts[k++] = "linger_timeout_ms";     opts[k++] = "0";
  opts[k++] = "enable_keep_alive";     opts[k++] = keep_alive ? "yes" : "no";
  opts[k++] = "enable_directory_listing"; opts[k++] = "no";
  if (doc_root) {
    opts[k++] = "document_root";       opts[k++] = doc_root;
    opts[k++] = "url_rewrite_patterns"; opts[k++] = rewrites;
  }
  if (tls_cert) {
    opts[k++] = "ssl_certificate";     opts[k++] = tls_cert;
  }
  opts[k] = NULL;

  s->running = 1;
  s->ctx = mg_start(NULL, s, opts);
  if (!s->ctx) {
    server_free(s);
    Rf_error("could not start the server on %s", addr);
  }
  mg_set_request_handler(s->ctx, "**", http_handler, s);
  mg_set_websocket_handler(s->ctx, s->ws_path, ws_connect_handler, ws_ready_handler,
                           ws_data_handler, ws_close_handler, s);

  SEXP xptr = PROTECT(R_MakeExternalPtr(s, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(xptr, server_finalizer, TRUE);
  UNPROTECT(1);
  return xptr;
}

/* Whether TLS was compiled in (civetweb's feature bit, no server needed). */
SEXP civetweb_has_tls(void) {
  return Rf_ScalarLogical(mg_check_feature(MG_FEATURES_TLS) != 0);
}

SEXP civetweb_stop_server(SEXP xptr) {
  if (TYPEOF(xptr) != EXTPTRSXP) Rf_error("not a server handle");
  cw_server_t *s = (cw_server_t *)R_ExternalPtrAddr(xptr);
  if (!s) return R_NilValue;
  server_stop(s);
  return R_NilValue;
}

SEXP civetweb_server_port(SEXP xptr) {
  cw_server_t *s = server_from_xptr(xptr, 1);
  struct mg_server_port ports[4];
  int n = mg_get_server_ports(s->ctx, 4, ports);
  if (n < 1) return Rf_ScalarInteger(NA_INTEGER);
  return Rf_ScalarInteger(ports[0].port);
}

static SEXP make_interrupt_sentinel(void) {
  SEXP out = PROTECT(Rf_allocVector(VECSXP, 1));
  SEXP nms = PROTECT(Rf_allocVector(STRSXP, 1));
  SET_STRING_ELT(nms, 0, Rf_mkChar("interrupted"));
  Rf_setAttrib(out, R_NamesSymbol, nms);
  SET_VECTOR_ELT(out, 0, Rf_ScalarLogical(1));
  UNPROTECT(2);
  return out;
}

SEXP civetweb_next_request_timeout(SEXP xptr, SEXP timeout_ms) {
  cw_server_t *s = server_from_xptr(xptr, 0);
  int ms = Rf_asInteger(timeout_ms);
  if (ms == NA_INTEGER || ms < 0) Rf_error("timeout_ms must be >= 0");

  cw_request_t *r = NULL;
  int rc = dequeue_timeout(s, &r, ms);
  if (rc == -1) return make_interrupt_sentinel();
  if (rc == 0) return R_NilValue;

  cw_event_t type = r->event_type;
  int id = r->id;

  const char *names[] = { "id", "method", "path", "query", "headers", "body",
                          "body_too_large", "type", "remote_addr", "remote_port",
                          "fin", "binary" };
  const int nf = 12;
  SEXP out = PROTECT(Rf_allocVector(VECSXP, nf));
  SEXP nms = PROTECT(Rf_allocVector(STRSXP, nf));
  for (int i = 0; i < nf; i++) SET_STRING_ELT(nms, i, Rf_mkChar(names[i]));
  Rf_setAttrib(out, R_NamesSymbol, nms);

  SET_VECTOR_ELT(out, 0, Rf_ScalarInteger(id));
  SET_VECTOR_ELT(out, 1, Rf_mkString(r->method ? r->method : ""));
  SET_VECTOR_ELT(out, 2, Rf_mkString(r->path ? r->path : ""));
  SET_VECTOR_ELT(out, 3, Rf_mkString(r->query ? r->query : ""));

  SEXP hval = PROTECT(Rf_allocVector(STRSXP, r->num_headers));
  SEXP hnm  = PROTECT(Rf_allocVector(STRSXP, r->num_headers));
  for (int i = 0; i < r->num_headers; i++) {
    SET_STRING_ELT(hnm,  i, Rf_mkChar(r->headers[i].name  ? r->headers[i].name  : ""));
    SET_STRING_ELT(hval, i, Rf_mkChar(r->headers[i].value ? r->headers[i].value : ""));
  }
  Rf_setAttrib(hval, R_NamesSymbol, hnm);
  SET_VECTOR_ELT(out, 4, hval);

  SEXP b = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)r->req_body_len));
  if (r->req_body_len > 0) memcpy(RAW(b), r->req_body, r->req_body_len);
  SET_VECTOR_ELT(out, 5, b);

  SET_VECTOR_ELT(out, 6, Rf_ScalarLogical(r->req_body_too_large ? 1 : 0));
  SET_VECTOR_ELT(out, 7, Rf_ScalarInteger((int)type));
  SET_VECTOR_ELT(out, 8, Rf_mkString(r->remote_addr));
  SET_VECTOR_ELT(out, 9, Rf_ScalarInteger(r->remote_port));
  SET_VECTOR_ELT(out, 10, Rf_ScalarLogical(r->ws_fin));
  SET_VECTOR_ELT(out, 11, Rf_ScalarLogical(r->ws_binary));
  UNPROTECT(5);

  /* Transient events are done once copied. A close event also retires
   * its anchor: the worker's close callback has already run, so nothing
   * else holds a pointer to it. */
  if (type == CW_EVENT_WS_READY || type == CW_EVENT_WS_DATA) {
    free_req(r);
  } else if (type == CW_EVENT_WS_CLOSE) {
    cw_mutex_lock(&s->lock);
    cw_request_t *anchor = find_active(s, id);
    if (anchor && anchor->event_type == CW_EVENT_WS_READY) {
      remove_active(s, anchor);
      free_req(anchor);
    }
    cw_mutex_unlock(&s->lock);
    free_req(r);
  }
  return out;
}

SEXP civetweb_send_response(SEXP xptr, SEXP idS, SEXP res) {
  cw_server_t *s = server_from_xptr(xptr, 0);
  int id = Rf_asInteger(idS);
  if (id == NA_INTEGER) Rf_error("id must be integer");

  cw_mutex_lock(&s->lock);
  cw_request_t *r = find_active(s, id);
  cw_mutex_unlock(&s->lock);
  if (!r) Rf_error("unknown request id");

  cw_mutex_lock(&r->lock);
  if (r->responded) {
    cw_mutex_unlock(&r->lock);
    Rf_error("request %d has already been answered", id);
  }
  if (r->event_type == CW_EVENT_WS_CONNECT) {
    apply_connect_decision(r, res);
  } else {
    apply_response_from_R(r, res);
  }
  r->responded = 1;
  cw_cond_signal(&r->cv);
  cw_mutex_unlock(&r->lock);
  return R_NilValue;
}

/* Write to a live WebSocket anchor under its lock. Returns the number of
 * bytes written, or -1 when the id is not an open connection. */
static int anchor_write(cw_server_t *s, int id, int opcode, const char *data, size_t len) {
  cw_mutex_lock(&s->lock);
  cw_request_t *r = find_active(s, id);
  cw_mutex_unlock(&s->lock);
  if (!r || r->event_type != CW_EVENT_WS_READY) return -1;

  int n;
  cw_mutex_lock(&r->lock);
  if (!r->conn || r->close_requested) {
    n = -1;
  } else {
    n = mg_websocket_write(r->conn, opcode, data, len);
    if (opcode == MG_WEBSOCKET_OPCODE_CONNECTION_CLOSE) r->close_requested = 1;
  }
  cw_mutex_unlock(&r->lock);
  return n;
}

SEXP civetweb_ws_send(SEXP xptr, SEXP idS, SEXP dataS) {
  cw_server_t *s = server_from_xptr(xptr, 0);
  int id = Rf_asInteger(idS);
  int n;
  if (TYPEOF(dataS) == RAWSXP) {
    n = anchor_write(s, id, MG_WEBSOCKET_OPCODE_BINARY,
                     (const char *)RAW(dataS), (size_t)XLENGTH(dataS));
  } else {
    const char *txt = scalar_string(dataS, "data");
    n = anchor_write(s, id, MG_WEBSOCKET_OPCODE_TEXT, txt, strlen(txt));
  }
  return Rf_ScalarLogical(n > 0);
}

SEXP civetweb_ws_close(SEXP xptr, SEXP idS, SEXP codeS) {
  cw_server_t *s = server_from_xptr(xptr, 0);
  int id = Rf_asInteger(idS);
  int code = Rf_asInteger(codeS);
  if (code == NA_INTEGER) code = 1000;
  char payload[2];
  payload[0] = (char)((code >> 8) & 0xff);
  payload[1] = (char)(code & 0xff);
  int n = anchor_write(s, id, MG_WEBSOCKET_OPCODE_CONNECTION_CLOSE, payload, 2);
  return Rf_ScalarLogical(n > 0);
}

SEXP civetweb_server_running(SEXP xptr) {
  if (TYPEOF(xptr) != EXTPTRSXP) return Rf_ScalarLogical(0);
  cw_server_t *s = (cw_server_t *)R_ExternalPtrAddr(xptr);
  return Rf_ScalarLogical(s != NULL && !s->stopped);
}
