#!/bin/sh
#
# mkwebdir.sh - create a web project directory you can work in without root.
#
# Usage:
#   mkwebdir.sh [options] NAME...
#
#   NAME             the project directory: a name under the web root, or an absolute path
#   --root DIR       the web root (default: the first that exists of /var/www/html,
#                    /srv/http, /srv/www/htdocs, /var/www)
#   --web-user USER  the web server's user (default: the first that exists of www-data,
#                    apache, http, wwwrun, nginx)
#   --group GROUP    the group you share with the web server (default: webdev)
#   --fix            NAME already exists: take it over, recursively (owner, group, modes,
#                    ACLs), as the UserSpice fixperms.sh does
#   --no-web-write   the web server may read but not change the files
#   --check          only report what is there and what would change
#   -y, --yes        don't ask before changing anything
#   -h, --help       this text
#
# Derived from the fixperms.sh the UserSpice maintainer uses for UserSpice web
# directories, for any web project. The directory belongs to you (so you can create,
# copy, rename and delete in it at once, without sudo and before any re-login) and to
# the shared group, which the web server is in:
#
#   - directories 2775: the setgid bit makes everything created inside inherit the group;
#   - files 664 (executables keep their x bits);
#   - default ACLs, so files you create there (an editor, touch, git) get group write
#     whatever your umask is (with only setgid, umask 022 would make them 644);
#   - with --no-web-write, 2755 / 644 and read-only default ACLs for the group.
#
# Copies are different: cp gives a copy its source file's mode (ACLs can only take
# permissions away from that), so a 644 file copied in stays 644 - readable by the web
# server, not writable. That's often what you want for code; where the web server must
# write, `chmod -R g+w NAME` fixes it without root (the files are yours), or --fix.
#
# It creates the group and adds you and the web server's user to it if needed, offers
# to install the ACL tools (package `acl`) if they are missing, and restarts the web
# server (systemd) so it picks up the new group.
#
# What fixperms.sh does that this doesn't: it marks *.php files executable (775).
# PHP files are read by the PHP interpreter, never executed, so they stay 664 here.

set -eu

# shellcheck disable=SC1007 # CDPATH= (empty) for this one command, as in _template.sh
SS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

# the header comment, from line 3 up to the first line that isn't a comment
usage() { sed -n '3,/^[^#]/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

ASSUME_YES=0
CHECK=0
FIX=0
WEB_WRITE=1
WEB_ROOT=""
WEB_USER=""
GROUP=webdev
NAMES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root) [ $# -ge 2 ] || die "--root needs a directory"; WEB_ROOT=$2; shift ;;
        --web-user) [ $# -ge 2 ] || die "--web-user needs a user"; WEB_USER=$2; shift ;;
        --group) [ $# -ge 2 ] || die "--group needs a group"; GROUP=$2; shift ;;
        --fix) FIX=1 ;;
        --no-web-write) WEB_WRITE=0 ;;
        --check) CHECK=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *)
            case "$1" in
                *"
"*) die "a directory name with a newline isn't supported" ;;
            esac
            NAMES="$NAMES
$1" ;;
    esac
    shift
done
[ -n "$NAMES" ] || die "name at least one project directory (see --help)"

# --- who and where -------------------------------------------------------------------

ME=$(invoking_user)
[ "$ME" != root ] || die "run this as yourself (it uses sudo or doas for the steps that need root): the directory is to be yours"

if [ -z "$WEB_ROOT" ]; then
    for _d in /var/www/html /srv/http /srv/www/htdocs /var/www; do
        if [ -d "$_d" ]; then WEB_ROOT=$_d; break; fi
    done
    [ -n "$WEB_ROOT" ] || die "no web root found (looked for /var/www/html, /srv/http, /srv/www/htdocs, /var/www); give one with --root"
fi
[ -d "$WEB_ROOT" ] || die "web root $WEB_ROOT doesn't exist"

if [ -z "$WEB_USER" ]; then
    for _u in www-data apache http wwwrun nginx; do
        if id "$_u" >/dev/null 2>&1; then WEB_USER=$_u; break; fi
    done
    [ -n "$WEB_USER" ] || die "no web server user found (looked for www-data, apache, http, wwwrun, nginx); is a web server installed? Give one with --web-user"
fi
id "$WEB_USER" >/dev/null 2>&1 || die "user $WEB_USER doesn't exist"

if [ "$WEB_WRITE" = 1 ]; then
    DIR_MODE=2775; FILE_SET='u+rw,g+rw,o+r,o-w'; ACL_G=rwx
else
    DIR_MODE=2755; FILE_SET='u+rw,g+r,g-w,o+r,o-w'; ACL_G=rx
fi
# Default ACLs: what new files and directories get, in place of the umask. Files are
# created without x, so they get rw (or r) from these.
DEFAULT_ACL="d:u::rwx,d:g::$ACL_G,d:m::rwx,d:o::rx"

# path_of NAME - the directory NAME stands for.
path_of() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$WEB_ROOT" "$1" ;;
    esac
}

web_services() {
    [ "$(init_system)" = systemd ] || return 0
    for _s in apache2 httpd nginx lighttpd caddy php-fpm $(systemctl list-units --type=service --state=active --no-legend 'php*-fpm*' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//'); do
        # by its unit's own name: httpd is an alias of apache2 on some systems
        systemctl is-active --quiet "$_s" 2>/dev/null &&
            systemctl show -p Id --value "$_s" 2>/dev/null | sed 's/\.service$//'
    done | sort -u
}

# --- report --------------------------------------------------------------------------

info "web root: $WEB_ROOT; web server user: $WEB_USER; shared group: $GROUP; you: $ME"
TODO=""
if group_exists "$GROUP"; then
    ok "group $GROUP exists"
else
    warn "group $GROUP doesn't exist: it will be created"
    TODO="$TODO group"
fi
for _u in "$ME" "$WEB_USER"; do
    if group_exists "$GROUP" && user_in_group "$_u" "$GROUP"; then
        ok "$_u is in $GROUP"
    else
        warn "$_u is not in $GROUP: will be added"
        TODO="$TODO member"
    fi
done
if have_cmd setfacl; then
    ok "ACL tools (setfacl) present"
else
    warn "no setfacl: will offer to install the 'acl' package (without it, new files follow your umask)"
fi
SERVICES=$(web_services)
# shellcheck disable=SC2086 # a list of unit names: split on purpose
[ -n "$SERVICES" ] && info "running web server(s): $(printf '%s ' $SERVICES)"

_old_ifs=$IFS
IFS='
'
for _n in $NAMES; do
    [ -n "$_n" ] || continue
    _p=$(path_of "$_n")
    if [ -e "$_p" ]; then
        if [ ! -d "$_p" ]; then
            die "$_p exists and is not a directory"
        fi
        # shellcheck disable=SC2012 # one known path; ls -ld is the portable way to its mode
        _o=$(ls -ld "$_p" | awk '{print $1, $3":"$4}')
        if [ "$FIX" = 1 ]; then
            warn "$_p exists ($_o): will be taken over, recursively"
        else
            die "$_p already exists ($_o); use --fix to take it over"
        fi
    else
        info "will create $_p (owner $ME, group $GROUP, mode $DIR_MODE)"
    fi
done
IFS=$_old_ifs

if [ "$CHECK" = 1 ]; then
    exit 0
fi

# --- change --------------------------------------------------------------------------

confirm "Go ahead?" || die "nothing changed"

case "$TODO" in
    *group*)
        if have_cmd groupadd || [ -x /usr/sbin/groupadd ] || [ -x /sbin/groupadd ]; then
            as_root groupadd "$GROUP"
        elif have_cmd addgroup; then
            as_root addgroup "$GROUP"
        else
            die "no groupadd or addgroup found to create $GROUP"
        fi
        ok "created group $GROUP" ;;
esac
GROUP_CHANGED=0
for _u in "$ME" "$WEB_USER"; do
    if ! user_in_group "$_u" "$GROUP"; then
        add_user_to_group "$_u" "$GROUP" || die "couldn't add $_u to $GROUP"
        ok "added $_u to $GROUP"
        GROUP_CHANGED=1
        [ "$_u" = "$WEB_USER" ] && WEB_GROUP_CHANGED=1
    fi
done

if ! have_cmd setfacl; then
    if [ "$(pkg_manager)" != none ] && confirm "Install the ACL tools (package 'acl')?"; then
        pkg_install acl || warn "couldn't install acl"
    fi
    have_cmd setfacl || warn "going on without ACLs: new files will follow your umask (022 gives 644, which the web server can only read)"
fi

_old_ifs=$IFS
IFS='
'
for _n in $NAMES; do
    [ -n "$_n" ] || continue
    _p=$(path_of "$_n")
    IFS=$_old_ifs
    if [ -d "$_p" ]; then
        as_root chown -R "$ME:$GROUP" "$_p"
        as_root find "$_p" -type d -exec chmod "$DIR_MODE" {} +
        as_root find "$_p" -type f -exec chmod "$FILE_SET" {} +
        if have_cmd setfacl; then
            as_root find "$_p" -type d -exec setfacl -m "$DEFAULT_ACL" {} +
        fi
        ok "took over $_p"
    else
        as_root mkdir -p "$_p"
        as_root chown "$ME:$GROUP" "$_p"
        as_root chmod "$DIR_MODE" "$_p"
        if have_cmd setfacl; then
            as_root setfacl -m "$DEFAULT_ACL" "$_p"
        fi
        ok "created $_p"
    fi

    # Check it: you, without root (owner, so at once), and the web server's user.
    _t="$_p/.mkwebdir-test-$$"
    if mkdir "$_t" && printf 'test\n' >"$_t/file" && cp "$_t/file" "$_t/copy" && rm -r "$_t"; then
        ok "you can create, copy and delete in $_p without root"
    else
        warn "you can't write in $_p - check the directories above it"
    fi
    if [ "$WEB_WRITE" = 1 ]; then
        _f="$_p/.mkwebdir-web-$$"
        if as_root su -s /bin/sh "$WEB_USER" -c "touch '$_f' && rm '$_f'" 2>/dev/null; then
            ok "$WEB_USER can write in $_p"
        else
            warn "$WEB_USER can't write in $_p"
        fi
        if have_cmd setfacl; then
            _g="$_p/.mkwebdir-umask-$$"
            ( umask 022 && : >"$_g" )
            # shellcheck disable=SC2012 # one known file; ls -l is the portable way to its mode
            case $(ls -l "$_g" | cut -c6) in
                w) ok "files you create get group write (whatever your umask)" ;;
                *) warn "files you create don't get group write - the file system may not support ACLs" ;;
            esac
            rm -f "$_g"
        fi
    else
        if as_root su -s /bin/sh "$WEB_USER" -c "test -r '$_p' && test -x '$_p'" 2>/dev/null; then
            ok "$WEB_USER can read $_p"
        else
            warn "$WEB_USER can't read $_p - check the directories above it"
        fi
    fi
    IFS='
'
done
IFS=$_old_ifs

if [ "${WEB_GROUP_CHANGED:-0}" = 1 ] && [ -n "$SERVICES" ]; then
    info "$WEB_USER was added to $GROUP: the web server picks that up when it restarts"
    # shellcheck disable=SC2086 # a list of unit names: split on purpose
    if confirm "Restart $(printf '%s ' $SERVICES)now?"; then
        for _s in $SERVICES; do service_restart "$_s" && ok "restarted $_s"; done
    else
        warn "restart the web server yourself before it writes there"
    fi
elif [ "${WEB_GROUP_CHANGED:-0}" = 1 ]; then
    warn "restart the web server so it picks up its new group $GROUP"
fi
if [ "$WEB_WRITE" = 1 ]; then
    info "files you copy in keep their own mode: where the web server must write them, chmod -R g+w them (no root needed)"
fi
if [ "$GROUP_CHANGED" = 1 ] && ! id -nG | tr ' ' '\n' | grep -qx "$GROUP"; then
    info "you were added to $GROUP: that matters only for files other people own there, and works after you log in again"
fi
