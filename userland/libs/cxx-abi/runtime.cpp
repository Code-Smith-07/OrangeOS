// Minimal, reusable freestanding C++ allocation bridge. This is not libc++.
#include <stddef.h>

extern "C" void *orange_cxx_allocate(size_t size);
extern "C" void orange_cxx_release(void *pointer);
extern "C" [[noreturn]] void orange_cxx_out_of_memory();

void *operator new(size_t size) {
    void *pointer = orange_cxx_allocate(size);
    if (!pointer) orange_cxx_out_of_memory();
    return pointer;
}

void *operator new[](size_t size) {
    void *pointer = orange_cxx_allocate(size);
    if (!pointer) orange_cxx_out_of_memory();
    return pointer;
}

void operator delete(void *pointer) noexcept { orange_cxx_release(pointer); }
void operator delete[](void *pointer) noexcept { orange_cxx_release(pointer); }
void operator delete(void *pointer, size_t) noexcept { orange_cxx_release(pointer); }
void operator delete[](void *pointer, size_t) noexcept { orange_cxx_release(pointer); }
