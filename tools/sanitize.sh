#!/bin/bash
# Hardening gate: valgrind memcheck, then AddressSanitizer plus
# UndefinedBehaviorSanitizer, each over the whole testthat suite.
#
# Run from the package root. The checkout is installed into scratch
# libraries under $WORK for every pass; the ambient installed civetwebR
# is never exercised. Exits nonzero on a failed expectation, a memcheck
# error or definite leak, or any sanitizer report.
#
# What this mirrors and what it does not: CRAN's valgrind check runs
# the tests under memcheck with an ordinary R, as here. CRAN's ASAN
# checks use an R built with the sanitizer; here a sanitized shared
# object is loaded into a normal R with libasan preloaded, which finds
# the package's own memory errors but not those at the R boundary. CI's
# asan job in the r-hub clang-asan container covers that case.
#
# Reference environment: Ubuntu noble, gcc 13.3.0, valgrind 3.22.0,
# libasan8. The callr child processes the tests start are not traced by
# valgrind (no --trace-children), but they do load the sanitized shared
# object in the ASan pass, since LD_PRELOAD is inherited.

set -euo pipefail

## Never leave differently-flagged objects in src/ for the next normal
## build to reuse, on failure as much as on success.
trap 'rm -f src/*.o src/civetwebR.so src/mbedtls/library/*.o' EXIT

WORK="${WORK:-$(mktemp -d)}"
echo "work dir: $WORK"

## The suite from the source tree against the installed package. The
## tests must see the scratch library, so the run proves which build
## it exercised before running anything.
## NOT_CRAN: every test that opens a socket is behind skip_on_cran(),
## and a run that skips them all would pass vacuously, so the run also
## fails if anything was skipped (the dev machine has openssl and curl).
export NOT_CRAN=true
SUITE='lib <- Sys.getenv("CIVETWEBR_SANITIZE_LIB")
stopifnot(nzchar(lib), identical(find.package("civetwebR"), file.path(lib, "civetwebR")))
library(civetwebR)
res <- testthat::test_dir("tests/testthat", package = "civetwebR",
                          load_package = "installed", reporter = "summary",
                          stop_on_failure = TRUE)
df <- as.data.frame(res)
if (any(df$skipped)) {
  print(df[df$skipped, c("file", "test")])
  stop("tests were skipped; the run proves nothing about them")
}
cat("SUITE-ALL-PASS\n")'

printf '%s\n' "$SUITE" > "$WORK/suite.R"

## R CMD INSTALL --preclean removes src/*.o but not the Mbed TLS objects
## one directory down, and make would then reuse them with the old
## flags; clear them before every build.
clean_objects() {
    rm -f src/*.o src/civetwebR.so src/mbedtls/library/*.o
}

## --no-init-file: the checkout's .Rprofile resets .libPaths() to its
## env/ directory, which would hide the scratch library.
R_ARGS="--no-init-file --no-save --no-restore"

## ---- plain build, for the valgrind pass ----
mkdir -p "$WORK/lib-plain"
clean_objects
R CMD INSTALL --preclean -l "$WORK/lib-plain" . > "$WORK/install-plain.log" 2>&1 \
    || { echo "plain install failed:"; tail -30 "$WORK/install-plain.log"; exit 1; }

## ---- valgrind memcheck ----
## Through R's own -d option, which runs the R binary itself under the
## debugger: Rscript and the R front end exec that binary, and valgrind
## does not follow an exec by default, so a `valgrind Rscript` run
## checks only the launcher. CRAN's check uses the same entry point.
## Gate on access errors and definite leaks. R's own exit-time state
## produces possibly-lost records (interior pointers); those are noise.
echo "=== valgrind"
set +e
R_LIBS="$WORK/lib-plain" CIVETWEBR_SANITIZE_LIB="$WORK/lib-plain" \
    R -d "valgrind --leak-check=full --show-leak-kinds=definite --errors-for-leak-kinds=definite --error-exitcode=99" \
    $R_ARGS -f "$WORK/suite.R" > "$WORK/valgrind.log" 2>&1
rc=$?
set -e
summary=$(grep -E "^==[0-9]+== ERROR SUMMARY" "$WORK/valgrind.log" || true)
grep -E "^==[0-9]+== (ERROR SUMMARY|definitely lost)" "$WORK/valgrind.log" || true
## The summary line is memcheck's proof that it ran the process to the
## end; without it the pass proves nothing.
if [ "$rc" -ne 0 ] || [ -z "$summary" ] || ! grep -q "SUITE-ALL-PASS" "$WORK/valgrind.log"; then
    echo "FAIL: valgrind pass (exit $rc); see $WORK/valgrind.log"
    grep -B2 -A12 -E "^==[0-9]+== (Invalid|Conditional|Use of uninit|Syscall param|[0-9,]+ bytes in [0-9,]+ blocks are definitely)" \
        "$WORK/valgrind.log" | head -80 || true
    tail -15 "$WORK/valgrind.log"
    exit 1
fi
echo "PASS: valgrind"

## ---- AddressSanitizer + UndefinedBehaviorSanitizer ----
## CRAN's config.site puts the sanitizer flags in CC itself, so they
## reach the link step too (SHLIB_LD is $(CC)); R_MAKEVARS_USER keeps
## this out of ~/.R/Makevars.
cat > "$WORK/Makevars.asan" <<EOF
CC = gcc -fsanitize=address,undefined -fno-omit-frame-pointer
CFLAGS = -g -O1 -Wall -pedantic -fno-omit-frame-pointer
EOF
mkdir -p "$WORK/lib-asan"
clean_objects
## --no-test-load: the instrumented .so only loads under the matching
## LD_PRELOAD, which the suite run below provides.
R_MAKEVARS_USER="$WORK/Makevars.asan" \
    R CMD INSTALL --preclean --no-test-load -l "$WORK/lib-asan" . > "$WORK/install-asan.log" 2>&1 \
    || { echo "sanitized install failed:"; tail -30 "$WORK/install-asan.log"; exit 1; }
so="$WORK/lib-asan/civetwebR/libs/civetwebR.so"
## Prove instrumentation landed before trusting any "clean" run. (A
## count, not grep -q: with pipefail, grep -q closing the pipe early
## turns nm's SIGPIPE into a failed pipeline.)
asan_refs=$(nm -u "$so" | grep -c __asan || true)
if [ "$asan_refs" -eq 0 ]; then
    echo "FATAL: $so has no __asan references; the sanitizer flags did not reach the build"
    exit 1
fi
echo "instrumented: $asan_refs __asan references"
libasan=$(ldconfig -p | awk '/libasan\.so\.[0-9]+ /{print $NF; exit}')
[ -n "$libasan" ] || { echo "FATAL: no libasan found by ldconfig"; exit 1; }

## detect_leaks=0: valgrind above owns leak checking; R's exit-time
## reachable allocations drown LSan otherwise. ASan halts on its first
## error; UBSan is told to do the same.
echo "=== ASan + UBSan (preloading $libasan)"
set +e
LD_PRELOAD="$libasan" \
    ASAN_OPTIONS=detect_leaks=0 \
    UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
    R_LIBS="$WORK/lib-asan" CIVETWEBR_SANITIZE_LIB="$WORK/lib-asan" \
    R $R_ARGS -f "$WORK/suite.R" > "$WORK/asan.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] || ! grep -q "SUITE-ALL-PASS" "$WORK/asan.log" \
   || grep -qE "runtime error:|ERROR: AddressSanitizer" "$WORK/asan.log"; then
    echo "FAIL: sanitizer pass (exit $rc); see $WORK/asan.log"
    grep -A25 -E "runtime error:|ERROR: AddressSanitizer" "$WORK/asan.log" | head -80 || true
    tail -15 "$WORK/asan.log"
    exit 1
fi
echo "PASS: ASan + UBSan"
echo "ALL PASS"
