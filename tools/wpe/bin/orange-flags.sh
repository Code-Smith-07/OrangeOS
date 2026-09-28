# Shared by orange-cc and orange-c++ (sourced, not run).
# Position-independent code throughout: the build systems of glib-networking
# (a GIO module) and WebKit (libWPEWebKit) link some static libraries into
# shared objects while building, and PIC objects still link into
# OrangeOS's static programs.
ORANGE_TARGET_FLAGS="-target x86_64-linux-musl -mcpu=baseline -fno-sanitize=all -fno-stack-protector -mno-red-zone -fPIC"
# Meson preprocesses with "-E -P ... -c"; zig then compiles instead of
# stopping after preprocessing, as clang would. Drop -c when -E is present.
case " $* " in
*" -E "*)
    for arg in "$@"; do
        shift
        [ "$arg" = "-c" ] || set -- "$@" "$arg"
    done
    ;;
esac
