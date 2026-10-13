# WebSocket through serve(): the handshake and an echo over a raw
# socket. Local-only: sockets, a spawnable R and wall-clock time.

if (!at_home()) exit_file("socket tests run at home")
if (!requireNamespace("callr", quietly = TRUE)) exit_file("callr not installed")
source("helper_server.R", local = TRUE)

local({
    port <- sample(10000:20000, 1)
    p <- serve_bg(port, setup = function() {
        # echo every message back to the client it came from
        on_ws("message", function(req) {
            ws_send(req$id, paste0("ECHO:", rawToChar(req$body)))
        })
    }, timeout_ms = 10L)
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    con <- socketConnection(host = "127.0.0.1", port = port, open = "r+b",
        blocking = TRUE)
    on.exit(close(con), add = TRUE)

    # 1. the handshake
    writeLines(c(
        "GET /ws HTTP/1.1",
        "Host: 127.0.0.1",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        ""
    ), con, sep = "\r\n")
    flush(con)

    # 2. 101 Switching Protocols, then the rest of the head
    status_line <- readLines(con, n = 1, warn = FALSE)
    expect_match(status_line, "101 Switching Protocols")
    repeat {
        line <- readLines(con, n = 1, warn = FALSE)
        if (line == "" || line == "\r") break
    }

    # 3. a masked text frame, as RFC 6455 requires of a client:
    #    [0x81 fin+text] [0x84 mask+len 4] [4-byte key] ["PING" masked]
    payload <- charToRaw("PING")
    mask_key <- as.raw(c(0x01, 0x02, 0x03, 0x04))
    masked_payload <- as.raw(bitwXor(as.integer(payload), as.integer(mask_key)))
    writeBin(as.raw(c(0x81, 0x84)), con)
    writeBin(mask_key, con)
    writeBin(masked_payload, con)
    flush(con)

    # 4. the echo, unmasked (a server must not mask): "ECHO:PING"
    header <- readBin(con, "raw", 2)
    expect_equal(header[1], as.raw(0x81))
    len <- as.integer(header[2])
    expect_equal(len, 9L)
    res_body <- readBin(con, "raw", len)
    expect_equal(rawToChar(res_body), "ECHO:PING")
})
