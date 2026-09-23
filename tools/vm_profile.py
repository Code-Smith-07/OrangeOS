#!/usr/bin/env python3
"""Resolve explicit VM resource profiles without changing global defaults.

ORANGE_VM_PROFILE=browser selects 4 GiB / 2 vCPUs and a 4096 MiB budget.
Explicit resource overrides win. This controls capacity, not GPU capability.
"""
import argparse
from dataclasses import asdict, dataclass
import json
import os
import re


@dataclass(frozen=True)
class Profile:
    name: str
    ram_mib: int
    cpus: int
    ram_budget_mib: int

    def qemu_args(self):
        return ["-m", str(self.ram_mib), "-smp", str(self.cpus)]


def positive_integer(value, name):
    if not re.fullmatch(r"[0-9]+", value) or int(value) < 1:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


def memory_mib(value):
    match = re.fullmatch(r"([0-9]+)([MG]?)", value, re.IGNORECASE)
    if not match:
        raise ValueError("ORANGE_VM_RAM must be whole MiB or an integer with M/G suffix")
    amount = positive_integer(match[1], "ORANGE_VM_RAM")
    return amount * (1024 if match[2].upper() == "G" else 1)


def resolve(environ=None):
    env = os.environ if environ is None else environ
    name = env.get("ORANGE_VM_PROFILE", "desktop")
    defaults = {"desktop": 3072, "browser": 4096}
    if name not in defaults:
        raise ValueError("ORANGE_VM_PROFILE must be desktop or browser")
    ram = memory_mib(env.get("ORANGE_VM_RAM", str(defaults[name])))
    cpus = positive_integer(env.get("ORANGE_VM_CPUS", "2"), "ORANGE_VM_CPUS")
    if cpus > 32:
        raise ValueError("ORANGE_VM_CPUS exceeds Zest's 32-CPU limit")
    budget = positive_integer(env.get("ORANGE_RAM_BUDGET_MIB", str(defaults[name])),
                              "ORANGE_RAM_BUDGET_MIB")
    if budget > ram:
        raise ValueError("RAM budget exceeds guest capacity; lower ORANGE_RAM_BUDGET_MIB too")
    return Profile(name, ram, cpus, budget)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--field", choices=("ram_mib", "cpus", "ram_budget_mib"))
    args = parser.parse_args()
    try:
        profile = resolve()
    except ValueError as error:
        parser.error(str(error))
    print(getattr(profile, args.field) if args.field else json.dumps(asdict(profile)))


if __name__ == "__main__":
    main()
