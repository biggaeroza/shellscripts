#!/bin/sh
#
# install-lamp.sh - install and configure Apache, MariaDB, PHP and
# phpMyAdmin on any Linux distribution. Every user name and password is
# asked for first; then everything is installed and set up in one go with
# nothing more to answer.
#
# Usage:
#   install-lamp.sh [--check] [--yes] [--pma-version VERSION]
#
#   --check                only report what is installed and running
#   --yes                  don't ask for confirmation before installing; the
#                          answers then come from the variables below
#   --pma-version VERSION  install this phpMyAdmin release (default: the
#                          current one from phpmyadmin.net)
#
# Asked for (or set beforehand, e.g. for --yes):
#   LAMP_SERVER_NAME        Apache's ServerName (default: this host's name)
#   LAMP_DB_ROOT_PASSWORD   password for MariaDB's root user
#   LAMP_DB_ADMIN_USER      a MariaDB user with all privileges, for phpMyAdmin
#   LAMP_DB_ADMIN_PASSWORD  that user's password
#   LAMP_PMA_REMOTE         1 = phpMyAdmin reachable from other computers
#                           (default 0: this computer only)
#   LAMP_OPEN_FIREWALL      1 = open HTTP (port 80) in firewalld or ufw
#
# phpMyAdmin comes from phpmyadmin.net (SHA-256 checked) into /opt/phpmyadmin,
# at http://SERVER/phpmyadmin/. MariaDB's root keeps logging in through
# `sudo mariadb` too; phpMyAdmin refuses root - log in there with the admin
# user. The anonymous users and the test database are removed, as
# mariadb-secure-installation would.
#
# Package managers: apt, dnf/yum, zypper, pacman, apk.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; }

CHECK_ONLY=0
ASSUME_YES=0
PMA_VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --pma-version) [ $# -ge 2 ] || die "--pma-version needs a version"; PMA_VERSION=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

PM=$(pkg_manager)
INIT=$(init_system)
PMA_DIR=/opt/phpmyadmin
PMA_TMP=/var/lib/phpmyadmin/tmp
PMA_CONTROL_USER=pma
CONF_NAME=lamp-setup

TMPDIR_LAMP=""
cleanup() {
    stty echo 2>/dev/null || true
    [ -n "$TMPDIR_LAMP" ] && rm -r "$TMPDIR_LAMP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- what differs between distributions --------------------------------------
# WEB_SVC/DB_SVC: service names. WEB_USER: who Apache (or PHP-FPM) runs as.
# CONF_DIR: where an extra Apache .conf goes. PHP_FPM: PHP runs as a
# separate PHP-FPM service rather than inside Apache (mod_php).

PHP_FPM=""
case "$PM" in
    apt)
        WEB_SVC=apache2; DB_SVC=mariadb; WEB_USER=www-data
        CONF_DIR=/etc/apache2/conf-available
        ;;
    dnf|yum)
        WEB_SVC=httpd; DB_SVC=mariadb; WEB_USER=apache
        CONF_DIR=/etc/httpd/conf.d; PHP_FPM=php-fpm
        ;;
    zypper)
        WEB_SVC=apache2; DB_SVC=mariadb; WEB_USER=wwwrun
        CONF_DIR=/etc/apache2/conf.d
        ;;
    pacman)
        WEB_SVC=httpd; DB_SVC=mariadb; WEB_USER=http
        CONF_DIR=/etc/httpd/conf/extra
        ;;
    apk)
        WEB_SVC=apache2; DB_SVC=mariadb; WEB_USER=apache
        CONF_DIR=/etc/apache2/conf.d
        ;;
    *)
        die "unsupported package manager ($PM); supported: apt, dnf/yum, zypper, pacman, apk"
        ;;
esac

# Alpine names PHP packages by version (php84-...): pick the newest offered.
APK_PHP=""
apk_php() {
    if [ -z "$APK_PHP" ]; then
        for _v in 85 84 83 82 81; do
            if apk search -x "php$_v-apache2" 2>/dev/null | grep -q .; then APK_PHP=php$_v; break; fi
        done
        if [ -z "$APK_PHP" ] && [ "${_apk_updated:-0}" = 0 ]; then
            _apk_updated=1; as_root apk update >/dev/null; APK_PHP=""; apk_php; return
        fi
        [ -n "$APK_PHP" ] || die "no phpNN-apache2 package found in the Alpine repositories"
    fi
    echo "$APK_PHP"
}

packages() {
    case "$PM" in
        apt) echo "apache2 mariadb-server mariadb-client php libapache2-mod-php php-mysql php-mbstring php-zip php-gd php-xml php-curl php-intl php-bz2 curl xz-utils tar ca-certificates" ;;
        dnf|yum) echo "httpd mariadb-server mariadb php php-fpm php-mysqlnd php-mbstring php-gd php-xml php-intl php-pecl-zip php-sodium curl xz tar" ;;
        zypper) echo "apache2 mariadb mariadb-client php8 apache2-mod_php8 php8-mysql php8-mbstring php8-zip php8-gd php8-dom php8-xmlreader php8-xmlwriter php8-intl php8-curl php8-openssl php8-ctype php8-iconv php8-sodium php8-bz2 curl xz tar" ;;
        pacman) echo "apache mariadb php php-apache php-gd php-intl curl xz tar" ;;
        apk) _p=$(apk_php); echo "apache2 mariadb mariadb-client $_p $_p-apache2 $_p-mysqli $_p-mbstring $_p-zip $_p-gd $_p-xml $_p-dom $_p-intl $_p-curl $_p-session $_p-ctype $_p-iconv $_p-openssl $_p-sodium $_p-bz2 curl xz tar" ;;
    esac
}

db_client() { if have_cmd mariadb; then echo mariadb; else echo mysql; fi; }

# Run SQL from stdin as MariaDB's root, authenticated as the OS root user.
sql_root() { as_root "$(db_client)" "$@"; }

# A value as a single-quoted SQL string.
sql_str() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g")"; }

apachectl_cmd() {
    for _c in apache2ctl apachectl; do
        if have_cmd "$_c" || [ -x "/usr/sbin/$_c" ]; then echo "$_c"; return 0; fi
    done
    echo ""
}

firewall_kind() {
    if have_cmd firewall-cmd && as_root firewall-cmd --state >/dev/null 2>&1; then echo firewalld
    elif have_cmd ufw && as_root ufw status 2>/dev/null | grep -q 'Status: active'; then echo ufw
    else echo none; fi
}

# --- --check ----------------------------------------------------------------------

service_active() {
    case "$INIT" in
        systemd) systemctl is-active --quiet "$1" ;;
        openrc)  rc-service "$1" status >/dev/null 2>&1 ;;
        runit)   sv status "$1" 2>/dev/null | grep -q '^run:' ;;
        *)       return 1 ;;
    esac
}

if [ "$CHECK_ONLY" = 1 ]; then
    info "LAMP stack - distro: $(os_id) (like: $(os_like)), package manager: $PM, init: $INIT"
    _bad=0
    for _s in "$WEB_SVC" "$DB_SVC" $PHP_FPM; do
        if service_active "$_s"; then ok "$_s running"; else warn "$_s not running"; _bad=1; fi
    done
    if have_cmd php; then ok "php $(php -r 'echo PHP_VERSION;')"; else warn "php not installed"; _bad=1; fi
    if [ -f "$PMA_DIR/config.inc.php" ]; then
        ok "phpMyAdmin $(sed -n "s/.*VERSION = '\([^']*\)'.*/\1/p" "$PMA_DIR/libraries/classes/Version.php" 2>/dev/null | head -1) in $PMA_DIR"
    else
        warn "phpMyAdmin not set up in $PMA_DIR"; _bad=1
    fi
    if have_cmd curl; then
        _code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/phpmyadmin/ || true)
        if [ "$_code" = 200 ]; then ok "http://localhost/phpmyadmin/ answers"; else warn "http://localhost/phpmyadmin/ gives HTTP $_code"; _bad=1; fi
    fi
    exit "$_bad"
fi

# --- questions: everything is asked before anything is installed -------------------

ask() { # PROMPT DEFAULT -> answer on stdout
    if [ -n "$2" ]; then printf '%s [%s]: ' "$1" "$2" >&2; else printf '%s: ' "$1" >&2; fi
    IFS= read -r _a || die "no answer (end of input)"
    [ -n "$_a" ] || _a=$2
    printf '%s\n' "$_a"
}

ask_secret() { # PROMPT -> password on stdout, asked twice
    while :; do
        printf '%s: ' "$1" >&2
        stty -echo 2>/dev/null || true
        IFS= read -r _p1 || { stty echo 2>/dev/null; die "no answer (end of input)"; }
        printf '\n%s (again): ' "$1" >&2
        IFS= read -r _p2 || { stty echo 2>/dev/null; die "no answer (end of input)"; }
        stty echo 2>/dev/null || true
        printf '\n' >&2
        if [ "$_p1" != "$_p2" ]; then warn "the two didn't match; try again"
        elif [ "${#_p1}" -lt 8 ]; then warn "use at least 8 characters"
        else printf '%s\n' "$_p1"; return 0; fi
    done
}

ask_yn() { # PROMPT DEFAULT(0|1) -> 0/1 on stdout
    if [ "$2" = 1 ]; then _d=Y/n; else _d=y/N; fi
    printf '%s [%s] ' "$1" "$_d" >&2
    IFS= read -r _a || die "no answer (end of input)"
    case "$_a" in [yY]|[yY][eE][sS]) echo 1 ;; [nN]|[nN][oO]) echo 0 ;; *) echo "$2" ;; esac
}

valid_user() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_]{1,32}$'; }

need_answer() { # VAR-NAME: with --yes, a missing value can't be asked for
    [ "$ASSUME_YES" = 1 ] && die "--yes needs $1 to be set (see --help)"
    return 0
}

info "LAMP stack - distro: $(os_id) (like: $(os_like)), package manager: $PM, init: $INIT"
info ""
info "First the names and passwords; nothing is installed until you confirm."
info ""

SERVER_NAME=${LAMP_SERVER_NAME:-}
if [ -z "$SERVER_NAME" ]; then
    if [ "$ASSUME_YES" = 1 ]; then SERVER_NAME=$(uname -n)
    else SERVER_NAME=$(ask "Apache server name" "$(uname -n)"); fi
fi

DB_ROOT_PW=${LAMP_DB_ROOT_PASSWORD:-}
[ -n "$DB_ROOT_PW" ] || { need_answer LAMP_DB_ROOT_PASSWORD; DB_ROOT_PW=$(ask_secret "MariaDB root password"); }
[ "${#DB_ROOT_PW}" -ge 8 ] || die "the MariaDB root password needs at least 8 characters"

DB_ADMIN_USER=${LAMP_DB_ADMIN_USER:-}
while [ -z "$DB_ADMIN_USER" ]; do
    need_answer LAMP_DB_ADMIN_USER
    DB_ADMIN_USER=$(ask "MariaDB admin user name (for phpMyAdmin; all privileges)" dbadmin)
    if ! valid_user "$DB_ADMIN_USER" || [ "$DB_ADMIN_USER" = root ] || [ "$DB_ADMIN_USER" = "$PMA_CONTROL_USER" ]; then
        warn "use letters, digits and _ (at most 32), and not root or $PMA_CONTROL_USER"; DB_ADMIN_USER=""
    fi
done
valid_user "$DB_ADMIN_USER" && [ "$DB_ADMIN_USER" != root ] && [ "$DB_ADMIN_USER" != "$PMA_CONTROL_USER" ] \
    || die "invalid admin user name: $DB_ADMIN_USER"

DB_ADMIN_PW=${LAMP_DB_ADMIN_PASSWORD:-}
[ -n "$DB_ADMIN_PW" ] || { need_answer LAMP_DB_ADMIN_PASSWORD; DB_ADMIN_PW=$(ask_secret "Password for $DB_ADMIN_USER"); }
[ "${#DB_ADMIN_PW}" -ge 8 ] || die "the admin password needs at least 8 characters"

PMA_REMOTE=${LAMP_PMA_REMOTE:-}
if [ -z "$PMA_REMOTE" ]; then
    if [ "$ASSUME_YES" = 1 ]; then PMA_REMOTE=0
    else PMA_REMOTE=$(ask_yn "Allow phpMyAdmin from other computers (not only this one)?" 0); fi
fi

FIREWALL=$(firewall_kind)
OPEN_FW=${LAMP_OPEN_FIREWALL:-}
if [ "$FIREWALL" = none ]; then
    OPEN_FW=0
elif [ -z "$OPEN_FW" ]; then
    if [ "$ASSUME_YES" = 1 ]; then OPEN_FW=0
    else OPEN_FW=$(ask_yn "$FIREWALL is active: open HTTP (port 80) so other computers can reach Apache?" 0); fi
fi

PKG_LIST=$(packages)

info ""
info "Planned:"
info "  install with $PM (as root): $PKG_LIST"
info "  Apache: ServerName $SERVER_NAME, PHP, phpMyAdmin at http://$SERVER_NAME/phpmyadmin/"
info "  MariaDB: root password set (sudo mariadb keeps working), anonymous users and test database removed"
info "  MariaDB user $DB_ADMIN_USER@localhost with all privileges"
info "  phpMyAdmin ${PMA_VERSION:-latest} from phpmyadmin.net into $PMA_DIR, reachable from $( [ "$PMA_REMOTE" = 1 ] && echo 'any computer' || echo 'this computer only' )"
info "  its control user $PMA_CONTROL_USER@localhost and configuration storage database phpmyadmin (random password)"
[ "$OPEN_FW" = 1 ] && info "  $FIREWALL: open HTTP (port 80)"
info "  enable and start: $WEB_SVC $DB_SVC $PHP_FPM"
info ""
confirm "Go ahead?" || { info "Nothing changed."; exit 1; }
TMPDIR_LAMP=$(mktemp -d)

# --- packages ---------------------------------------------------------------------------

info ""; info "== Installing packages"
case "$PM" in
    apt) as_root apt-get update
         # shellcheck disable=SC2086
         as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y $PKG_LIST ;;
    apk) as_root apk update
         # shellcheck disable=SC2086
         pkg_install $PKG_LIST ;;
    *)   # shellcheck disable=SC2086
         pkg_install $PKG_LIST ;;
esac
WEB_GROUP=$(id -gn "$WEB_USER") || die "the web server user $WEB_USER doesn't exist after installing"

# --- MariaDB ------------------------------------------------------------------------------

info ""; info "== MariaDB"
# Debian/Ubuntu, Fedora and openSUSE create MariaDB's system tables
# themselves (on install or first start). Arch and Alpine leave the data
# directory empty: there, and only if the server doesn't come up as
# installed, create them. Never run this over a working server - under
# Ubuntu's AppArmor profile it can't even read the directory.
db_up() { sql_root -e 'SELECT 1' >/dev/null 2>&1; }
db_wait() { # SECONDS
    _t=0
    until db_up; do
        _t=$((_t + 1)); [ "$_t" -lt "$1" ] || return 1
        sleep 1
    done
}
if ! db_up; then
    service_enable "$DB_SVC" || true
    if ! db_wait 20; then
        case "$PM" in
            pacman|apk)
                if as_root test -d /var/lib/mysql/mysql; then
                    die "MariaDB doesn't start, but its data directory is already set up; see its log"
                fi
                if have_cmd mariadb-install-db || [ -x /usr/bin/mariadb-install-db ]; then
                    as_root mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null
                else
                    as_root mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null
                fi
                ok "data directory initialised"
                service_restart "$DB_SVC"
                db_wait 30 || die "MariaDB didn't come up after initialising it"
                ;;
            *)
                die "MariaDB didn't come up; see its log (journalctl -u $DB_SVC)"
                ;;
        esac
    fi
fi
service_enable "$DB_SVC"
ok "MariaDB is running"

sql_root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD($(sql_str "$DB_ROOT_PW"));
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
CREATE USER IF NOT EXISTS '$DB_ADMIN_USER'@'localhost' IDENTIFIED BY $(sql_str "$DB_ADMIN_PW");
ALTER USER '$DB_ADMIN_USER'@'localhost' IDENTIFIED BY $(sql_str "$DB_ADMIN_PW");
GRANT ALL PRIVILEGES ON *.* TO '$DB_ADMIN_USER'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
ok "root password set, test database and anonymous users removed, $DB_ADMIN_USER created"
DB_SOCKET=$(sql_root -N -B -e 'SELECT @@socket')

# --- PHP and Apache -------------------------------------------------------------------------

info ""; info "== PHP and Apache"
if [ "$PM" = pacman ]; then
    # Arch: mod_php needs the prefork MPM, and PHP's MySQL and other
    # extensions are off until php.ini enables them.
    _conf=/etc/httpd/conf/httpd.conf
    sed -e 's|^LoadModule mpm_event_module|#LoadModule mpm_event_module|' \
        -e 's|^#LoadModule mpm_prefork_module|LoadModule mpm_prefork_module|' \
        "$_conf" > "$TMPDIR_LAMP/httpd.conf"
    for _line in 'LoadModule php_module modules/libphp.so' 'AddHandler php-script .php' \
                 'Include conf/extra/php_module.conf' "Include conf/extra/$CONF_NAME.conf"; do
        grep -qxF "$_line" "$TMPDIR_LAMP/httpd.conf" || printf '%s\n' "$_line" >> "$TMPDIR_LAMP/httpd.conf"
    done
    root_write "$_conf" < "$TMPDIR_LAMP/httpd.conf"
    cp /etc/php/php.ini "$TMPDIR_LAMP/php.ini"
    for _ext in mysqli pdo_mysql iconv gd intl zip bz2 sodium; do
        sed -e "s/^;extension=$_ext\$/extension=$_ext/" "$TMPDIR_LAMP/php.ini" > "$TMPDIR_LAMP/php.ini.new"
        mv "$TMPDIR_LAMP/php.ini.new" "$TMPDIR_LAMP/php.ini"
    done
    root_write /etc/php/php.ini < "$TMPDIR_LAMP/php.ini"
    ok "httpd.conf: prefork MPM and mod_php; php.ini: mysqli, gd, intl, zip and others enabled"
fi
[ "$PM" = zypper ] && { as_root a2enmod php8 >/dev/null 2>&1 || true; }

# --- phpMyAdmin ----------------------------------------------------------------------------------

info ""; info "== phpMyAdmin"
if [ -z "$PMA_VERSION" ]; then
    PMA_VERSION=$(curl -fsSL https://www.phpmyadmin.net/home_page/version.txt | head -1) \
        || die "couldn't get the current phpMyAdmin version (pass --pma-version)"
fi
_file=phpMyAdmin-$PMA_VERSION-all-languages
_url=https://files.phpmyadmin.net/phpMyAdmin/$PMA_VERSION/$_file.tar.xz
info "Downloading phpMyAdmin $PMA_VERSION ..."
curl -fsSL --proto '=https' -o "$TMPDIR_LAMP/$_file.tar.xz" "$_url" || die "download failed: $_url"
_want=$(curl -fsSL "$_url.sha256" | cut -d' ' -f1) || die "couldn't get the checksum: $_url.sha256"
_have=$(if have_cmd sha256sum; then sha256sum "$TMPDIR_LAMP/$_file.tar.xz"; else shasum -a 256 "$TMPDIR_LAMP/$_file.tar.xz"; fi | cut -d' ' -f1)
[ -n "$_want" ] && [ "$_have" = "$_want" ] || die "phpMyAdmin's SHA-256 doesn't match; nothing installed"
tar -xJf "$TMPDIR_LAMP/$_file.tar.xz" -C "$TMPDIR_LAMP"

if [ -e "$PMA_DIR" ]; then
    _old=$PMA_DIR.old-$(date +%Y%m%d%H%M%S)
    as_root mv "$PMA_DIR" "$_old"
    info "previous $PMA_DIR kept as $_old"
fi
as_root mkdir -p "$(dirname "$PMA_DIR")"
as_root cp -R "$TMPDIR_LAMP/$_file" "$PMA_DIR"
as_root chown -R root:root "$PMA_DIR"
as_root mkdir -p "$PMA_TMP"
as_root chown "$WEB_USER:$WEB_GROUP" "$PMA_TMP"
as_root chmod 750 "$PMA_TMP"

# Configuration storage (bookmarks, history, designer...): its database and
# a control user that may only use it.
PMA_CONTROL_PW=$(random_string 32)
sql_root < "$PMA_DIR/sql/create_tables.sql"
sql_root <<EOF
CREATE USER IF NOT EXISTS '$PMA_CONTROL_USER'@'localhost' IDENTIFIED BY '$PMA_CONTROL_PW';
ALTER USER '$PMA_CONTROL_USER'@'localhost' IDENTIFIED BY '$PMA_CONTROL_PW';
GRANT SELECT, INSERT, UPDATE, DELETE ON phpmyadmin.* TO '$PMA_CONTROL_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# config.inc.php holds the control user's password: readable by the web
# server's group only, and created with that mode before anything is in it.
as_root install -m 640 -o root -g "$WEB_GROUP" /dev/null "$PMA_DIR/config.inc.php"
root_write "$PMA_DIR/config.inc.php" <<EOF
<?php
// Written by install-lamp.sh. Settings: https://docs.phpmyadmin.net/en/latest/config.html
declare(strict_types=1);

\$cfg['blowfish_secret'] = '$(random_string 32)';

\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['socket'] = '$DB_SOCKET';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = false;

\$cfg['Servers'][\$i]['controluser'] = '$PMA_CONTROL_USER';
\$cfg['Servers'][\$i]['controlpass'] = '$PMA_CONTROL_PW';
\$cfg['Servers'][\$i]['pmadb'] = 'phpmyadmin';
\$cfg['Servers'][\$i]['bookmarktable'] = 'pma__bookmark';
\$cfg['Servers'][\$i]['relation'] = 'pma__relation';
\$cfg['Servers'][\$i]['table_info'] = 'pma__table_info';
\$cfg['Servers'][\$i]['table_coords'] = 'pma__table_coords';
\$cfg['Servers'][\$i]['pdf_pages'] = 'pma__pdf_pages';
\$cfg['Servers'][\$i]['column_info'] = 'pma__column_info';
\$cfg['Servers'][\$i]['history'] = 'pma__history';
\$cfg['Servers'][\$i]['table_uiprefs'] = 'pma__table_uiprefs';
\$cfg['Servers'][\$i]['tracking'] = 'pma__tracking';
\$cfg['Servers'][\$i]['userconfig'] = 'pma__userconfig';
\$cfg['Servers'][\$i]['recent'] = 'pma__recent';
\$cfg['Servers'][\$i]['favorite'] = 'pma__favorite';
\$cfg['Servers'][\$i]['users'] = 'pma__users';
\$cfg['Servers'][\$i]['usergroups'] = 'pma__usergroups';
\$cfg['Servers'][\$i]['navigationhiding'] = 'pma__navigationhiding';
\$cfg['Servers'][\$i]['savedsearches'] = 'pma__savedsearches';
\$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
\$cfg['Servers'][\$i]['designer_settings'] = 'pma__designer_settings';
\$cfg['Servers'][\$i]['export_templates'] = 'pma__export_templates';

\$cfg['TempDir'] = '$PMA_TMP';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
EOF
ok "phpMyAdmin $PMA_VERSION in $PMA_DIR"

# SELinux (Fedora, RHEL): let Apache read phpMyAdmin and write its temp dir.
if have_cmd getenforce && [ "$(getenforce 2>/dev/null)" != Disabled ]; then
    if have_cmd semanage; then
        as_root semanage fcontext -a -t httpd_sys_content_t "$PMA_DIR(/.*)?" 2>/dev/null || true
        as_root semanage fcontext -a -t httpd_sys_rw_content_t "$PMA_TMP(/.*)?" 2>/dev/null || true
        as_root restorecon -R "$PMA_DIR" "$PMA_TMP"
    else
        as_root chcon -R -t httpd_sys_content_t "$PMA_DIR"
        as_root chcon -R -t httpd_sys_rw_content_t "$PMA_TMP"
    fi
    ok "SELinux labels set"
fi

# --- Apache configuration ------------------------------------------------------------------------

if [ "$PMA_REMOTE" = 1 ]; then PMA_ACCESS='Require all granted'; else PMA_ACCESS='Require local'; fi
as_root mkdir -p "$CONF_DIR"
root_write "$CONF_DIR/$CONF_NAME.conf" <<EOF
# Written by install-lamp.sh.
ServerName $SERVER_NAME

Alias /phpmyadmin $PMA_DIR
<Directory $PMA_DIR>
    Options FollowSymLinks
    DirectoryIndex index.php
    AllowOverride None
    $PMA_ACCESS
</Directory>
# phpMyAdmin's own code and setup pages are never served directly.
<DirectoryMatch "^$PMA_DIR/(libraries|templates|setup|sql|vendor|tmp)/">
    Require all denied
</DirectoryMatch>
EOF
[ "$PM" = apt ] && as_root a2enconf "$CONF_NAME" >/dev/null

_ctl=$(apachectl_cmd)
if [ -n "$_ctl" ]; then
    _out=$(as_root "$_ctl" -t 2>&1) || { printf '%s\n' "$_out" >&2; die "Apache's configuration test failed"; }
fi

[ -n "$PHP_FPM" ] && service_enable "$PHP_FPM" && service_restart "$PHP_FPM"
service_enable "$WEB_SVC"
service_restart "$WEB_SVC"

# --- firewall ---------------------------------------------------------------------------------------

if [ "$OPEN_FW" = 1 ]; then
    case "$FIREWALL" in
        firewalld) as_root firewall-cmd --permanent --add-service=http >/dev/null && as_root firewall-cmd --reload >/dev/null ;;
        ufw) as_root ufw allow 80/tcp >/dev/null ;;
    esac
    ok "$FIREWALL: HTTP (port 80) open"
fi

# --- checks ---------------------------------------------------------------------------------------------

info ""; info "== Checking"
FAILED=0
if MYSQL_PWD=$DB_ADMIN_PW "$(db_client)" -u "$DB_ADMIN_USER" -N -B -e 'SELECT 1' >/dev/null 2>&1; then
    ok "$DB_ADMIN_USER can log in to MariaDB with its password"
else
    warn "$DB_ADMIN_USER can't log in to MariaDB"; FAILED=1
fi
if MYSQL_PWD=$DB_ROOT_PW "$(db_client)" -u root -N -B -e 'SELECT 1' >/dev/null 2>&1; then
    ok "root can log in to MariaDB with its password"
else
    warn "root can't log in to MariaDB with its password"; FAILED=1
fi
sleep 1
_code=$(curl -s -o "$TMPDIR_LAMP/page" -w '%{http_code}' http://localhost/phpmyadmin/ || true)
if [ "$_code" = 200 ] && grep -q 'phpMyAdmin' "$TMPDIR_LAMP/page"; then
    ok "http://localhost/phpmyadmin/ shows phpMyAdmin's login page"
else
    warn "http://localhost/phpmyadmin/ gives HTTP $_code"; FAILED=1
fi

info ""
if [ "$FAILED" = 1 ]; then warn "installed, but some checks failed (see above)"; exit 1; fi
ok "done"
info "phpMyAdmin: http://$SERVER_NAME/phpmyadmin/ (log in as $DB_ADMIN_USER)"
info "Web root:   Apache's default document root for this distribution"
info "MariaDB:    sudo mariadb, or mariadb -u $DB_ADMIN_USER -p"
