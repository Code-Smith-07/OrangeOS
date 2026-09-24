// Native C++ language/ABI probe; deliberately no libc++ or host services.
#include <stdint.h>

namespace {
int initialized = 0;
int destructed = 0;

struct Startup {
    Startup() { initialized = 0x51; }
};
Startup startup;

struct Expression {
    virtual double evaluate(double input) const = 0;
    virtual ~Expression() {}
};

struct Affine final : Expression {
    explicit Affine(double base) : base_(base) {}
    double evaluate(double input) const override { return base_ + input * 1.5; }
    ~Affine() override { ++destructed; }
private:
    double base_;
};
}  // namespace

extern "C" struct Result {
    double value;
    uint64_t checks;
};

extern "C" Result orange_cxx_probe(double input) {
    uint64_t checks = initialized == 0x51 ? 1 : 0;
    Expression *expression = new Affine(2.25);
    const double value = expression->evaluate(input);
    const int before_delete = destructed;
    delete expression;
    if (destructed == before_delete + 1) checks |= 2;

    int *values = new int[17];
    int total = 0;
    for (int i = 0; i < 17; ++i) {
        values[i] = i + 1;
        total += values[i];
    }
    delete[] values;
    if (total == 153) checks |= 4;
    return {value, checks};
}
