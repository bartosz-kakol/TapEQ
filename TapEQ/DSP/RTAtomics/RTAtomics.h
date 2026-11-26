//
//  RTAtomics.h
//  TapEQ
//
//  Minimal C11 atomics for the real-time audio path.
//
//  Swift has no atomics that deploy back to macOS 14 (the `Synchronization`
//  module needs macOS 15), so the lock-free hand-off between the main thread
//  and the IOProc goes through these static inline wrappers. They are header
//  only: every call is inlined into the Swift caller, and none of them
//  allocates, locks, or touches a reference count.
//

#ifndef TAPEQ_RT_ATOMICS_H
#define TAPEQ_RT_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

#if !defined(__clang__)
#error "RTAtomics.h needs clang"
#endif

#pragma clang assume_nonnull begin

/// A pointer-sized cell that is only read and written atomically.
typedef struct {
    void *_Nullable _value;
} tapeq_atomic_ptr;

/// A 64-bit cell that is only read and written atomically.
typedef struct {
    uint64_t _value;
} tapeq_atomic_u64;

/// A 32-bit cell that is only read and written atomically.
typedef struct {
    uint32_t _value;
} tapeq_atomic_u32;

static inline void *_Nullable tapeq_atomic_ptr_load(tapeq_atomic_ptr *cell) {
    return atomic_load_explicit((_Atomic(void *) *)&cell->_value, memory_order_acquire);
}

static inline void tapeq_atomic_ptr_store(tapeq_atomic_ptr *cell, void *_Nullable value) {
    atomic_store_explicit((_Atomic(void *) *)&cell->_value, value, memory_order_release);
}

static inline void *_Nullable tapeq_atomic_ptr_exchange(tapeq_atomic_ptr *cell, void *_Nullable value) {
    return atomic_exchange_explicit((_Atomic(void *) *)&cell->_value, value, memory_order_acq_rel);
}

static inline uint64_t tapeq_atomic_u64_load(tapeq_atomic_u64 *cell) {
    return atomic_load_explicit((_Atomic(uint64_t) *)&cell->_value, memory_order_relaxed);
}

static inline void tapeq_atomic_u64_store(tapeq_atomic_u64 *cell, uint64_t value) {
    atomic_store_explicit((_Atomic(uint64_t) *)&cell->_value, value, memory_order_relaxed);
}

static inline uint64_t tapeq_atomic_u64_add(tapeq_atomic_u64 *cell, uint64_t value) {
    return atomic_fetch_add_explicit((_Atomic(uint64_t) *)&cell->_value, value, memory_order_relaxed);
}

static inline uint32_t tapeq_atomic_u32_load(tapeq_atomic_u32 *cell) {
    return atomic_load_explicit((_Atomic(uint32_t) *)&cell->_value, memory_order_relaxed);
}

static inline void tapeq_atomic_u32_store(tapeq_atomic_u32 *cell, uint32_t value) {
    atomic_store_explicit((_Atomic(uint32_t) *)&cell->_value, value, memory_order_relaxed);
}

static inline uint32_t tapeq_atomic_u32_exchange(tapeq_atomic_u32 *cell, uint32_t value) {
    return atomic_exchange_explicit((_Atomic(uint32_t) *)&cell->_value, value, memory_order_relaxed);
}

#pragma clang assume_nonnull end

#endif /* TAPEQ_RT_ATOMICS_H */
