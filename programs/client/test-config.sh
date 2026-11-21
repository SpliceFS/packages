# shellcheck shell=sh
# The test configuration of the client: it mounts the share of the server in the same system and
# trusts that server by the cluster key, the way a person would. Written the way docs/configuration.md
# of the client says (a cluster is a file in clusters.d, a mount is a file in mounts.d, the password is
# a file the cluster names), and checked where the documentation says it is. The cluster key is the one
# splicefsdctl cluster init makes on the server and splicefsdctl cluster show prints. Sourced inside a
# system the packages are installed in (scripts/package-test-steps.sh, through scripts/system-state-lib.sh),
# after scripts/package-lib.sh, which says where the configuration and the data are (confdir, datadir).
# The functions read those variables when they run, so a test can move them. The address of the system,
# which the adapter of the package format knows, is in OWN_ADDRESS.
# shellcheck disable=SC2154
# shellcheck source=../../scripts/test-config-lib.sh
. scripts/test-config-lib.sh

cluster_name="test"
# The one file name the test writes in clusters.d and in mounts.d, which the file checks of the package
# leave out: a cluster and a mount share a name, as the documentation's examples do.
test_config_file=$cluster_name.yaml

# The files of the test configuration, from the folders as they are when a function runs. The password is in
# the state folder, which holds what the administrator adds to it, so that the configuration folder holds
# nothing but its own folders.
set_paths() {
    cluster_conf="$confdir/clusters.d/$test_config_file"
    mount_conf="$confdir/mounts.d/$test_config_file"
    password_path="$datadir/password"
}

# Prints the cluster key of the server: the key line of splicefsdctl cluster show without its name.
# splicefsdctl cluster init makes the key first, as a person does once on one server.
make_cluster_key() {
    splicefsdctl cluster init >/dev/null || fail "splicefsdctl cluster init failed"
    key_line="$(splicefsdctl cluster show)" || fail "splicefsdctl cluster show failed"
    case "$key_line" in
        "cluster_key: "?*) echo "${key_line#cluster_key: }" ;;
        *) fail "splicefsdctl cluster show printed '$key_line', not a cluster_key line" ;;
    esac
}

# Writes the cluster, the mount, the password and the folder it mounts at. The cluster is the server of this
# system, by its address, trusted by the cluster key.
write_test_config() {
    : "${OWN_ADDRESS:?OWN_ADDRESS is not set: the system has no address of its own}"
    set_paths
    key="$(make_cluster_key)" || exit 1
    make_test_folder "$mount_target"
    make_test_folder "$datadir"
    (umask 077 && printf '%s\n' "$user_password" >"$password_path")
    printf 'url: https://%s:%s%s\nuser: %s\npassword_file: %s\ncluster_key: %s\n' \
        "$OWN_ADDRESS" "$server_port" "$server_api_path" "$user_name" "$password_path" "$key" >"$cluster_conf"
    printf 'cluster: %s\npath: /%s\ntarget: %s\n' "$cluster_name" "$share_name" "$mount_target" >"$mount_conf"
}

# The files are where the documentation says they are, with what the documentation says they hold, and the
# client's own check of its configuration accepts them.
check_test_config() {
    set_paths
    [ -f "$cluster_conf" ] || fail "$cluster_conf is missing"
    [ -f "$mount_conf" ] || fail "$mount_conf is missing"
    [ -f "$password_path" ] || fail "$password_path is missing"
    grep -q '^cluster_key: ..' "$cluster_conf" || fail "$cluster_conf holds no cluster_key"
    grep -qxF "user: $user_name" "$cluster_conf" || fail "$cluster_conf does not name the user $user_name"
    grep -qxF "target: $mount_target" "$mount_conf" || fail "$mount_conf does not name the folder $mount_target"
    [ -d "$mount_target" ] || fail "$mount_target is missing"
    splicefs config check >/dev/null || fail "splicefs config check does not accept the test configuration"
}

# The cluster key of the written configuration.
configured_cluster_key() {
    set_paths
    sed -n 's/^cluster_key: //p' "$cluster_conf"
}

# Whether the system can ask the server which certificate it serves: the TLS tool of the systems that have it.
can_ask_served_certificate() {
    command -v openssl >/dev/null 2>&1
}

# Writes the files of the certificate that the server of the cluster serves, which the client checks with
# its cluster key: the part the key signed, and the signature. The server serves a certificate whose
# issuer has no certificate of its own, so the signature is checked with the key alone, the way the client
# does. Usage: take_served_certificate FOLDER. Files: tbs.der and sig.bin.
take_served_certificate() {
    openssl s_client -connect "$OWN_ADDRESS:$server_port" </dev/null 2>/dev/null | openssl x509 >"$1/leaf.pem" || return 1
    parsed="$(openssl asn1parse -in "$1/leaf.pem")" || return 1
    # The part the issuer signed is the first thing inside the certificate; the signature is the last
    # thing in it, a bit string at the same depth.
    tbs_offset="$(printf '%s\n' "$parsed" | awk -F: 'NR == 2 { print $1 + 0 }')"
    sig_offset="$(printf '%s\n' "$parsed" | awk -F: '$2 ~ /^d=1 / && /BIT STRING/ { print $1 + 0 }')"
    [ -n "$tbs_offset" ] && [ -n "$sig_offset" ] || return 1
    openssl asn1parse -in "$1/leaf.pem" -noout -strparse "$tbs_offset" -out "$1/tbs.der" &&
        openssl asn1parse -in "$1/leaf.pem" -noout -strparse "$sig_offset" -out "$1/sig.bin"
}

# Status 0 when the certificate the server serves is signed by the cluster key of the configuration: the
# answer to "can the client trust it". The public key is the 32 bytes of the key, wrapped in the header of
# an Ed25519 public key, which is the form the TLS tool reads.
served_certificate_is_signed_by_cluster_key() {
    verify_dir="$(mktemp -d)" || return 1
    key_text="$(configured_cluster_key)"
    if take_served_certificate "$verify_dir" &&
        { printf '\060\052\060\005\006\003\053\145\160\003\041\000'
            printf '%s' "$key_text" | openssl base64 -d -A; } >"$verify_dir/pub.der" &&
        openssl pkeyutl -verify -pubin -inkey "$verify_dir/pub.der" -keyform DER -rawin \
            -in "$verify_dir/tbs.der" -sigfile "$verify_dir/sig.bin" >/dev/null 2>&1; then
        rm -rf "$verify_dir"
        return 0
    fi
    rm -rf "$verify_dir"
    return 1
}

# What the test made outside the folders the documented removal deletes: the folder it mounts at, the state
# folder it made for the password, and the folders above them that were not there before the test.
remove_test_data() {
    remove_made_folders
}
