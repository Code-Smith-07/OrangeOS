# Shared by orange-cc and orange-c++ (sourced, not run).
ORANGE_TARGET_FLAGS="-target x86_64-linux-musl -mcpu=baseline -fno-sanitize=all -fno-stack-protector -mno-red-zone"
# Non-PIC by default, as build.zig compiles OrangeOS programs; a build that
# asks for position-independent code (WebKit does) gets it, and such
# objects still link into OrangeOS's static programs.
case " $* " in
*" -fPIC "* | *" -fpic "* | *" -fPIE "* | *" -fpie "*) ;;
*) ORANGE_TARGET_FLAGS="$ORANGE_TARGET_FLAGS -fno-pic" ;;
esac
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
