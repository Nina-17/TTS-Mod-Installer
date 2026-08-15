# RAR test fixture

`test_read_format_rar.rar.uu` comes from the upstream libarchive test suite:

- <https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar.rar.uu>

The fixture is intentionally uuencoded and contains a symbolic link. The integration test verifies that official 7-Zip 26.02 can inspect and extract the RAR data, then confirms that the installer rejects the extracted link before any copy begins.

libarchive is distributed under the BSD 2-Clause License. See the upstream `COPYING` file:

- <https://github.com/libarchive/libarchive/blob/master/COPYING>
