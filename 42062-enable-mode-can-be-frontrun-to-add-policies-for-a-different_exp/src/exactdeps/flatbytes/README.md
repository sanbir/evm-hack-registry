# Flat Bytes Library

**A library to store `bytes` in consecutive storage slots**

> This repository is a work in progress and is not yet ready for production use.

## Using the library

In a contract, you can use the `FlatBytes` library to store bytes in a way that is compliant with the ERC-4337 standard:

```solidity
contract Example {
    using FlatBytesLib for FlatBytesLib.Bytes;

    // Declare a variable to store the data
    // Note: this can also be in a mapping or other data structure
    FlatBytesLib.Bytes data;

    function set(bytes memory _data) external {
        // Store the data
        data.store(_data);
    }

    function get() external view returns (bytes memory) {
        // Retrieve the data
        return data.load();
    }
}
```

## Using this repo

To install the dependencies, run:

```bash
forge install
```

To build the project, run:

```bash
forge build
```

To run the tests, run:

```bash
forge test
```

## Contributing

For feature or change requests, feel free to open a PR, start a discussion or get in touch with us.
