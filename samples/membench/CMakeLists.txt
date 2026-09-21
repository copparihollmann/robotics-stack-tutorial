# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(membench)

# kernels.S carries the three inner loops. They are assembly so that the bandwidth and
# latency numbers can be traced to an instruction stream rather than to a compiler's mood;
# scripts/25_rocket_membench.sh disassembles them out of the built ELF into inner_loops.txt.
target_sources(app PRIVATE src/main.c src/kernels.S)
