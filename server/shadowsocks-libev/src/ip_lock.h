/*
 * ip_lock.h - Per-port client IP lock with live connection awareness
 */

#ifndef _IP_LOCK_H
#define _IP_LOCK_H

#include <stddef.h>

#ifndef INET6_ADDRSTRLEN
#define INET6_ADDRSTRLEN 46
#endif

#define IP_LOCK_RUNTIME_DIR "/run/shadowsocks-manager"
#define IP_LOCK_MAX_TRACK_IPS 16
#define IP_LOCK_RECENT_MAX 8
#define IP_LOCK_RECENT_TTL_SEC 30
#define IP_LOCK_STATUS_JSON_MAX 1024
/* Kopuk TCP: keepalive + TCP_USER_TIMEOUT ile ~10 sn (uygulama idle timer yok) */
#define IP_LOCK_KEEPIDLE_SEC 4
#define IP_LOCK_KEEPINTVL_SEC 2
#define IP_LOCK_KEEPCNT 3
#define IP_LOCK_USER_TIMEOUT_MS 10000

void ip_lock_format_active_ips(const char *const *ips, int ip_count,
                               char *out, size_t out_size);

void ip_lock_sidecar_path(char *out, size_t out_size, const char *port, const char *suffix);
void ip_lock_ensure_runtime_dir(void);
int ip_lock_is_enabled(void);
void ip_lock_configure_client_socket(int fd);

void ip_lock_init(const char *lock_file, const char *status_file);
void ip_lock_reload(void);
const char *ip_lock_get_locked_ip(void);
void ip_lock_set(const char *ip);
void ip_lock_clear(void);
void ip_lock_record_incoming(const char *ip);
void ip_lock_record_blocked(const char *ip);
void ip_lock_write_status(int total_conn, const char *const *active_ips, int active_count);

#endif
