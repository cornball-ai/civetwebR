if (requireNamespace("tinytest", quietly = TRUE)) {
    # Every test that opens a socket exits unless tinytest's at_home()
    # is TRUE. TT_AT_HOME=TRUE in the environment (CI sets it) runs
    # them under R CMD check too; CRAN's checks leave them out.
    tinytest::test_package("civetwebR",
        at_home = identical(Sys.getenv("TT_AT_HOME"), "TRUE"))
}
