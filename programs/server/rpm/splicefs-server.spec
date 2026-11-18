# rpmbuild only wraps files here. scripts/package-rpm.sh passes in the package name (pkg_name),
# where the compiled program (stage), the service unit (unit) and the documents (docs) are.
Name:           %{pkg_name}
Version:        %{pkg_version}
Release:        %{pkg_release}
Summary:        Server of the SpliceFS read-only multi-source filesystem
License:        MIT
URL:            https://github.com/SpliceFS/server
# Files, not a package name: the tools come from shadow-utils on Red Hat and from shadow
# on SUSE.
Requires(pre):  /usr/sbin/useradd
Requires(pre):  /usr/sbin/groupadd

# The binary is static and already stripped, and it may be for another CPU type than the
# one building the package, so the usual post-processing has nothing it could do right.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
# gzip is the payload format every rpm version in use can read.
%global _binary_payload w9.gzdio

%description
splicefsd serves local directories over HTTP so that SpliceFS clients can read
each file from every node that holds a copy, at the combined speed of those
nodes. It only reads; it never writes to a shared directory.

%install
install -D -m 755 %{stage}/splicefsd %{buildroot}/usr/bin/splicefsd
install -D -m 755 %{stage}/splicefsdctl %{buildroot}/usr/bin/splicefsdctl
install -D -m 644 %{unit} %{buildroot}/usr/lib/systemd/system/splicefsd.service
install -d %{buildroot}/etc/splicefs/server/conf.d %{buildroot}/etc/splicefs/server/shares.d
install -D -m 644 %{license_file} %{buildroot}/usr/share/doc/%{name}/LICENSE
install -m 644 %{docs} %{buildroot}/usr/share/doc/%{name}/

%files
/usr/bin/splicefsd
/usr/bin/splicefsdctl
/usr/lib/systemd/system/splicefsd.service
%dir /etc/splicefs
%dir /etc/splicefs/server
# Empty on purpose: the administrator's files go here and no package file ever does.
%dir /etc/splicefs/server/conf.d
%dir /etc/splicefs/server/shares.d
/usr/share/doc/%{name}

%pre
# The server runs as its own user so that a bug in it has no more rights than reading
# what that user was given.
getent group splicefs >/dev/null || groupadd -r splicefs
getent passwd splicefs >/dev/null || useradd -r -g splicefs -M -d / -s /sbin/nologin splicefs

%post
@service:after-files@

%preun
# $1 is 0 when the package is removed for good, not replaced by another version.
if [ "$1" -eq 0 ]; then
    @service:before-removal@
fi

%postun
@service:after-removal@
