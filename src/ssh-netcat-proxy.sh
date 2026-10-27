#!/bin/sh
# ssh ProxyCommand helper.
#
# The egress mode puts the agent on an `internal: true` Docker network: there is
# no route out except the allowlist proxy, and Docker's embedded DNS does not
# forward external names on such a network, so `ssh`/`scp`/`git` cannot resolve
# the host themselves. OpenSSH expands %h and %p *before* running this helper,
# so the name is passed through to the proxy untouched.
#
# Usage (from /etc/ssh/ssh_config.d/90-pi-egress.conf):
#   ProxyCommand /usr/local/bin/ssh-netcat-proxy %h %p
#
# With HTTPS_PROXY set (egress on) the connection is tunnelled through the
# allowlist proxy with `nc -X connect`; otherwise it connects directly, so the
# same image works with EGRESS=false.
set -eu

host="${1:?ssh-netcat-proxy: missing host}"
port="${2:?ssh-netcat-proxy: missing port}"

NC="${PI_NC_BIN:-/usr/bin/nc}"
proxy="${HTTPS_PROXY:-${https_proxy:-}}"

case "$proxy" in
    "")
        exec "$NC" "$host" "$port"
        ;;
    http://*|HTTP://*|http://*)
        exec "$NC" -X connect -x "${proxy#*://}" "$host" "$port"
        ;;
    *)
        exec "$NC" -X connect -x "$proxy" "$host" "$port"
        ;;
esac
