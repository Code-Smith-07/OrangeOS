// A C++20 program built against libc++, libc++abi and libunwind on musl,
// running natively on OrangeOS: iostreams and file streams, containers and
// algorithms, formatting, exceptions unwinding through destructors and
// across threads, RTTI, thread-safe static initialization, std::thread with
// mutexes, condition variables, atomics and futures, and steady_clock sleeps.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <exception>
#include <format>
#include <fstream>
#include <functional>
#include <future>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <typeinfo>
#include <unordered_map>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const char *what) {
    if (!condition) {
        std::printf("cxx-probe: FAIL %s\n", what);
        ++failures;
    }
}

// ── Exceptions ──────────────────────────────────────────────────────────────

int live_guards = 0;
struct Guard {
    Guard() { ++live_guards; }
    ~Guard() { --live_guards; }
};

struct ProbeError : std::runtime_error {
    int code;
    ProbeError(const char *message, int value) : std::runtime_error(message), code(value) {}
};

[[gnu::noinline]] void throwDeep(int depth) {
    Guard guard;
    if (depth == 0) throw ProbeError("deep", 42);
    throwDeep(depth - 1);
}

bool exceptions() {
    bool caught = false;
    try {
        throwDeep(16);
    } catch (const std::runtime_error &error) {
        // Caught through a base class; every frame's Guard was destroyed.
        auto *derived = dynamic_cast<const ProbeError *>(&error);
        caught = derived && derived->code == 42 && std::string(error.what()) == "deep" && live_guards == 0;
    }
    check(caught, "throw through 17 frames, catch by base, unwind destructors");

    int rethrown = 0;
    try {
        try {
            throw std::out_of_range("inner");
        } catch (...) {
            ++rethrown;
            throw;
        }
    } catch (const std::logic_error &) {
        ++rethrown;
    }
    check(rethrown == 2, "catch-all rethrow");

    std::vector<int> small(3);
    bool range = false;
    try {
        (void)small.at(10);
    } catch (const std::out_of_range &) {
        range = true;
    }
    check(range, "library-thrown std::out_of_range");

    bool bad_alloc = false;
    try {
        // Publishing the pointer keeps the compiler from eliding the
        // allocation, which it may do for a new/delete pair nobody observes.
        static char *volatile escaped;
        escaped = new char[std::size_t{1} << 46];
        delete[] escaped;
    } catch (const std::bad_alloc &) {
        bad_alloc = true;
    }
    check(bad_alloc, "operator new failure throws std::bad_alloc");

    auto pointer = std::make_exception_ptr(ProbeError("stored", 7));
    int stored = 0;
    try {
        std::rethrow_exception(pointer);
    } catch (const ProbeError &error) {
        stored = error.code;
    }
    check(stored == 7, "exception_ptr rethrow");
    return failures == 0;
}

// ── RTTI ────────────────────────────────────────────────────────────────────

struct Shape {
    virtual ~Shape() = default;
    virtual double area() const = 0;
};
struct Square : Shape {
    double side;
    explicit Square(double value) : side(value) {}
    double area() const override { return side * side; }
};
struct Circle : Shape {
    double radius;
    explicit Circle(double value) : radius(value) {}
    double area() const override { return 3.0 * radius * radius; }
};

void rtti() {
    std::vector<std::unique_ptr<Shape>> shapes;
    shapes.push_back(std::make_unique<Square>(2));
    shapes.push_back(std::make_unique<Circle>(1));
    int squares = 0;
    double total = 0;
    for (const auto &shape : shapes) {
        if (dynamic_cast<Square *>(shape.get())) ++squares;
        total += shape->area();
    }
    check(squares == 1 && total == 7.0, "dynamic_cast and virtual dispatch");
    const Shape &square = *shapes[0], &circle = *shapes[1];
    check(typeid(circle) == typeid(Circle) && typeid(square) != typeid(Circle), "typeid");
    bool bad_cast = false;
    try {
        Shape &shape = *shapes[1];
        (void)dynamic_cast<Square &>(shape);
    } catch (const std::bad_cast &) {
        bad_cast = true;
    }
    check(bad_cast, "reference dynamic_cast throws std::bad_cast");
}

// ── Library ─────────────────────────────────────────────────────────────────

void library() {
    std::vector<int> values(1000);
    std::iota(values.begin(), values.end(), 0);
    std::reverse(values.begin(), values.end());
    std::sort(values.begin(), values.end());
    check(std::is_sorted(values.begin(), values.end()) && values[999] == 999, "vector and sort");

    std::map<std::string, int> ordered;
    std::unordered_map<int, std::string> hashed;
    for (int i = 0; i < 200; ++i) {
        ordered[std::to_string(i)] = i;
        hashed[i] = std::to_string(i * i);
    }
    check(ordered.size() == 200 && ordered.begin()->first == "0" && ordered["57"] == 57, "map");
    check(hashed.size() == 200 && hashed[12] == "144", "unordered_map");

    std::ostringstream stream;
    stream << "pi=" << 3.25 << " hex=" << std::hex << 255;
    check(stream.str() == "pi=3.25 hex=ff", "ostringstream");
    check(std::format("{:>6}|{:.3f}|{}", "ok", 2.0 / 3.0, 12345) == "    ok|0.667|12345", "std::format");
    check(std::stod("2.5e3") == 2500.0 && std::stoi("-17") == -17, "stod and stoi");

    std::ifstream motd("/etc/motd");
    std::string line;
    check(motd && std::getline(motd, line) && line == "Welcome to Orange OS.", "ifstream getline");
    std::ifstream missing("/etc/missing");
    check(!missing, "ifstream of a missing file fails");
}

// ── Threads ─────────────────────────────────────────────────────────────────

std::atomic<int> constructions{0};
struct Expensive {
    int value;
    Expensive() : value(99) {
        ++constructions;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
};

int sharedStatic() {
    static Expensive instance;  // guarded by __cxa_guard_acquire
    return instance.value;
}

void threads() {
    constexpr int kThreads = 4;
    constexpr int kRounds = 5000;

    std::vector<std::thread> workers;
    std::atomic<int> static_ok{0};
    for (int i = 0; i < kThreads; ++i)
        workers.emplace_back([&] {
            if (sharedStatic() == 99) ++static_ok;
        });
    for (auto &worker : workers) worker.join();
    check(constructions == 1 && static_ok == kThreads, "thread-safe static initialization");

    std::mutex lock;
    std::condition_variable changed;
    long counter = 0;
    int finished = 0;
    workers.clear();
    for (int i = 0; i < kThreads; ++i)
        workers.emplace_back([&] {
            for (int round = 0; round < kRounds; ++round) {
                std::lock_guard<std::mutex> hold(lock);
                ++counter;
            }
            std::lock_guard<std::mutex> hold(lock);
            ++finished;
            changed.notify_all();
        });
    {
        std::unique_lock<std::mutex> hold(lock);
        changed.wait(hold, [&] { return finished == kThreads; });
    }
    for (auto &worker : workers) worker.join();
    check(counter == kThreads * kRounds, "std::thread, mutex and condition_variable");

    auto failing = std::async(std::launch::async, [] {
        throw ProbeError("from thread", 9);
        return 0;
    });
    int thread_code = 0;
    try {
        failing.get();
    } catch (const ProbeError &error) {
        thread_code = error.code;
    }
    check(thread_code == 9, "exception carried out of a thread by std::future");

    auto sum = std::async(std::launch::async, [] {
        long total = 0;
        for (int i = 1; i <= 1000; ++i) total += i;
        return total;
    });
    check(sum.get() == 500500, "std::async result");

    auto start = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    check(std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(20), "sleep_for and steady_clock");
}

}  // namespace

int main() {
    exceptions();
    rtti();
    library();
    threads();
    if (failures != 0) return 1;
    std::cout << "cxx-probe: PASS iostreams, containers, format, exceptions, RTTI, "
                 "thread-safe statics, threads and futures"
              << std::endl;
    return 0;
}
