#!/usr/bin/env python3
"""Signs an Alpine package again with another RSA key: apk-resign.py PACKAGE PRIVATE_KEY PUBLIC_NAME OUT.

An Alpine package is three gzip streams one after the other: the signature, the control part and
the data. The signature is made over the control stream only, as RSA with SHA-1, and sits in a
tar file named .SIGN.RSA.PUBLIC_NAME, where PUBLIC_NAME is the file name apk looks for in
/etc/apk/keys. This replaces the first stream and leaves the other two as they are, so the
package keeps its content and only its maker changes. The lifecycle test needs it because it
serves the published release from a test repository whose key is not the release key.
Standard library and the openssl program only."""
import gzip
import subprocess
import sys
import tarfile
import zlib


def split_streams(data):
    """Returns the gzip streams of data, each as the bytes it takes up in the file."""
    streams = []
    while data:
        stream = zlib.decompressobj(wbits=31)
        stream.decompress(data)
        if not stream.eof:
            raise ValueError("the file ends inside a gzip stream")
        streams.append(data[: len(data) - len(stream.unused_data)])
        data = stream.unused_data
    return streams


def signature_stream(control, private_key, public_name):
    """Returns the gzip stream that signs control, as abuild writes it: a tar file with its
    end blocks cut off, so that the next stream continues the archive."""
    signed = subprocess.run(
        ["openssl", "dgst", "-sha1", "-sign", private_key],
        input=control, capture_output=True, check=True,
    ).stdout
    entry = tarfile.TarInfo(".SIGN.RSA." + public_name)
    entry.size = len(signed)
    body = entry.tobuf(tarfile.USTAR_FORMAT) + signed + b"\0" * (-len(signed) % 512)
    return gzip.compress(body, mtime=0)


def resign(package, private_key, public_name):
    """Returns the bytes of package signed with private_key."""
    streams = split_streams(package)
    if len(streams) != 3 or b".SIGN.RSA." not in zlib.decompress(streams[0], wbits=31):
        raise ValueError("not a signed Alpine package: expected a signature, control and data stream")
    return signature_stream(streams[1], private_key, public_name) + streams[1] + streams[2]


def main(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    with open(argv[1], "rb") as source:
        signed = resign(source.read(), argv[2], argv[3])
    with open(argv[4], "wb") as target:
        target.write(signed)


if __name__ == "__main__":
    main(sys.argv)
