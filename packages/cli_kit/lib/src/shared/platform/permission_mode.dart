String octalPermissionMode(int mode) =>
    (mode & 0xfff).toRadixString(8).padLeft(4, '0');
