{ lib, stdenv, fetchurl, fetchpatch
, bzip2
, expat
, libffi
, gdbm
, xz
, mailcap, mimetypesSupport ? true
, ncurses
, openssl
, readline
, sqlite
, tcl ? null, tk ? null, tix ? null, libX11 ? null, xorgproto ? null, x11Support ? false
, bluez ? null, bluezSupport ? false
, zlib
, tzdata ? null
, self
, configd
, autoreconfHook
, autoconf-archive
, pkg-config
, python-setup-hook
, nukeReferences
# For the Python package set
, packageOverrides ? (self: super: {})
, pkgsBuildBuild
, pkgsBuildHost
, pkgsBuildTarget
, pkgsHostHost
, pkgsTargetTarget
, sourceVersion
, sha256
, passthruFun
, bash
, stripConfig ? false
, stripIdlelib ? false
, stripTests ? false
, stripTkinter ? false
, rebuildBytecode ? true
, stripBytecode ? true
, includeSiteCustomize ? true
, static ? stdenv.hostPlatform.isStatic
, enableOptimizations ? false
# enableNoSemanticInterposition is a subset of the enableOptimizations flag that doesn't harm reproducibility.
# clang starts supporting `-fno-sematic-interposition` with version 10
, enableNoSemanticInterposition ? (!stdenv.cc.isClang || (stdenv.cc.isClang && lib.versionAtLeast stdenv.cc.version "10"))
# enableLTO is a subset of the enableOptimizations flag that doesn't harm reproducibility.
# enabling LTO on 32bit arch causes downstream packages to fail when linking
# enabling LTO on *-darwin causes python3 to fail when linking.
, enableLTO ? stdenv.is64bit && stdenv.isLinux
, reproducibleBuild ? false
, pythonAttr ? "python${sourceVersion.major}${sourceVersion.minor}"
}:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

assert x11Support -> tcl != null
                  && tk != null
                  && xorgproto != null
                  && libX11 != null;

assert bluezSupport -> bluez != null;

assert lib.assertMsg (enableOptimizations -> (!stdenv.cc.isClang))
  "Optimizations with clang are not supported. configure: error: llvm-profdata is required for a --enable-optimizations build but could not be found.";

assert lib.assertMsg (reproducibleBuild -> stripBytecode)
  "Deterministic builds require stripping bytecode.";

assert lib.assertMsg (reproducibleBuild -> (!enableOptimizations))
  "Deterministic builds are not achieved when optimizations are enabled.";

assert lib.assertMsg (reproducibleBuild -> (!rebuildBytecode))
  "Deterministic builds are not achieved when (default unoptimized) bytecode is created.";

with lib;

let
  buildPackages = pkgsBuildHost;
  inherit (passthru) pythonForBuild;

  tzdataSupport = tzdata != null && passthru.pythonAtLeast "3.9";

  passthru = passthruFun rec {
    inherit self sourceVersion packageOverrides;
    implementation = "cpython";
    libPrefix = "python${pythonVersion}";
    executable = libPrefix;
    pythonVersion = with sourceVersion; "${major}.${minor}";
    sitePackages = "lib/${libPrefix}/site-packages";
    inherit hasDistutilsCxxPatch;
    pythonOnBuildForBuild = pkgsBuildBuild.${pythonAttr};
    pythonOnBuildForHost = pkgsBuildHost.${pythonAttr};
    pythonOnBuildForTarget = pkgsBuildTarget.${pythonAttr};
    pythonOnHostForHost = pkgsHostHost.${pythonAttr};
    pythonOnTargetForTarget = pkgsTargetTarget.${pythonAttr} or {};
  };

  version = with sourceVersion; "${major}.${minor}.${patch}${suffix}";

  strictDeps = true;

  nativeBuildInputs = optionals (!stdenv.isDarwin) [
    autoreconfHook
    pkg-config
    autoconf-archive # needed for AX_CHECK_COMPILE_FLAG
  ] ++ [
    nukeReferences
  ] ++ optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
    buildPackages.stdenv.cc
    pythonForBuild
  ] ++ optionals (stdenv.cc.isClang && enableLTO) [
    stdenv.cc.cc.libllvm.out
  ];

  buildInputs = filter (p: p != null) ([
    zlib bzip2 expat xz libffi gdbm sqlite readline ncurses openssl ]
    ++ optionals x11Support [ tcl tk libX11 xorgproto ]
    ++ optionals (bluezSupport && stdenv.isLinux) [ bluez ]
    ++ optionals stdenv.isDarwin [ configd ])
    ++ optionals tzdataSupport [ tzdata ];  # `zoneinfo` module

  hasDistutilsCxxPatch = !(stdenv.cc.isGNU or false);

  pythonForBuildInterpreter = if stdenv.hostPlatform == stdenv.buildPlatform then
    "$out/bin/python"
  else pythonForBuild.interpreter;

  # The CPython interpreter contains a _sysconfigdata_<platform specific suffix>
  # module that is imported by the sysconfig and distutils.sysconfig modules.
  # The sysconfigdata module is generated at build time and contains settings
  # required for building Python extension modules, such as include paths and
  # other compiler flags. By default, the sysconfigdata module is loaded from
  # the currently running interpreter (ie. the build platform interpreter), but
  # when cross-compiling we want to load it from the host platform interpreter.
  # This can be done using the _PYTHON_SYSCONFIGDATA_NAME environment variable.
  # The _PYTHON_HOST_PLATFORM variable also needs to be set to get the correct
  # platform suffix on extension modules. The correct values for these variables
  # are not documented, and must be derived from the configure script (see links
  # below).
  sysconfigdataHook = with stdenv.hostPlatform; with passthru; let
    # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L428
    # The configure script uses "arm" as the CPU name for all 32-bit ARM
    # variants when cross-compiling, but native builds include the version
    # suffix, so we do the same.
    pythonHostPlatform = "${parsed.kernel.name}-${parsed.cpu.name}";

    # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L724
    multiarchCpu =
      if isAarch32 then
        if parsed.cpu.significantByte.name == "littleEndian" then "arm" else "armeb"
      else if isx86_32 then "i386"
      else parsed.cpu.name;
    pythonAbiName =
      # python's build doesn't differentiate between musl and glibc in its
      # abi detection, our wrapper should match.
      if stdenv.hostPlatform.isMusl then
        replaceStrings [ "musl" ] [ "gnu" ] parsed.abi.name
        else parsed.abi.name;
    multiarch =
      if isDarwin then "darwin"
      else "${multiarchCpu}-${parsed.kernel.name}-${pythonAbiName}";

    abiFlags = optionalString (isPy36 || isPy37) "m";

    # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L78
    pythonSysconfigdataName = "_sysconfigdata_${abiFlags}_${parsed.kernel.name}_${multiarch}";
  in ''
    sysconfigdataHook() {
      if [ "$1" = '${placeholder "out"}' ]; then
        export _PYTHON_HOST_PLATFORM='${pythonHostPlatform}'
        export _PYTHON_SYSCONFIGDATA_NAME='${pythonSysconfigdataName}'
      fi
    }

    addEnvHooks "$hostOffset" sysconfigdataHook
  '';

in with passthru; stdenv.mkDerivation {
  pname = "python3";
  inherit version;

  inherit buildInputs nativeBuildInputs;

  src = fetchurl {
    url = with sourceVersion; "https://www.python.org/ftp/python/${major}.${minor}.${patch}/Python-${version}.tar.xz";
    inherit sha256;
  };

  prePatch = optionalString stdenv.isDarwin ''
    substituteInPlace configure --replace '`/usr/bin/arch`' '"i386"'
  '' + optionalString (pythonOlder "3.9" && stdenv.isDarwin && x11Support) ''
    # Broken on >= 3.9; replaced with ./3.9/darwin-tcl-tk.patch
    substituteInPlace setup.py --replace /Library/Frameworks /no-such-path
  '';

  patches = [
    # Disable the use of ldconfig in ctypes.util.find_library (since
    # ldconfig doesn't work on NixOS), and don't use
    # ctypes.util.find_library during the loading of the uuid module
    # (since it will do a futile invocation of gcc (!) to find
    # libuuid, slowing down program startup a lot).
    (./. + "/${sourceVersion.major}.${sourceVersion.minor}/no-ldconfig.patch")
    # Make sure that the virtualenv activation scripts are
    # owner-writable, so venvs can be recreated without permission
    # errors.
    ./virtualenv-permissions.patch
  ] ++ optionals mimetypesSupport [
    # Make the mimetypes module refer to the right file
    ./mimetypes.patch
  ] ++ optionals (isPy35 || isPy36) [
    # Determinism: Write null timestamps when compiling python files.
    ./3.5/force_bytecode_determinism.patch
  ] ++ optionals isPy35 [
    # Backports support for LD_LIBRARY_PATH from 3.6
    ./3.5/ld_library_path.patch
  ] ++ optionals (isPy35 || isPy36 || isPy37) [
    # Backport a fix for discovering `rpmbuild` command when doing `python setup.py bdist_rpm` to 3.5, 3.6, 3.7.
    # See: https://bugs.python.org/issue11122
    ./3.7/fix-hardcoded-path-checking-for-rpmbuild.patch
    # The workaround is for unittests on Win64, which we don't support.
    # It does break aarch64-darwin, which we do support. See:
    # * https://bugs.python.org/issue35523
    # * https://github.com/python/cpython/commit/e6b247c8e524
    ./3.7/no-win64-workaround.patch
  ] ++ optionals (pythonAtLeast "3.7") [
    # Fix darwin build https://bugs.python.org/issue34027
    ./3.7/darwin-libutil.patch
  ] ++ optionals (pythonOlder "3.8") [
    # Backport from CPython 3.8 of a good list of tests to run for PGO.
    (
      if isPy36 || isPy37 then
        ./3.6/profile-task.patch
      else
        ./3.5/profile-task.patch
    )
  ] ++ optionals (pythonAtLeast "3.9" && stdenv.isDarwin) [
    # Stop checking for TCL/TK in global macOS locations
    ./3.9/darwin-tcl-tk.patch
  ] ++ optionals (isPy3k && hasDistutilsCxxPatch) [
    # Fix for http://bugs.python.org/issue1222585
    # Upstream distutils is calling C compiler to compile C++ code, which
    # only works for GCC and Apple Clang. This makes distutils to call C++
    # compiler when needed.
    (
      if isPy35 then
        ./3.5/python-3.x-distutils-C++.patch
      else if pythonAtLeast "3.7" then
        ./3.7/python-3.x-distutils-C++.patch
      else
        fetchpatch {
          url = "https://bugs.python.org/file48016/python-3.x-distutils-C++.patch";
          sha256 = "1h18lnpx539h5lfxyk379dxwr8m2raigcjixkf133l4xy3f4bzi2";
        }
    )
  ] ++ [
    # LDSHARED now uses $CC instead of gcc. Fixes cross-compilation of extension modules.
    ./3.8/0001-On-all-posix-systems-not-just-Darwin-set-LDSHARED-if.patch
    # Use sysconfigdata to find headers. Fixes cross-compilation of extension modules.
    (
      if isPy36 then
        ./3.6/fix-finding-headers-when-cross-compiling.patch
      else
        ./3.7/fix-finding-headers-when-cross-compiling.patch
    )
  ] ++ optionals (isPy36) [
    # Backport a fix for ctypes.util.find_library.
    ./3.6/find_library.patch
  ];

  postPatch = ''
    substituteInPlace Lib/subprocess.py \
      --replace "'/bin/sh'" "'${bash}/bin/sh'"
  '' + optionalString mimetypesSupport ''
    substituteInPlace Lib/mimetypes.py \
      --replace "@mime-types@" "${mailcap}"
  '' + optionalString (x11Support && (tix != null)) ''
    substituteInPlace "Lib/tkinter/tix.py" --replace "os.environ.get('TIX_LIBRARY')" "os.environ.get('TIX_LIBRARY') or '${tix}/lib'"
  '';

  CPPFLAGS = concatStringsSep " " (map (p: "-I${getDev p}/include") buildInputs);
  LDFLAGS = concatStringsSep " " (map (p: "-L${getLib p}/lib") buildInputs);
  LIBS = "${optionalString (!stdenv.isDarwin) "-lcrypt"} ${optionalString (ncurses != null) "-lncurses"}";
  NIX_LDFLAGS = lib.optionalString stdenv.cc.isGNU ({
    "glibc" = "-lgcc_s";
    "musl" = "-lgcc_eh";
  }."${stdenv.hostPlatform.libc}" or "");
  # Determinism: We fix the hashes of str, bytes and datetime objects.
  PYTHONHASHSEED=0;

  configureFlags = [
    "--without-ensurepip"
    "--with-system-expat"
    "--with-system-ffi"
  ] ++ optionals (!static) [
    "--enable-shared"
  ] ++ optionals enableOptimizations [
    "--enable-optimizations"
  ] ++ optionals enableLTO [
    "--with-lto"
  ] ++ optionals (pythonOlder "3.7") [
    # This is unconditionally true starting in CPython 3.7.
    "--with-threads"
  ] ++ optionals (sqlite != null && isPy3k) [
    "--enable-loadable-sqlite-extensions"
  ] ++ optionals (openssl != null) [
    "--with-openssl=${openssl.dev}"
  ] ++ optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
    "ac_cv_buggy_getaddrinfo=no"
    # Assume little-endian IEEE 754 floating point when cross compiling
    "ac_cv_little_endian_double=yes"
    "ac_cv_big_endian_double=no"
    "ac_cv_mixed_endian_double=no"
    "ac_cv_x87_double_rounding=yes"
    "ac_cv_tanh_preserves_zero_sign=yes"
    # Generally assume that things are present and work
    "ac_cv_posix_semaphores_enabled=yes"
    "ac_cv_broken_sem_getvalue=no"
    "ac_cv_wchar_t_signed=yes"
    "ac_cv_rshift_extends_sign=yes"
    "ac_cv_broken_nice=no"
    "ac_cv_broken_poll=no"
    "ac_cv_working_tzset=yes"
    "ac_cv_have_long_long_format=yes"
    "ac_cv_have_size_t_format=yes"
    "ac_cv_computed_gotos=yes"
    "ac_cv_file__dev_ptmx=yes"
    "ac_cv_file__dev_ptc=yes"
  ] ++ optionals stdenv.hostPlatform.isLinux [
    # Never even try to use lchmod on linux,
    # don't rely on detecting glibc-isms.
    "ac_cv_func_lchmod=no"
  ] ++ optionals tzdataSupport [
    "--with-tzpath=${tzdata}/share/zoneinfo"
  ] ++ optional static "LDFLAGS=-static";

  preConfigure = ''
    for i in /usr /sw /opt /pkg; do	# improve purity
      substituteInPlace ./setup.py --replace $i /no-such-path
    done
  '' + optionalString stdenv.isDarwin ''
    # Override the auto-detection in setup.py, which assumes a universal build
    export PYTHON_DECIMAL_WITH_MACHINE=${if stdenv.isAarch64 then "uint128" else "x64"}
  '' + optionalString (isPy3k && pythonOlder "3.7") ''
    # Determinism: The interpreter is patched to write null timestamps when compiling Python files
    #   so Python doesn't try to update the bytecode when seeing frozen timestamps in Nix's store.
    export DETERMINISTIC_BUILD=1;
  '' + optionalString stdenv.hostPlatform.isMusl ''
    export NIX_CFLAGS_COMPILE+=" -DTHREAD_STACK_SIZE=0x100000"
  '' +

  # enableNoSemanticInterposition essentially sets that CFLAG -fno-semantic-interposition
  # which changes how symbols are looked up. This essentially means we can't override
  # libpython symbols via LD_PRELOAD anymore. This is common enough as every build
  # that uses --enable-optimizations has the same "issue".
  #
  # The Fedora wiki has a good article about their journey towards enabling this flag:
  # https://fedoraproject.org/wiki/Changes/PythonNoSemanticInterpositionSpeedup
  optionalString enableNoSemanticInterposition ''
    export CFLAGS_NODIST="-fno-semantic-interposition"
  '';

  setupHook = python-setup-hook sitePackages;

  postInstall = let
    # References *not* to nuke from (sys)config files
    keep-references = concatMapStringsSep " " (val: "-e ${val}") ([
      (placeholder "out")
    ] ++ optionals tzdataSupport [
      tzdata
    ]);
  in ''
    # needed for some packages, especially packages that backport functionality
    # to 2.x from 3.x
    for item in $out/lib/${libPrefix}/test/*; do
      if [[ "$item" != */test_support.py*
         && "$item" != */test/support
         && "$item" != */test/libregrtest
         && "$item" != */test/regrtest.py* ]]; then
        rm -rf "$item"
      else
        echo $item
      fi
    done
    touch $out/lib/${libPrefix}/test/__init__.py

    ln -s "$out/include/${executable}m" "$out/include/${executable}"

    # Determinism: Windows installers were not deterministic.
    # We're also not interested in building Windows installers.
    find "$out" -name 'wininst*.exe' | xargs -r rm -f

    # Use Python3 as default python
    ln -s "$out/bin/idle3" "$out/bin/idle"
    ln -s "$out/bin/pydoc3" "$out/bin/pydoc"
    ln -s "$out/bin/python3" "$out/bin/python"
    ln -s "$out/bin/python3-config" "$out/bin/python-config"
    ln -s "$out/lib/pkgconfig/python3.pc" "$out/lib/pkgconfig/python.pc"

    # Get rid of retained dependencies on -dev packages, and remove
    # some $TMPDIR references to improve binary reproducibility.
    # Note that the .pyc file of _sysconfigdata.py should be regenerated!
    for i in $out/lib/${libPrefix}/_sysconfigdata*.py $out/lib/${libPrefix}/config-${sourceVersion.major}${sourceVersion.minor}*/Makefile; do
       sed -i $i -e "s|$TMPDIR|/no-such-path|g"
    done

    # Further get rid of references. https://github.com/NixOS/nixpkgs/issues/51668
    find $out/lib/python*/config-* -type f -print -exec nuke-refs ${keep-references} '{}' +
    find $out/lib -name '_sysconfigdata*.py*' -print -exec nuke-refs ${keep-references} '{}' +

    # Make the sysconfigdata module accessible on PYTHONPATH
    # This allows build Python to import host Python's sysconfigdata
    mkdir -p "$out/${sitePackages}"
    ln -s "$out/lib/${libPrefix}/"_sysconfigdata*.py "$out/${sitePackages}/"

    # debug info can't be separated from a static library and would otherwise be
    # left in place by a separateDebugInfo build. force its removal here to save
    # space in output.
    $STRIP -S $out/lib/${libPrefix}/config-*/libpython*.a || true
    '' + optionalString stripConfig ''
    rm -R $out/bin/python*-config $out/lib/python*/config-*
    '' + optionalString stripIdlelib ''
    # Strip IDLE (and turtledemo, which uses it)
    rm -R $out/bin/idle* $out/lib/python*/{idlelib,turtledemo}
    '' + optionalString stripTkinter ''
    rm -R $out/lib/python*/tkinter
    '' + optionalString stripTests ''
    # Strip tests
    rm -R $out/lib/python*/test $out/lib/python*/**/test{,s}
    '' + optionalString includeSiteCustomize ''
    # Include a sitecustomize.py file
    cp ${../sitecustomize.py} $out/${sitePackages}/sitecustomize.py

    '' + optionalString stripBytecode ''
    # Determinism: deterministic bytecode
    # First we delete all old bytecode.
    find $out -type d -name __pycache__ -print0 | xargs -0 -I {} rm -rf "{}"
    '' + optionalString rebuildBytecode ''
    # Python 3.7 implements PEP 552, introducing support for deterministic bytecode.
    # compileall uses the therein introduced checked-hash method by default when
    # `SOURCE_DATE_EPOCH` is set.
    # We exclude lib2to3 because that's Python 2 code which fails
    # We build 3 levels of optimized bytecode. Note the default level, without optimizations,
    # is not reproducible yet. https://bugs.python.org/issue29708
    # Not creating bytecode will result in a large performance loss however, so we do build it.
    find $out -name "*.py" | ${pythonForBuildInterpreter} -m compileall -q -f -x "lib2to3" -i -
    find $out -name "*.py" | ${pythonForBuildInterpreter} -O  -m compileall -q -f -x "lib2to3" -i -
    find $out -name "*.py" | ${pythonForBuildInterpreter} -OO -m compileall -q -f -x "lib2to3" -i -
    '' + ''
    # *strip* shebang from libpython gdb script - it should be dual-syntax and
    # interpretable by whatever python the gdb in question is using, which may
    # not even match the major version of this python. doing this after the
    # bytecode compilations for the same reason - we don't want bytecode generated.
    mkdir -p $out/share/gdb
    sed '/^#!/d' Tools/gdb/libpython.py > $out/share/gdb/libpython.py
  '';

  preFixup = lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
    # Ensure patch-shebangs uses shebangs of host interpreter.
    export PATH=${lib.makeBinPath [ "$out" bash ]}:$PATH
  '';

  # Add CPython specific setup-hook that configures distutils.sysconfig to
  # always load sysconfigdata from host Python.
  postFixup = lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
    cat << "EOF" >> "$out/nix-support/setup-hook"
    ${sysconfigdataHook}
    EOF
  '';

  # Enforce that we don't have references to the OpenSSL -dev package, which we
  # explicitly specify in our configure flags above.
  disallowedReferences =
    lib.optionals (openssl != null && !static) [ openssl.dev ]
    ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
    # Ensure we don't have references to build-time packages.
    # These typically end up in shebangs.
    pythonForBuild buildPackages.bash
  ];

  separateDebugInfo = true;

  inherit passthru;

  enableParallelBuilding = true;

  meta = {
    homepage = "http://python.org";
    description = "A high-level dynamically-typed programming language";
    longDescription = ''
      Python is a remarkably powerful dynamic programming language that
      is used in a wide variety of application domains. Some of its key
      distinguishing features include: clear, readable syntax; strong
      introspection capabilities; intuitive object orientation; natural
      expression of procedural code; full modularity, supporting
      hierarchical packages; exception-based error handling; and very
      high level dynamic data types.
    '';
    license = licenses.psfl;
    platforms = with platforms; linux ++ darwin;
    maintainers = with maintainers; [ fridh ];
  };
}
