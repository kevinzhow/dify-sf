#include "RuntimeCurl.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct RuntimeCurlExchange {
    CURL *easy;
    struct curl_slist *headers;
    uint8_t *request, *body, *response_headers;
    size_t length, capacity, limit, headers_length;
    atomic_int cancelled;
    int truncated;
    long status, proxy_status, read_ms, write_ms, total_ms;
    struct timespec created;
    int proxy_connecting;
    int timed_out;
    struct timespec last_received;
    int request_started;
};
static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
struct RuntimeCurlSession { CURLSH *share; pthread_mutex_t locks[CURL_LOCK_DATA_LAST]; int initialized; };
static void lock_cookie(CURL *handle, curl_lock_data data, curl_lock_access access, void *context) {
    (void)handle; (void)data; (void)access; pthread_mutex_lock(&((RuntimeCurlSession *)context)->locks[data<CURL_LOCK_DATA_LAST ? data : 0]);
}
static void unlock_cookie(CURL *handle, curl_lock_data data, void *context) {
    (void)handle; (void)data; pthread_mutex_unlock(&((RuntimeCurlSession *)context)->locks[data<CURL_LOCK_DATA_LAST ? data : 0]);
}
RuntimeCurlSession *runtime_curl_session_create(void) {
    pthread_once(&initialization,initialize);
    RuntimeCurlSession *session=calloc(1,sizeof(*session));
    if (!session) return NULL;
    for (int i=0; i<CURL_LOCK_DATA_LAST; i++) {
        if (pthread_mutex_init(&session->locks[i],NULL)) { runtime_curl_session_free(session); return NULL; }
        session->initialized++;
    }
    session->share=curl_share_init();
    if (!session->share) { runtime_curl_session_free(session); return NULL; }
    if (curl_share_setopt(session->share,CURLSHOPT_USERDATA,session)!=CURLSHE_OK ||
        curl_share_setopt(session->share,CURLSHOPT_LOCKFUNC,lock_cookie)!=CURLSHE_OK ||
        curl_share_setopt(session->share,CURLSHOPT_UNLOCKFUNC,unlock_cookie)!=CURLSHE_OK ||
        curl_share_setopt(session->share,CURLSHOPT_SHARE,CURL_LOCK_DATA_COOKIE)!=CURLSHE_OK) {
        runtime_curl_session_free(session); return NULL;
    }
    return session;
}
void runtime_curl_session_free(RuntimeCurlSession *session) {
    if (!session) return;
    if (session->share) curl_share_cleanup(session->share);
    for (int i=0; i<session->initialized; i++) pthread_mutex_destroy(&session->locks[i]);
    free(session);
}
static double elapsed_ms(struct timespec start) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec-start.tv_sec)*1000.0 + (now.tv_nsec-start.tv_nsec)/1000000.0;
}
static int progress(void *context, curl_off_t dt, curl_off_t dn, curl_off_t ut, curl_off_t un) {
    (void)dt; (void)dn;
    RuntimeCurlExchange *x=context;
    if (atomic_load(&x->cancelled)) return 1;
    // No incoming data for the configured read timeout after sending the request.
    long idle_ms=(ut>un && ut>0) ? x->write_ms : x->read_ms;
    if (x->request_started && idle_ms>0 && elapsed_ms(x->last_received)>idle_ms) { x->timed_out=1; return 1; }
    return 0;
}
static int debug(CURL *handle, curl_infotype kind, char *data, size_t length, void *context) {
    (void)handle; (void)data; (void)length;
    RuntimeCurlExchange *x=context;
    // A proxy CONNECT and TLS handshake belong to connect timeout, not the
    // response-read timer. Only the subsequent origin request starts that timer.
    if (kind==CURLINFO_HEADER_OUT) {
        if (length>=8 && !memcmp(data,"CONNECT ",8)) { x->proxy_connecting=1; return 0; }
        x->proxy_connecting=0;
    }
    if (x->proxy_connecting) return 0;
    // Observe activity only; never log request headers, credentials or payloads.
    if (kind == CURLINFO_HEADER_OUT || kind == CURLINFO_DATA_OUT || kind == CURLINFO_HEADER_IN || kind == CURLINFO_DATA_IN) {
        clock_gettime(CLOCK_MONOTONIC, &x->last_received);
        x->request_started=1;
    }
    return 0;
}
static size_t body(char *bytes, size_t size, size_t count, void *context) {
    RuntimeCurlExchange *x=context;
    if (size && count > SIZE_MAX/size) return 0;
    size_t n=size*count, take=n;
    if (take > x->limit-x->length) { take=x->limit-x->length; x->truncated=1; }
    if (x->length+take > x->capacity) {
        size_t capacity=x->capacity ? x->capacity*2 : 4096;
        if (capacity < x->length+take) capacity=x->length+take;
        if (capacity > x->limit) capacity=x->limit;
        uint8_t *p=realloc(x->body,capacity);
        if (!p && capacity) return 0;
        x->body=p; x->capacity=capacity;
    }
    if (take) memcpy(x->body+x->length,bytes,take);
    x->length+=take;
    return x->truncated ? 0 : n;
}
static size_t header(char *bytes, size_t size, size_t count, void *context) {
    RuntimeCurlExchange *x=context;
    if (size && count > SIZE_MAX/size) return 0;
    size_t n=size*count;
    // Ignore interim/redirect bodies and expose only the final response block.
    if (n>=5 && !memcmp(bytes,"HTTP/",5)) { x->headers_length=0; x->length=0; x->truncated=0; }
    if (n>131072-x->headers_length) return 0;
    uint8_t *p=realloc(x->response_headers,x->headers_length+n);
    if (!p && n) return 0;
    x->response_headers=p;
    if (n) memcpy(p+x->headers_length,bytes,n);
    x->headers_length+=n;
    return n;
}
RuntimeCurlExchange *runtime_curl_create(const char *url, const char *proxy, const char *method,
    int verify_tls, long connect_ms, long read_ms, long write_ms, long total_ms, size_t body_limit, RuntimeCurlSession *session) {
    pthread_once(&initialization,initialize);
    RuntimeCurlExchange *x=calloc(1,sizeof(*x));
    if (!x) return NULL;
    atomic_init(&x->cancelled,0); x->limit=body_limit; x->read_ms=read_ms; x->write_ms=write_ms; x->total_ms=total_ms;
    clock_gettime(CLOCK_MONOTONIC, &x->created);
    x->easy=curl_easy_init();
    if (!x->easy) { free(x); return NULL; }
#define SET(option,value) do { if (curl_easy_setopt(x->easy,option,value)!=CURLE_OK) { runtime_curl_free(x); return NULL; } } while(0)
    SET(CURLOPT_URL,url);
    // Explicit empty proxy disables inherited proxy variables. Explicit nonempty
    // proxy never bypasses local destinations via the host's NO_PROXY setting.
    SET(CURLOPT_PROXY,proxy); SET(CURLOPT_NOPROXY,"");
    SET(CURLOPT_SHARE,session->share); SET(CURLOPT_COOKIEFILE,"");
    SET(CURLOPT_PROTOCOLS_STR,"http,https"); SET(CURLOPT_REDIR_PROTOCOLS_STR,"http,https");
    SET(CURLOPT_FOLLOWLOCATION,0L);
    SET(CURLOPT_SSL_VERIFYPEER,verify_tls ? 1L : 0L); SET(CURLOPT_SSL_VERIFYHOST,verify_tls ? 2L : 0L);
    SET(CURLOPT_CONNECTTIMEOUT_MS,connect_ms); SET(CURLOPT_TIMEOUT_MS,total_ms); SET(CURLOPT_NOSIGNAL,1L);
    SET(CURLOPT_ACCEPT_ENCODING,""); SET(CURLOPT_WRITEFUNCTION,body); SET(CURLOPT_WRITEDATA,x);
    SET(CURLOPT_HEADERFUNCTION,header); SET(CURLOPT_HEADERDATA,x);
    SET(CURLOPT_XFERINFOFUNCTION,progress); SET(CURLOPT_XFERINFODATA,x); SET(CURLOPT_NOPROGRESS,0L);
    SET(CURLOPT_DEBUGFUNCTION,debug); SET(CURLOPT_DEBUGDATA,x); SET(CURLOPT_VERBOSE,1L);
    if (!strcmp(method,"POST")) SET(CURLOPT_POST,1L);
    SET(CURLOPT_CUSTOMREQUEST,method);
    if (!strcmp(method,"HEAD")) SET(CURLOPT_NOBODY,1L);
#undef SET
    return x;
}
int runtime_curl_header(RuntimeCurlExchange *x, const char *value) {
    struct curl_slist *p=curl_slist_append(x->headers,value);
    if (!p) return 0;
    x->headers=p;
    return curl_easy_setopt(x->easy,CURLOPT_HTTPHEADER,p)==CURLE_OK;
}
int runtime_curl_body(RuntimeCurlExchange *x, const void *bytes, size_t length) {
    x->request=malloc(length ? length : 1);
    if (!x->request) return 0;
    if (length) memcpy(x->request,bytes,length);
    return curl_easy_setopt(x->easy,CURLOPT_POSTFIELDS,x->request)==CURLE_OK &&
        curl_easy_setopt(x->easy,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)length)==CURLE_OK;
}
int runtime_curl_perform(RuntimeCurlExchange *x) {
    if (atomic_load(&x->cancelled)) return CURLE_ABORTED_BY_CALLBACK;
    long remaining=x->total_ms-(long)elapsed_ms(x->created);
    if (remaining<=0) return CURLE_OPERATION_TIMEDOUT;
    curl_easy_setopt(x->easy,CURLOPT_TIMEOUT_MS,remaining);
    CURLcode code=curl_easy_perform(x->easy);
    curl_easy_getinfo(x->easy,CURLINFO_RESPONSE_CODE,&x->status);
    curl_easy_getinfo(x->easy,CURLINFO_HTTP_CONNECTCODE,&x->proxy_status);
    return x->timed_out ? CURLE_OPERATION_TIMEDOUT : code;
}
int runtime_curl_cancelled(RuntimeCurlExchange *x) { return atomic_load(&x->cancelled); }
void runtime_curl_cancel(RuntimeCurlExchange *x) { atomic_store(&x->cancelled,1); }
void runtime_curl_free(RuntimeCurlExchange *x) {
    if (!x) return;
    if (x->easy) curl_easy_cleanup(x->easy);
    curl_slist_free_all(x->headers); free(x->request); free(x->body); free(x->response_headers); free(x);
}
const char *runtime_curl_error(int code) {
    if (code==CURLE_OPERATION_TIMEDOUT) return "HTTP request timed out";
    return curl_easy_strerror((CURLcode)code);
}
long runtime_curl_status(RuntimeCurlExchange *x) { return x->status; }
long runtime_curl_proxy_status(RuntimeCurlExchange *x) { return x->proxy_status; }
const uint8_t *runtime_curl_response_body(RuntimeCurlExchange *x) { return x->body; }
size_t runtime_curl_response_length(RuntimeCurlExchange *x) { return x->length; }
const uint8_t *runtime_curl_response_headers(RuntimeCurlExchange *x) { return x->response_headers; }
size_t runtime_curl_headers_length(RuntimeCurlExchange *x) { return x->headers_length; }
int runtime_curl_truncated(RuntimeCurlExchange *x) { return x->truncated; }
