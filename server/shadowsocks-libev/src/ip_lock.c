/*
 * ip_lock.c - Per-port client IP lock with live connection awareness
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef __MINGW32__
#include <netinet/tcp.h>
#endif

#include "ip_lock.h"
#include "utils.h"

typedef struct {
    char ip[INET6_ADDRSTRLEN];
    time_t seen_at;
} ip_lock_recent_entry_t;

static char lock_file_path[512];
static char status_file_path[512];
static char locked_ip[INET6_ADDRSTRLEN];
static ip_lock_recent_entry_t recent_incoming[IP_LOCK_RECENT_MAX];
static int recent_incoming_count = 0;
static ip_lock_recent_entry_t blocked_ips[IP_LOCK_RECENT_MAX];
static int blocked_count = 0;
static time_t lock_file_mtime = 0;
static int ip_lock_enabled     = 0;

static int
ip_lock_ip_in_list(const char *const *ips, int ip_count, const char *ip)
{
    int i;

    if (ip == NULL || ip[0] == '\0' || ips == NULL) {
        return 0;
    }

    for (i = 0; i < ip_count; i++) {
        if (ips[i] != NULL && strcmp(ips[i], ip) == 0) {
            return 1;
        }
    }

    return 0;
}

static void
ip_lock_prune_recent(ip_lock_recent_entry_t *store, int *count, time_t now)
{
    int i;
    int write_idx = 0;

    if (count == NULL || store == NULL) {
        return;
    }

    for (i = 0; i < *count; i++) {
        if (now - store[i].seen_at <= IP_LOCK_RECENT_TTL_SEC) {
            if (write_idx != i) {
                store[write_idx] = store[i];
            }
            write_idx++;
        }
    }

    *count = write_idx;
}

static void
ip_lock_push_recent(ip_lock_recent_entry_t *store, int *count, const char *ip)
{
    int i;
    time_t now = time(NULL);

    if (ip == NULL || ip[0] == '\0' || count == NULL || store == NULL) {
        return;
    }

    ip_lock_prune_recent(store, count, now);

    for (i = 0; i < *count; i++) {
        if (strcmp(store[i].ip, ip) == 0) {
            store[i].seen_at = now;
            if (i > 0) {
                ip_lock_recent_entry_t tmp = store[i];
                memmove(&store[1], &store[0], (size_t)i * sizeof(ip_lock_recent_entry_t));
                store[0] = tmp;
            }
            return;
        }
    }

    if (*count < IP_LOCK_RECENT_MAX) {
        (*count)++;
    } else {
        *count = IP_LOCK_RECENT_MAX;
    }

    memmove(&store[1], &store[0], (size_t)(*count - 1) * sizeof(ip_lock_recent_entry_t));
    strncpy(store[0].ip, ip, INET6_ADDRSTRLEN - 1);
    store[0].ip[INET6_ADDRSTRLEN - 1] = '\0';
    store[0].seen_at = now;
}

static void
ip_lock_reset_recent_lists(void)
{
    recent_incoming_count = 0;
    blocked_count         = 0;
    memset(recent_incoming, 0, sizeof(recent_incoming));
    memset(blocked_ips, 0, sizeof(blocked_ips));
}

void
ip_lock_sidecar_path(char *out, size_t out_size, const char *port, const char *suffix)
{
    snprintf(out, out_size, IP_LOCK_RUNTIME_DIR "/.shadowsocks_%s.%s", port, suffix);
}

void
ip_lock_ensure_runtime_dir(void)
{
    mkdir(IP_LOCK_RUNTIME_DIR, S_IRWXU);
}

void
ip_lock_init(const char *lock_file, const char *status_file)
{
    ip_lock_enabled = 1;
    ip_lock_ensure_runtime_dir();
    if (lock_file != NULL) {
        strncpy(lock_file_path, lock_file, sizeof(lock_file_path) - 1);
        lock_file_path[sizeof(lock_file_path) - 1] = '\0';
    }
    if (status_file != NULL) {
        strncpy(status_file_path, status_file, sizeof(status_file_path) - 1);
        status_file_path[sizeof(status_file_path) - 1] = '\0';
    }
    locked_ip[0] = '\0';
    ip_lock_reset_recent_lists();
    ip_lock_reload();
}

void
ip_lock_reload(void)
{
    char previous_ip[INET6_ADDRSTRLEN];

    if (lock_file_path[0] == '\0') {
        return;
    }

    strncpy(previous_ip, locked_ip, sizeof(previous_ip) - 1);
    previous_ip[sizeof(previous_ip) - 1] = '\0';

    struct stat st;
    if (stat(lock_file_path, &st) != 0) {
        if (locked_ip[0] != '\0') {
            ip_lock_reset_recent_lists();
        }
        locked_ip[0] = '\0';
        lock_file_mtime = 0;
        return;
    }

    if (st.st_mtime == lock_file_mtime) {
        return;
    }

    lock_file_mtime = st.st_mtime;

    FILE *f = fopen(lock_file_path, "r");
    if (f == NULL) {
        locked_ip[0] = '\0';
        return;
    }

    if (fgets(locked_ip, sizeof(locked_ip), f) == NULL) {
        locked_ip[0] = '\0';
    } else {
        size_t len = strlen(locked_ip);
        while (len > 0 && (locked_ip[len - 1] == '\n' || locked_ip[len - 1] == '\r' ||
                           locked_ip[len - 1] == ' ')) {
            locked_ip[--len] = '\0';
        }
    }
    fclose(f);

    if (strcmp(previous_ip, locked_ip) != 0) {
        ip_lock_reset_recent_lists();
    }
}

const char *
ip_lock_get_locked_ip(void)
{
    return locked_ip;
}

void
ip_lock_set(const char *ip)
{
    if (ip == NULL || ip[0] == '\0') {
        return;
    }

    if (locked_ip[0] != '\0' && strcmp(locked_ip, ip) != 0) {
        ip_lock_reset_recent_lists();
    }

    strncpy(locked_ip, ip, sizeof(locked_ip) - 1);
    locked_ip[sizeof(locked_ip) - 1] = '\0';

    if (lock_file_path[0] == '\0') {
        return;
    }

    FILE *f = fopen(lock_file_path, "w");
    if (f == NULL) {
        return;
    }
    fprintf(f, "%s\n", locked_ip);
    fclose(f);

    struct stat st;
    if (stat(lock_file_path, &st) == 0) {
        lock_file_mtime = st.st_mtime;
    }
}

void
ip_lock_clear(void)
{
    locked_ip[0] = '\0';
    lock_file_mtime = 0;
    ip_lock_reset_recent_lists();

    if (lock_file_path[0] != '\0') {
        unlink(lock_file_path);
    }
}

void
ip_lock_record_incoming(const char *ip)
{
    if (!ip_lock_enabled) {
        return;
    }
    ip_lock_push_recent(recent_incoming, &recent_incoming_count, ip);
}

void
ip_lock_record_blocked(const char *ip)
{
    if (!ip_lock_enabled) {
        return;
    }
    ip_lock_push_recent(blocked_ips, &blocked_count, ip);
}

void
ip_lock_format_active_ips(const char *const *ips, int ip_count,
                          char *out, size_t out_size)
{
    int pos = 0;
    int i;

    if (out == NULL || out_size == 0) {
        return;
    }

    if (ips == NULL || ip_count <= 0) {
        snprintf(out, out_size, "[]");
        return;
    }

    pos += snprintf(out + pos, out_size - pos, "[");
    for (i = 0; i < ip_count; i++) {
        int n;
        if (ips[i] == NULL || ips[i][0] == '\0') {
            continue;
        }
        if (pos > 1 && pos < (int)out_size - 1) {
            pos += snprintf(out + pos, out_size - pos, ",");
        }
        if (pos >= (int)out_size - 2) {
            break;
        }
        n = snprintf(out + pos, out_size - pos, "\"%s\"", ips[i]);
        if (n < 0 || pos + n >= (int)out_size - 2) {
            break;
        }
        pos += n;
    }
    snprintf(out + pos, out_size - pos, "]");
}

static void
ip_lock_json_escape(const char *in, char *out, size_t out_size)
{
    size_t pos = 0;

    if (out == NULL || out_size == 0) {
        return;
    }

    if (in == NULL) {
        out[0] = '\0';
        return;
    }

    for (; *in != '\0' && pos + 1 < out_size; in++) {
        if (*in == '"' || *in == '\\') {
            if (pos + 2 >= out_size) {
                break;
            }
            out[pos++] = '\\';
        }
        out[pos++] = *in;
    }
    out[pos] = '\0';
}

void
ip_lock_write_status(int total_conn, const char *const *active_ips, int active_count)
{
    char locked_esc[INET6_ADDRSTRLEN * 2];
    char active_json[IP_LOCK_STATUS_JSON_MAX];
    char incoming_json[IP_LOCK_STATUS_JSON_MAX];
    char blocked_json[IP_LOCK_STATUS_JSON_MAX];
    const char *incoming_ptrs[IP_LOCK_RECENT_MAX];
    const char *blocked_ptrs[IP_LOCK_RECENT_MAX];
    int incoming_filtered = 0;
    int blocked_filtered  = 0;
    time_t now            = time(NULL);
    int i;

    if (status_file_path[0] == '\0') {
        return;
    }

    ip_lock_prune_recent(recent_incoming, &recent_incoming_count, now);
    ip_lock_prune_recent(blocked_ips, &blocked_count, now);

    for (i = 0; i < recent_incoming_count; i++) {
        const char *ip = recent_incoming[i].ip;
        if (ip_lock_ip_in_list(active_ips, active_count, ip)) {
            continue;
        }
        incoming_ptrs[incoming_filtered++] = ip;
    }

    for (i = 0; i < blocked_count; i++) {
        const char *ip = blocked_ips[i].ip;
        if (ip_lock_ip_in_list(active_ips, active_count, ip)) {
            continue;
        }
        blocked_ptrs[blocked_filtered++] = ip;
    }

    ip_lock_format_active_ips(active_ips, active_count, active_json, sizeof(active_json));
    ip_lock_format_active_ips(incoming_ptrs, incoming_filtered,
                              incoming_json, sizeof(incoming_json));
    ip_lock_format_active_ips(blocked_ptrs, blocked_filtered,
                              blocked_json, sizeof(blocked_json));
    ip_lock_json_escape(locked_ip, locked_esc, sizeof(locked_esc));

    FILE *f = fopen(status_file_path, "w");
    if (f == NULL) {
        return;
    }

    fprintf(f,
            "{\"locked_ip\":\"%s\",\"connections\":%d,\"active_ips\":%s,"
            "\"recent_incoming\":%s,\"blocked_ips\":%s}\n",
            locked_esc, total_conn, active_json, incoming_json, blocked_json);
    fclose(f);
}

int
ip_lock_is_enabled(void)
{
    return ip_lock_enabled;
}

void
ip_lock_configure_client_socket(int fd)
{
#ifndef __MINGW32__
    int on = 1;

    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));

    int keepidle  = IP_LOCK_KEEPIDLE_SEC;
    int keepintvl = IP_LOCK_KEEPINTVL_SEC;
    int keepcnt   = IP_LOCK_KEEPCNT;
#ifdef TCP_KEEPIDLE
    setsockopt(fd, SOL_TCP, TCP_KEEPIDLE, &keepidle, sizeof(keepidle));
#endif
#ifdef TCP_KEEPINTVL
    setsockopt(fd, SOL_TCP, TCP_KEEPINTVL, &keepintvl, sizeof(keepintvl));
#endif
#ifdef TCP_KEEPCNT
    setsockopt(fd, SOL_TCP, TCP_KEEPCNT, &keepcnt, sizeof(keepcnt));
#endif
#ifdef TCP_USER_TIMEOUT
    {
        unsigned int user_timeout = IP_LOCK_USER_TIMEOUT_MS;
        setsockopt(fd, SOL_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof(user_timeout));
    }
#endif
#else
    (void)fd;
#endif
}
