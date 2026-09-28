# Shared by orange-cc and orange-c++ (sourced, not run).
ORANGE_TARGET_FLAGS="-target x86_64-linux-musl -mcpu=baseline -fno-sanitize=all -fno-stack-protector -mno-red-zone -fno-pic"
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
