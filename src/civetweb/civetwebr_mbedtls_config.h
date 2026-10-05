/* civetwebR's adjustments to Mbed TLS's default configuration. Included
 * after mbedtls_config.h through -DMBEDTLS_USER_CONFIG_FILE (Makevars),
 * so the defaults stay as upstream ships them except for what follows.
 *
 * R CMD check refuses compiled code that references printf() or rand().
 * The self tests use both and nothing here runs them, so they are off.
 * Two library paths print through mbedtls_printf() outside the self
 * tests: mbedtls_mpi_write_file() with a NULL stream, and a consistency
 * check of the signature-algorithm tables under MBEDTLS_DEBUG_C. Neither
 * is reached from civetweb, and both run on TLS worker threads where R's
 * console is off limits anyway, so mbedtls_printf() prints nothing. */

#undef MBEDTLS_SELF_TEST

static inline int civetwebr_mbedtls_noprintf(const char *format, ...)
{
	(void)format;
	return 0;
}
#define MBEDTLS_PLATFORM_PRINTF_MACRO civetwebr_mbedtls_noprintf
