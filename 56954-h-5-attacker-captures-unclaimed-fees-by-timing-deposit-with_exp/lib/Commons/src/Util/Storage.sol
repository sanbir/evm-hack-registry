// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

/*
  EMPTY FILE.
  Notes on storage design as of 1/5/2023.

  In a more complex system, we want to lock the storage we want to modify instead
  of just putting a reentrancy guard on function calls either through a mutex or a reader/writer lock.
  That way we can classify which code paths can be used together and which can't.

  That overhead is really tricky. Do we embed the mutex in the storage struct itself?
  We could give every storage struct a wrapper struct that contains a mutex and cast
  between the two when locking and unlocking.

  That's pretty expensive in terms of storage fetching. Especially because we want swap to be hyper-gas
  optimized. This gets extra expensive if we split storage structs into their semantic parts. We'd need
  a seperate lock for each storage struct. That's ultimately the reason we fallback to a single
  reentrancy guard. We don't want to

  Alternatively, we can give the mutexes a separate storage location and group them into a bitmap, but that's
  still more expensive than a single reentrancy guard.

  Once EIP-1153 is live we can look into these solutions.
 */
