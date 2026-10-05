/* civetwebR's mg_cry implementation, selected by
 * -DMG_EXTERNAL_FUNCTION_mg_cry_internal_impl in Makevars.
 *
 * civetweb's default writes to stderr when it has no connection and to
 * an error log file otherwise, neither of which an R package may do (and
 * this runs on civetweb's worker threads, where R's own console is off
 * limits). Messages go to the context's log_message callback when one is
 * set, and are dropped otherwise. The signature matches the default in
 * civetweb.c. */

static void
mg_cry_internal_impl(const struct mg_connection *conn,
                     const char *func,
                     unsigned line,
                     const char *fmt,
                     va_list ap)
{
	char buf[MG_BUF_LEN];

	(void)func;
	(void)line;

#if defined(GCC_DIAGNOSTIC)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
#endif
	IGNORE_UNUSED_RESULT(vsnprintf_impl(buf, sizeof(buf), fmt, ap));
#if defined(GCC_DIAGNOSTIC)
#pragma GCC diagnostic pop
#endif
	buf[sizeof(buf) - 1] = 0;

	if (conn && conn->phys_ctx && conn->phys_ctx->callbacks.log_message) {
		(void)conn->phys_ctx->callbacks.log_message(conn, buf);
	}
}
