/* Freestanding C ABI probe; deliberately no libc or browser-engine claims. */
#include <stdint.h>
#include <stddef.h>

struct result { double value; uint64_t tag; };
typedef double (*callback)(double, double);

struct result browser_c_arithmetic(double value, double divisor, uint64_t tag) {
    struct result result = {(value * divisor + 1.0) / divisor, tag};
    return result;
}

double browser_c_sum(const double *values, size_t count, callback add) {
    double sum = 0.0;
    for (size_t i = 0; i < count; ++i) sum = add(sum, values[i]);
    return sum;
}

/* Nine floating-point arguments also exercise the stack beyond XMM0..7. */
double browser_c_stack(double a, double b, double c, double d, double e,
                       double f, double g, double h, double i) {
    return a + b + c + d + e + f + g + h + i;
}
