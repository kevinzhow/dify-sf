#ifndef RUNTIME_CURL_H
#define RUNTIME_CURL_H
#include <stddef.h>
#include <stdint.h>
// Thin libcurl binding, not an HTTP parser/transport implementation. Only cancel
// may run concurrently with perform. Configure before perform; free afterwards.
typedef struct RuntimeCurlExchange RuntimeCurlExchange;
typedef struct RuntimeCurlSession RuntimeCurlSession;
RuntimeCurlSession *runtime_curl_session_create(void);
void runtime_curl_session_free(RuntimeCurlSession *);
RuntimeCurlExchange *runtime_curl_create(const char *url, const char *proxy, const char *method,
    int verify_tls, long connect_ms, long read_ms, long write_ms, long total_ms, size_t body_limit, RuntimeCurlSession *session);
int runtime_curl_header(RuntimeCurlExchange *, const char *header);
int runtime_curl_body(RuntimeCurlExchange *, const void *bytes, size_t length);
int runtime_curl_perform(RuntimeCurlExchange *);
void runtime_curl_cancel(RuntimeCurlExchange *);
int runtime_curl_cancelled(RuntimeCurlExchange *);
void runtime_curl_free(RuntimeCurlExchange *);
const char *runtime_curl_error(int code);
long runtime_curl_status(RuntimeCurlExchange *);
long runtime_curl_proxy_status(RuntimeCurlExchange *);
const uint8_t *runtime_curl_response_body(RuntimeCurlExchange *);
size_t runtime_curl_response_length(RuntimeCurlExchange *);
const uint8_t *runtime_curl_response_headers(RuntimeCurlExchange *);
size_t runtime_curl_headers_length(RuntimeCurlExchange *);
int runtime_curl_truncated(RuntimeCurlExchange *);
#endif
